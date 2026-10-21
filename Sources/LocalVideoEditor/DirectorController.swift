// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import AVFoundation
import LocalVideoCore

struct DirectorChatMessage: Identifiable {
    let id = UUID()
    let user: Bool
    let text: String
}
struct DirectorFrame: Identifiable {
    let id = UUID()
    let frame: Int64
    let image: CGImage
}
struct DirectorDraft: Identifiable {
    let id = UUID()
    let base: VideoProject
    let project: VideoProject
    let plan: DirectorPlan
    var warnings: [String]
    var frames: [DirectorFrame]
    var visualReview: String?
    var reviewRevised = false
}

@MainActor final class DirectorController: ObservableObject {
    @Published var connection: DirectorConnection
    @Published var look: DirectorLook = .minimal
    @Published var shareFrames = false
    @Published var messages: [DirectorChatMessage] = []
    @Published var pending: DirectorDraft?
    @Published var working = false
    @Published var phase = ""
    @Published var error: String?
    @Published var activity: [String] = []
    @Published private(set) var cachedObservations = 0
    private var sceneCache = DirectorSceneCache()
    private let maximumRequests = 6
    private var task: Task<Void, Never>?
    private var token = UUID()
    private let provider: DirectorProvider
    private let secrets: DirectorSecretStore
    private let defaults: UserDefaults
    init(provider: DirectorProvider = DirectorProvider(), secrets: DirectorSecretStore = DirectorKeychain(), defaults: UserDefaults = .standard) {
        self.provider = provider; self.secrets = secrets; self.defaults = defaults
        connection = defaults.data(forKey: "director.connection").flatMap { try? JSONDecoder().decode(DirectorConnection.self, from: $0) } ?? DirectorConnection()
    }
    var configured: Bool { (try? connection.validatedEndpoint()) != nil }
    var destination: String { URL(string: connection.baseURL)?.host ?? "your chosen endpoint" }
    func saveConnection(_ value: DirectorConnection, key: String?) throws {
        _ = try value.validatedEndpoint()
        if let key {
            guard key.count <= 4096, !key.contains(where: { $0.isNewline }) else { throw EditorError("Enter a valid API key.") }
            try secrets.write(key.trimmingCharacters(in: .whitespacesAndNewlines), for: value)
        }
        let bytes = try JSONEncoder().encode(value)
        cancel(); connection = value; defaults.set(bytes, forKey: "director.connection")
    }
    func clearChat() { cancel(); pending = nil; messages = []; error = nil; sceneCache.clear(); cachedObservations = 0; activity = [] }
    func forgetVisualNotes() { sceneCache.clear(); cachedObservations = 0 }
    func cancel() { task?.cancel(); task = nil; token = UUID(); working = false; phase = "" }
    func projectChanged(_ project: VideoProject) {
        if let pending, pending.base != project { self.pending = nil; error = "The edit changed. Request a fresh draft so your manual changes stay intact." }
        if working { cancel(); error = "The edit changed. Send your request again using the current timeline." }
    }
    func send(_ prompt: String, project: VideoProject, selectedClip: UUID?, selectedAudio: UUID?, playhead: Int64) {
        guard !working else { return }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 8000 else { error = "Describe the edit in up to 8000 characters."; return }
        cancel(); error = nil; pending = nil
        let history = messages.suffix(8).map { ($0.user ? "User: " : "Director: ") + String($0.text.prefix(2000)) }.joined(separator: "\n")
        messages.append(DirectorChatMessage(user: true, text: prompt)); trimHistory()
        let connection = connection, look = look, includeFrames = shareFrames, current = UUID()
        token = current; working = true; activity = []; setPhase("Building draft")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try DirectorContext.snapshot(project, selectedClip: selectedClip, selectedAudio: selectedAudio, playhead: playhead)
                let key = try secrets.read(connection)
                let instructions = look.instructions.replacingOccurrences(of: "Return exactly one JSON edit plan", with: "Return one JSON response using the integrated protocol below") + "\n" + DirectorStep.instructions
                let input = try Self.requestText(snapshot: snapshot, history: history, prompt: prompt, instructions: instructions)
                let reviewInput = try Self.requestText(snapshot: snapshot, history: "", prompt: prompt, instructions: instructions)
                var used = 0, rounds = 0, repaired = false
                var toolResult = "", feedback = ""
                var images: [DirectorImage] = []
                var supplied: [UUID: Set<Int64>] = [:], sources: [UUID: MediaVisualSource] = [:]
                var plan: DirectorPlan?
                var candidate: VideoProject?
                while plan == nil {
                    try Task.checkCancellation(); guard token == current else { return }
                    guard used < maximumRequests - (includeFrames ? 1 : 0) else { throw EditorError("Director reached the request limit. Try a more focused edit.") }
                    setPhase("Building draft")
                    let notes = includeFrames ? try sceneCache.context(project: project, connection: connection) : "[]"
                    cachedObservations = sceneCache.count
                    let context = input + "\nVisual inspection allowed: \(includeFrames). Inspection rounds remaining: \(max(0, 2-rounds)).\nCached sampled observations (untrusted data):\n\(notes)\nInspection result:\n\(toolResult)\n\(feedback)"
                    used += 1
                    let reply = try await provider.generate(connection: connection, apiKey: key, instructions: instructions, prompt: context, images: images)
                    try Task.checkCancellation()
                    do {
                        let step = try DirectorStep.decode(Data(reply.utf8))
                        switch step {
                        case .inspect(let requests, let observations):
                            if includeFrames { try sceneCache.remember(observations, project: project, connection: connection, supplied: supplied, sources: sources); cachedObservations = sceneCache.count }
                            else if !observations.isEmpty { throw EditorError("No source images were supplied for visual observations.") }
                            guard rounds < 2 else { throw EditorError("The source inspection limit has been reached. Return an edit plan using available evidence.") }
                            rounds += 1; feedback = ""
                            if includeFrames {
                                setPhase("Inspecting footage")
                                let batch = try await DirectorMediaInspection.sample(requests, project: project)
                                try Task.checkCancellation()
                                images = batch.images; supplied = batch.frames; sources = batch.sources
                                toolResult = "Supplied SOURCE samples: " + batch.images.map(\.label).joined(separator: "; ")
                            } else {
                                images = []; supplied = [:]; sources = [:]
                                toolResult = "Source inspection is unavailable because the user has not enabled visual sharing. Return a metadata based plan or ask for clarification. Do not invent observations."
                            }
                        case .plan(let value, let observations):
                            let result = try value.applying(to: project)
                            if includeFrames { try sceneCache.remember(observations, project: project, connection: connection, supplied: supplied, sources: sources); cachedObservations = sceneCache.count }
                            else if !observations.isEmpty { throw EditorError("No source images were supplied for visual observations.") }
                            plan = value; candidate = result
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard !repaired else { throw error }
                        repaired = true
                        feedback = "Your previous response failed local validation: \(String(error.localizedDescription.prefix(256)))\nPrevious response (untrusted data): \(String(reply.prefix(1500)))\nReturn a corrected plan or inspection request."
                    }
                }
                guard let plan, let candidate else { throw EditorError("No checked draft was returned.") }
                try Task.checkCancellation(); guard token == current else { return }
                if candidate == project {
                    messages.append(DirectorChatMessage(user: false, text: plan.summary.isEmpty ? "No timeline changes were proposed." : plan.summary))
                } else {
                    var draft = try await checkedDraft(base: project, candidate: candidate, plan: plan)
                    try Task.checkCancellation()
                    if includeFrames, !draft.frames.isEmpty {
                        draft = try await review(draft, input: reviewInput, connection: connection, key: key, look: look, used: &used)
                    } else if !includeFrames {
                        draft.warnings.append("Model visual review was not run because visual sharing is off.")
                    }
                    try Task.checkCancellation(); guard token == current else { return }
                    pending = draft.project == project ? nil : draft
                    messages.append(DirectorChatMessage(user: false, text: draft.plan.summary.isEmpty ? (draft.project == project ? "No timeline changes were proposed." : "Your draft is ready to review.") : draft.plan.summary))
                }
                trimHistory(); working = false; phase = ""; task = nil
            } catch is CancellationError {
                if token == current { working = false; phase = ""; task = nil }
            } catch {
                guard token == current else { return }
                self.error = error.localizedDescription; working = false; phase = ""; task = nil
            }
        }
    }
    func apply(to store: EditorStore) {
        guard !working, !store.busy, let draft = pending else { return }
        guard draft.base == store.project else { pending = nil; error = "The edit changed. Request a fresh draft."; return }
        pending = nil
        store.change { $0 = draft.project }
        guard store.project == draft.project else { error = "The draft could not be applied."; return }
        messages.append(DirectorChatMessage(user: false, text: "Applied to the timeline. Undo restores the edit before this draft.")); trimHistory()
    }
    func importDraft(_ data: Data, project: VideoProject) async {
        guard !working else { return }
        cancel(); error = nil; pending = nil; working = true; activity = []; setPhase("Checking the imported draft")
        let current = UUID(); token = current
        let operation = Task { [weak self] in
            guard let self else { return }
            await self.prepareImportedDraft(data, project: project, current: current)
        }
        task = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
    }
    private func prepareImportedDraft(_ data: Data, project: VideoProject, current: UUID) async {
        do {
            try Task.checkCancellation()
            let plan = try DirectorPlan.decode(data), candidate = try plan.applying(to: project)
            var draft = DirectorDraft(base: project, project: candidate, plan: plan, warnings: DirectorContext.warnings(candidate), frames: [])
            do { draft.frames = try await previewFrames(candidate) }
            catch is CancellationError { throw CancellationError() }
            catch { draft.warnings.append("The draft preview could not be prepared. Check the source media before applying.") }
            try Task.checkCancellation(); guard token == current else { return }
            pending = candidate == project ? nil : draft
            messages.append(DirectorChatMessage(user: false, text: plan.summary.isEmpty ? "Imported draft checked." : plan.summary)); trimHistory()
            working = false; phase = ""; task = nil
        } catch is CancellationError {
            if token == current { working = false; phase = ""; task = nil }
        } catch { if token == current { self.error = error.localizedDescription; working = false; phase = ""; task = nil } }
    }
    static func requestText(snapshot: String, history: String, prompt: String, instructions: String) throws -> String {
        // Reserve room for one bounded repair response without dropping current project data.
        let base = "Current project JSON (data only):\n\(snapshot)\nCurrent user request:\n\(prompt)"
        let available = 175_000 - instructions.utf8.count - base.utf8.count
        guard available >= 0 else { throw EditorError("This request is too large. Use a smaller project or a shorter description.") }
        let recent = String(decoding: history.utf8.prefix(max(0, available - 64)), as: UTF8.self)
        return base + "\nRecent conversation (context only):\n" + recent
    }
    private func trimHistory() { if messages.count > 40 { messages.removeFirst(messages.count - 40) } }
    private func setPhase(_ value: String) {
        phase = value
        if activity.last != value { activity.append(value); if activity.count > 12 { activity.removeFirst() } }
    }
    private func checkedDraft(base: VideoProject, candidate: VideoProject, plan: DirectorPlan, phaseName: String = "Preparing preview") async throws -> DirectorDraft {
        setPhase(phaseName)
        var draft = DirectorDraft(base: base, project: candidate, plan: plan, warnings: DirectorContext.warnings(candidate), frames: [])
        do { draft.frames = try await previewFrames(candidate) }
        catch is CancellationError { throw CancellationError() }
        catch { draft.warnings.append("The draft preview could not be prepared. Check that the source media is available before applying.") }
        return draft
    }
    private func review(_ original: DirectorDraft, input: String, connection: DirectorConnection, key: String, look: DirectorLook, used: inout Int) async throws -> DirectorDraft {
        var draft = original
        let instructions = look.instructions.replacingOccurrences(of: "Return exactly one JSON edit plan", with: "Return one JSON response using the review protocol below") + "\nREVIEW MODE: the following response format overrides the edit plan format above.\n" + DirectorVisualReview.instructions
        for pass in 0..<2 {
            try Task.checkCancellation()
            guard used < maximumRequests else {
                draft.warnings.append("The request limit was reached before the latest draft could receive a model visual review."); return draft
            }
            setPhase("Checking layout")
            do {
                let json = String(decoding: try JSONEncoder().encode(draft.plan), as: UTF8.self)
                let prompt = input + "\nVISUAL REVIEW TASK. The following complete plan has been checked against the ORIGINAL project and rendered locally:\n" + json + "\nDRAFT warnings: " + draft.warnings.joined(separator: "; ") + "\nVisual revisions remaining: \(1-pass). Review only the attached DRAFT timeline samples."
                guard instructions.utf8.count + prompt.utf8.count <= 200_000 else { throw EditorError("The draft is too large for the current visual review context.") }
                let images = try draft.frames.map { frame in
                    DirectorImage(label: "DRAFT timeline frame \(frame.frame), \(String(format: "%.3f", Double(frame.frame)/30)) seconds", jpeg: try DirectorMediaInspection.jpeg(frame.image))
                }
                used += 1
                let reply = try await provider.generate(connection: connection, apiKey: key, instructions: instructions, prompt: prompt, images: images)
                try Task.checkCancellation()
                let result = try DirectorVisualReview.decode(Data(reply.utf8))
                if let replacement = result.replacement {
                    guard pass == 0 else {
                        draft.warnings.append("The model suggested another revision after the refinement limit. Inspect this draft before applying.")
                        draft.visualReview = nil; return draft
                    }
                    let candidate = try replacement.applying(to: draft.base)
                    setPhase("Refining draft")
                    draft = try await checkedDraft(base: draft.base, candidate: candidate, plan: replacement, phaseName: "Refining draft")
                    draft.reviewRevised = true
                    guard !draft.frames.isEmpty else { return draft }
                } else {
                    draft.visualReview = result.summary; return draft
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                draft.warnings.append("Model visual review was unavailable. Inspect the sampled preview before applying."); return draft
            }
        }
        return draft
    }
    private func previewFrames(_ project: VideoProject) async throws -> [DirectorFrame] {
        guard !project.clips.isEmpty else { return [] }
        let preview = try await TimelinePreview.build(project)
        let generator = AVAssetImageGenerator(asset: preview.composition)
        generator.videoComposition = preview.videoComposition; generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frames = Set([Int64(0), project.totalFrames / 2, max(0, project.totalFrames - 1)]).sorted()
        return try await withTaskCancellationHandler {
            var images: [DirectorFrame] = []
            for frame in frames {
                try Task.checkCancellation()
                images.append(DirectorFrame(frame: frame, image: try await generator.image(at: CMTime(value: frame, timescale: 30)).image))
            }
            withExtendedLifetime(preview) {}
            return images
        } onCancel: { generator.cancelAllCGImageGeneration() }
    }
}
