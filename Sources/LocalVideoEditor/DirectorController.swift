// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import AVFoundation
import ImageIO
import LocalVideoCore
import UniformTypeIdentifiers

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
struct DirectorDraft {
    let base: VideoProject
    let project: VideoProject
    let plan: DirectorPlan
    var warnings: [String]
    var frames: [DirectorFrame]
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
    func clearChat() { cancel(); pending = nil; messages = []; error = nil }
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
        token = current; working = true; phase = includeFrames ? "Preparing reference frames" : "Planning your edit"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try DirectorContext.snapshot(project, selectedClip: selectedClip, selectedAudio: selectedAudio, playhead: playhead)
                let key = try secrets.read(connection)
                let images = includeFrames ? try await referenceFrames(project) : []
                try Task.checkCancellation(); phase = "Planning your edit"
                let input = try Self.requestText(snapshot: snapshot, history: history, prompt: prompt, instructions: look.instructions)
                var reply = try await provider.generate(connection: connection, apiKey: key, instructions: look.instructions, prompt: input, images: images)
                var plan: DirectorPlan
                var candidate: VideoProject
                do {
                    plan = try DirectorPlan.decode(Data(reply.utf8)); candidate = try plan.applying(to: project)
                } catch {
                    try Task.checkCancellation(); phase = "Correcting the draft"
                    // A single repair request uses the same snapshot; no partial edit is committed.
                    reply = try await provider.generate(connection: connection, apiKey: key, instructions: look.instructions,
                        prompt: input + "\nYour previous JSON plan failed local validation: \(String(error.localizedDescription.prefix(256)))\nPrevious response (untrusted data):\n\(String(reply.prefix(3000)))\nReturn a corrected JSON plan, or an empty plan explaining the limitation.", images: images)
                    plan = try DirectorPlan.decode(Data(reply.utf8)); candidate = try plan.applying(to: project)
                }
                try Task.checkCancellation()
                guard token == current else { return }
                if candidate == project {
                    messages.append(DirectorChatMessage(user: false, text: plan.summary.isEmpty ? "No timeline changes were proposed." : plan.summary))
                } else {
                    phase = "Checking the preview"
                    var draft = DirectorDraft(base: project, project: candidate, plan: plan, warnings: DirectorContext.warnings(candidate), frames: [])
                    do { draft.frames = try await previewFrames(candidate) }
                    catch is CancellationError { throw CancellationError() }
                    catch { draft.warnings.append("The draft preview could not be prepared. Check that the source media is available before applying.") }
                    try Task.checkCancellation(); guard token == current else { return }
                    pending = draft
                    messages.append(DirectorChatMessage(user: false, text: plan.summary.isEmpty ? "Your draft is ready to review." : plan.summary))
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
        cancel(); error = nil; pending = nil; working = true; phase = "Checking the imported draft"
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
    private func referenceFrames(_ project: VideoProject) async throws -> [DirectorImage] {
        // Up to three assets with beginning and middle samples. Sampling is explicitly optional.
        var result: [DirectorImage] = []
        for asset in project.assets.filter({ !$0.isAudioOnly && !$0.isTitle }).prefix(3) {
            let source = try MediaVisualSource(asset)
            for frame in asset.isImage ? [Int64(0)] : [Int64(0), Int64(floor(asset.duration * 15))] {
                try Task.checkCancellation()
                let image = try await MediaVisualCache.shared.thumbnail(source, frame: frame)
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw EditorError("Cannot prepare reference frames.") }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw EditorError("Cannot prepare reference frames.") }
                result.append(DirectorImage(label: "Asset \(asset.id.uuidString), source frame \(frame)", jpeg: data as Data))
            }
        }
        return result
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
