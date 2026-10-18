// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import AVKit
import Combine
import LocalVideoCore
import UniformTypeIdentifiers

@MainActor final class EditorStore: ObservableObject {
    @Published var project = VideoProject()
    @Published var snappingEnabled = true
    @Published var selectionRevision = 0
    @Published var selectedClip: UUID?
    @Published var selectedAudio: UUID?
    @Published var selectedAsset: UUID?
    @Published var fileURL: URL?
    @Published var dirty = false
    @Published var recoveryWarning: String?
    private var recoveryStarted = false
    private var recoveredEdit = false
    private var recovery: ProjectRecovery?
    private var recoveryWork: DispatchWorkItem?
    private var recoveryRevision = UUID()
    private let recoveryQueue = DispatchQueue(label: "studio.localvideo.recovery", qos: .utility)
    @Published var error: String?
    @Published var status = "Ready to import a local video"
    @Published var busy = false
    @Published var progress = 0.0
    @Published var player: AVPlayer?
    @Published var previewURL: URL?
    @Published var playheadFrame: Int64 = 0
    @Published var isPlaying = false
    @Published var previewLoading = false
    @Published var previewProblem: String?
    private var livePreview: TimelinePreview?
    @Published var canvasDraft: VisualTransform?
    private var canvasClip: UUID?
    private var previewTask: Task<Void, Never>?
    private var previewToken = UUID()
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    @Published var past: [VideoProject] = []
    @Published var future: [VideoProject] = []
    private var job: MediaJob?
    private var jobID = UUID()
    private let cache = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-\(UUID().uuidString)")

    var audioClip: AudioClip? { project.audioClips.first { $0.id == selectedAudio } }
    var clip: Clip? { project.clips.first { $0.id == selectedClip } }
    var asset: MediaAsset? { project.assets.first { $0.id == selectedAsset } }
    var sourceForClip: MediaAsset? { clip.flatMap { try? project.asset(for: $0) } }
    var canPreview: Bool { !busy && !project.clips.isEmpty }

    func change(_ edit: (inout VideoProject) throws -> Void) {
        guard !busy else { return }
        cancelCanvasTransform()
        do {
            var next = project
            next.materializePositions()
            try edit(&next); try next.validate()
            guard next != project else { return }
            let playbackChanged = next.clips != project.clips || next.audioClips != project.audioClips || next.videoVolume != project.videoVolume || next.assets != project.assets
                || next.width != project.width || next.height != project.height
            past.append(project); if past.count > 100 { past.removeFirst() }
            future.removeAll(); project = next; dirty = true
            status = "Edit updated"
            scheduleRecovery()
            if playbackChanged { refreshPreview() }
        } catch { self.error = error.localizedDescription }
    }
    func invalidatePreview() {
        cancelCanvasTransform(); livePreview = nil
        previewTask?.cancel(); previewTask = nil; previewToken = UUID(); previewLoading = false
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil; rateObserver = nil; itemObserver = nil
        player = nil; isPlaying = false; previewProblem = nil
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        previewURL = nil
    }
    var canTransformCanvas: Bool {
        guard !busy, !previewLoading, previewProblem == nil, livePreview != nil, let clip else { return false }
        return playheadFrame >= project.position(of: clip) && playheadFrame < project.position(of: clip) + clip.frames
    }
    func updateCanvasTransform(_ value: VisualTransform) {
        guard canTransformCanvas, value.isValid, let clip else { return }
        if canvasDraft == nil { NSApp.keyWindow?.makeFirstResponder(nil) }
        player?.pause()
        canvasClip = clip.id; canvasDraft = value
        player?.currentItem?.videoComposition = livePreview?.transforming(clip.id, to: value)
    }
    func cancelCanvasTransform() {
        guard canvasDraft != nil else { return }
        canvasDraft = nil; canvasClip = nil
        player?.currentItem?.videoComposition = livePreview?.videoComposition
    }
    func commitCanvasTransform() {
        guard let value = canvasDraft, let id = canvasClip, selectedClip == id else { cancelCanvasTransform(); return }
        cancelCanvasTransform()
        change { project in
            if let index = project.clips.firstIndex(where: { $0.id == id }) { project.clips[index].transform = value }
        }
    }
    var totalFrames: Int64 { project.totalFrames }
    var canSplitAtPlayhead: Bool {
        guard !busy else { return false }
        if let audio = audioClip { return playheadFrame > audio.startFrame && playheadFrame < audio.endFrame }
        guard let target = splitTarget else { return false }
        let start = project.position(of: target)
        return playheadFrame > start && playheadFrame < start + target.frames
    }
    private var splitTarget: Clip? {
        if let clip { return clip }
        return project.clips.filter { project.position(of: $0) <= playheadFrame && project.position(of: $0) + $0.frames > playheadFrame }.max { $0.lane < $1.lane }
    }
    func splitAtPlayhead() {
        guard canSplitAtPlayhead else { return }
        if let audio = audioClip {
            let offset = playheadFrame - audio.startFrame
            change { try $0.splitAudio(audio.id, at: offset) }
        } else if let target = splitTarget {
            let offset = playheadFrame - project.position(of: target)
            selectedClip = target.id; selectedAsset = target.assetID
            change { try $0.split(target.id, at: offset) }
        }
    }
    func refreshPreview() {
        invalidatePreview()
        playheadFrame = min(playheadFrame, max(0, totalFrames - 1))
        guard !project.clips.isEmpty else { return }
        let snapshot = project, token = UUID()
        previewToken = token; previewLoading = true
        previewTask = Task { [weak self] in
            do {
                let preview = try await TimelinePreview.build(snapshot)
                guard let self, !Task.isCancelled, self.previewToken == token else { return }
                self.previewLoading = false
                self.livePreview = preview
                self.installPlayer(preview.playerItem())
                self.status = "Live preview ready"
            } catch {
                guard let self, !Task.isCancelled, self.previewToken == token else { return }
                self.previewLoading = false
                self.previewProblem = "Live preview unavailable: \(error.localizedDescription) Use Render Preview."
                self.status = "Use Render Preview for this media"
            }
        }
    }
    private func installPlayer(_ item: AVPlayerItem) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self, self.player === player, time.seconds.isFinite else { return }
                self.playheadFrame = min(self.totalFrames, max(0, Int64((time.seconds * 30).rounded())))
            }
        }
        rateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self, weak player] _, _ in
            Task { @MainActor in
                guard let self, self.player === player else { return }
                self.isPlaying = (player?.rate ?? 0) != 0
            }
        }
        itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, self.player?.currentItem === item, item?.status == .failed else { return }
                self.previewProblem = "Playback failed. Use Render Preview. \(item?.error?.localizedDescription ?? "")"
                self.status = "Use Render Preview for this media"
            }
        }
        seek(toFrame: playheadFrame)
    }
    func snapTimelineFrame(_ frame: Int64, excluding id: UUID, scale: Double) -> Int64 {
        guard snappingEnabled else { return frame }
        var edges: [Int64] = [0, playheadFrame]
        for clip in project.clips where clip.id != id {
            edges += [project.position(of: clip), project.position(of: clip) + clip.frames]
        }
        for clip in project.audioClips where clip.id != id { edges += [clip.startFrame, clip.endFrame] }
        return TimelineSnapping.nearestFrame(frame, candidates: edges, tolerance: max(1, Int64(6 / max(0.1, scale) * 30)))
    }
    func seek(toFrame frame: Int64) {
        cancelCanvasTransform()
        playheadFrame = min(max(0, frame), max(0, totalFrames - 1))
        player?.seek(to: CMTime(value: playheadFrame, timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func togglePlayback() {
        cancelCanvasTransform()
        guard !busy, let player else { return }
        if player.rate != 0 { player.pause() }
        else {
            if playheadFrame >= totalFrames - 1 { seek(toFrame: 0) }
            player.play()
        }
    }
    func clearSelection() {
        cancelCanvasTransform()
        selectedClip = nil; selectedAudio = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    func selectClip(_ clip: Clip) {
        selectionRevision += 1
        NSApp.keyWindow?.makeFirstResponder(nil)
        selectedAudio = nil; selectedClip = clip.id; selectedAsset = clip.assetID
        seek(toFrame: project.position(of: clip))
    }

    func undo() {
        guard !busy, let previous = past.popLast() else { return }
        future.append(project); project = previous; dirty = true; scheduleRecovery(); refreshPreview()
    }
    func redo() {
        guard !busy, let next = future.popLast() else { return }
        past.append(project); project = next; dirty = true; scheduleRecovery(); refreshPreview()
    }
    func addAsset(_ id: UUID) {
        let audio = project.assets.first { $0.id == id }?.isAudioOnly == true
        let count = audio ? project.audioClips.count : project.clips.count
        change { if audio { try $0.appendAudio(id, at: playheadFrame) } else { try $0.insertVisual(id, at: playheadFrame) } }
        if audio, project.audioClips.count > count, let clip = project.audioClips.last { selectAudio(clip) }
        else if !audio { selectedAudio = nil; selectedClip = project.clips.last?.id }
    }
    func selectAudio(_ clip: AudioClip) {
        selectionRevision += 1
        NSApp.keyWindow?.makeFirstResponder(nil)
        selectedAudio = clip.id; selectedClip = nil; selectedAsset = clip.assetID
        seek(toFrame: clip.startFrame)
    }
    func updateAudio(_ id: UUID, start: Double, sourceIn: Double, sourceOut: Double, lane: Int, volume: Double, muted: Bool? = nil, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        guard [start, sourceIn, sourceOut, volume].allSatisfy({ $0.isFinite }),
              start >= 0, start <= 1_000_000, sourceIn >= 0, sourceOut <= 1_000_000 else { error = "Enter valid audio times."; return }
        let fadeTimes = [fadeIn, fadeOut].compactMap { $0 }
        guard fadeTimes.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) else { error = "Enter valid fade durations."; return }
        change { project in
            guard let i = project.audioClips.firstIndex(where: { $0.id == id }) else { return }
            let original = project.audioClips[i]
            project.audioClips[i].startFrame = Int64((start * 30).rounded())
            project.audioClips[i].inFrame = Int64((sourceIn * 30).rounded())
            project.audioClips[i].outFrame = Int64((sourceOut * 30).rounded())
            project.audioClips[i].lane = lane; project.audioClips[i].volume = volume
            if let muted { project.audioClips[i].muted = muted }
            let entering = fadeIn.map { Int64(($0 * 30).rounded()) } ?? original.fadeInFrames
            let leaving = fadeOut.map { Int64(($0 * 30).rounded()) } ?? original.fadeOutFrames
            if entering != original.fadeInFrames || leaving != original.fadeOutFrames {
                try project.audioClips[i].setFades(fadeIn: entering, fadeOut: leaving)
            } else if project.audioClips[i].inFrame != original.inFrame || project.audioClips[i].outFrame != original.outFrame {
                let length = max(0, project.audioClips[i].frames)
                let clampedIn = min(length, entering)
                try project.audioClips[i].setFades(fadeIn: clampedIn, fadeOut: min(length - clampedIn, leaving))
            }
        }
    }
    func setAudioFades(_ id: UUID, fadeIn: Int64, fadeOut: Int64) {
        change { project in
            guard let index = project.audioClips.firstIndex(where: { $0.id == id }) else { return }
            try project.audioClips[index].setFades(fadeIn: fadeIn, fadeOut: fadeOut)
        }
    }
    func moveAudio(_ id: UUID, to frame: Int64) {
        change { project in
            guard let i = project.audioClips.firstIndex(where: { $0.id == id }) else { return }
            project.audioClips[i].startFrame = max(0, min(30_000_000, frame))
        }
    }
    func removeAudio() {
        guard let id = selectedAudio else { return }
        change { $0.audioClips.removeAll { $0.id == id } }; selectedAudio = nil
    }
    func removeClip() {
        if selectedAudio != nil { removeAudio(); return }
        guard let id = selectedClip else { return }
        change { $0.clips.removeAll { $0.id == id } }; selectedClip = nil
    }
    func duplicateClip() {
        guard var copy = clip else { return }
        copy.startFrame = project.position(of: copy); copy.id = UUID()
        change { project in
            copy.lane = try project.availableVisualLane(at: copy.startFrame!, frames: copy.frames)
            project.clips.append(copy)
        }
        if let added = project.clips.first(where: { $0.id == copy.id }) { selectClip(added) }
    }
    func placeVisual(_ id: UUID, at frame: Int64, lane: Int) {
        change { try $0.placeVisual(id, at: frame, lane: lane) }
    }
    func addVisualTrack() {
        guard project.visualTrackCount < 32 else { return }
        change { $0.visualTrackCount += 1 }
    }
    func trimVisual(_ id: UUID, edge: TrimEdge, delta: Int64) {
        change { project in
            var replacement = try project.trimmedClip(id, edge: edge, delta: delta)
            if let index = project.clips.firstIndex(where: { $0.id == id }) {
                if edge == .start { replacement.startFrame = project.position(of: project.clips[index]) + replacement.inFrame - project.clips[index].inFrame }
                project.clips[index] = replacement
            }
        }
    }
    func trim(start: Double, end: Double) {
        guard let selectedClip, start.isFinite, end.isFinite, start >= 0, end < 1_000_000 else {
            error = "Enter valid trim times in seconds."; return
        }
        change { project in
            guard let i = project.clips.firstIndex(where: { $0.id == selectedClip }) else { return }
            project.clips[i].inFrame = Int64((start * 30).rounded())
            project.clips[i].outFrame = Int64((end * 30).rounded())
        }
    }
    func importMedia() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.message = "Import local video, audio, PNG or JPEG images. Media stays at its original location."
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL], addToTimeline: Bool = false) {
        guard !busy, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return }
        let insertionFrame = playheadFrame
        let task = MediaJob(); job = task; busy = true; status = "Reading media…"
        Task {
            defer { busy = false; job = nil }
            do {
                let assets = try await Task.detached { try urls.map { try MediaProbe.read($0, job: task) } }.value
                busy = false
                var addedVideoID: UUID?
                var addedAudioID: UUID?
                change { project in
                    for asset in assets {
                        let existing = project.assets.first { $0.path == asset.path }
                        if existing == nil { project.assets.append(asset) }
                        if addToTimeline {
                            let id = existing?.id ?? asset.id
                            if asset.isAudioOnly {
                                try project.appendAudio(id, at: insertionFrame)
                                addedAudioID = project.audioClips.last?.id
                                addedVideoID = nil
                            } else {
                                try project.insertVisual(id, at: insertionFrame)
                                addedVideoID = project.clips.last?.id
                                addedAudioID = nil
                            }
                        }
                    }
                }
                // change commits atomically and reports validation errors itself.
                // Select only an insertion that actually reached the project.
                if addToTimeline {
                    if let id = addedAudioID, let clip = project.audioClips.first(where: { $0.id == id }) {
                        selectAudio(clip)
                    } else if let id = addedVideoID, let clip = project.clips.first(where: { $0.id == id }) {
                        selectClip(clip)
                    } else {
                        status = "Import failed"
                        return
                    }
                }
                guard assets.allSatisfy({ asset in project.assets.contains { $0.path == asset.path } }) else {
                    status = "Import failed"
                    return
                }
                selectedAsset = assets.last.flatMap { last in project.assets.first { $0.path == last.path }?.id }
                status = "Imported \(assets.count) media file(s)"
            } catch is CancellationError { status = "Import cancelled" }
            catch { self.error = error.localizedDescription; status = "Import failed" }
        }
    }
    func relink() {
        guard let original = asset, !busy else { return }
        let panel = NSOpenPanel(); panel.message = "Locate replacement for \(original.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let task = MediaJob(); job = task; busy = true; status = "Checking replacement media…"
        Task {
            defer { busy = false; job = nil }
            do {
                var replacement = try await Task.detached { try MediaProbe.read(url, job: task) }.value
                replacement.id = original.id
                busy = false
                change { project in
                    if let i = project.assets.firstIndex(where: { $0.id == original.id }) { project.assets[i] = replacement }
                }
            } catch is CancellationError { status = "Relink cancelled" }
            catch { self.error = error.localizedDescription }
        }
    }
    @discardableResult func confirmDiscard() -> Bool {
        if busy {
            let alert = NSAlert(); alert.messageText = "A media job is running"
            alert.informativeText = "Cancel the job before opening another project or closing the editor."
            alert.runModal(); return false
        }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save your changes?"
        alert.informativeText = "Your project has unsaved edits."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func newProject() {
        guard confirmDiscard() else { return }
        guard clearRecovery() else { return }
        recoveredEdit = false
        invalidatePreview(); project = VideoProject(); fileURL = nil; selectedClip = nil; selectedAudio = nil; selectedAsset = nil
        dirty = false; past = []; future = []; playheadFrame = 0; status = "New local project"
    }
    func openProject() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "localvideo") ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try ProjectFile.load(url)
            guard clearRecovery() else { return }
            recoveredEdit = false
            invalidatePreview(); project = loaded; fileURL = url; dirty = false
            selectedAudio = nil; selectedClip = loaded.clips.first?.id; selectedAsset = loaded.assets.first?.id; past = []; future = []
            let missing = loaded.assets.filter { !$0.isTitle && !FileManager.default.isReadableFile(atPath: $0.path) }.count
            status = missing > 0 ? "\(missing) missing asset(s) · select media and Relink" : "Project opened"
            playheadFrame = 0; refreshPreview()
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func save(as saveAs: Bool = false) -> Bool {
        guard !busy else { return false }
        var target = fileURL
        if saveAs || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "localvideo") ?? .json]
            panel.nameFieldStringValue = project.name + (recoveredEdit ? " recovered" : "") + ".localvideo"
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            target = url
        }
        guard let target else { return false }
        do {
            try ProjectFile.save(project, to: target)
            fileURL = target; dirty = false; recoveredEdit = false
            _ = clearRecovery()
            status = "Saved \(target.lastPathComponent)"; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func buildPreview() {
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            render(to: cache.appendingPathComponent(UUID().uuidString + ".mp4"), preview: true)
        } catch { self.error = error.localizedDescription }
    }
    func exportVideo() {
        guard canPreview else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = project.name + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        render(to: url, preview: false)
    }
    private func render(to url: URL, preview: Bool) {
        guard canPreview else { return }
        let snapshot = project, task = MediaJob(), token = UUID()
        previewTask?.cancel(); previewToken = UUID(); previewLoading = false
        player?.pause()
        job = task; jobID = token; busy = true; progress = 0
        status = preview ? "Rendering preview locally…" : "Exporting MP4 locally…"
        Task {
            defer { busy = false; job = nil }
            do {
                try await Task.detached {
                    try VideoRenderer.render(snapshot, to: url, job: task) { value in
                        Task { @MainActor [weak self] in
                            guard let self, self.jobID == token, self.busy else { return }
                            self.progress = value
                        }
                    }
                }.value
                progress = 1
                if preview {
                    invalidatePreview(); previewURL = url
                    installPlayer(AVPlayerItem(url: url))
                    status = "Preview ready · rendered from the current timeline"
                } else {
                    status = "Exported \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch is CancellationError { status = "Render cancelled · existing output preserved" }
            catch { self.error = error.localizedDescription; status = "Render failed" }
        }
    }
    func cancel() { job?.cancel(); status = "Cancelling…" }
    func cleanup() { _ = clearRecovery(); job?.cancel(); invalidatePreview(); MediaVisualCache.shared.stopWorkers(); Task { await MediaVisualCache.shared.cancelAll() }; try? FileManager.default.removeItem(at: cache) }
}

// Recovery uses its own serial writer so delayed edits cannot resurrect a discarded copy.
extension EditorStore {
    private var recoveryDirectory: URL {
        // An isolated directory allows native verification without touching real recovery data.
        if let path = ProcessInfo.processInfo.environment["PLSTK_RECOVERY_DIRECTORY"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PLSTK/Recovery", isDirectory: true)
    }

    func startRecovery() {
        guard !recoveryStarted else { return }
        recoveryStarted = true
        guard prepareRecovery() else { return }
        offerRecovery(automatically: true)
    }

    private func prepareRecovery() -> Bool {
        if recovery != nil { return true }
        do {
            let directory = recoveryDirectory
            recovery = try recoveryQueue.sync { try ProjectRecovery(directory: directory) }
            recoveryWarning = nil
            return true
        } catch {
            recoveryWarning = "Recovery is unavailable. Save your project to keep your edits."
            return false
        }
    }

    private func cancelRecoveryWrite() {
        recoveryWork?.cancel(); recoveryWork = nil; recoveryRevision = UUID()
    }

    private func scheduleRecovery() {
        cancelRecoveryWrite()
        guard dirty, prepareRecovery(), let recovery else { return }
        let snapshot = RecoverySnapshot(project: project, originalFileURL: fileURL), revision = recoveryRevision
        let work = DispatchWorkItem { [weak self] in
            do {
                try recovery.write(snapshot)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.recoveryRevision == revision else { return }
                    self.recoveryWarning = nil
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.recoveryRevision == revision else { return }
                    self.recoveryWarning = "Recovery could not be updated. Save your project to keep your latest edits."
                }
            }
        }
        recoveryWork = work
        recoveryQueue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func flushRecovery() {
        cancelRecoveryWrite()
        guard dirty, prepareRecovery(), let recovery else { return }
        do {
            let snapshot = RecoverySnapshot(project: project, originalFileURL: fileURL)
            try recoveryQueue.sync { try recovery.write(snapshot) }
            recoveryWarning = nil
        } catch { recoveryWarning = "Recovery could not be updated. Save your project to keep your latest edits." }
    }

    @discardableResult private func clearRecovery() -> Bool {
        cancelRecoveryWrite()
        guard let recovery else { return true }
        do {
            try recoveryQueue.sync { try recovery.clear() }
            recoveryWarning = nil
            return true
        } catch {
            recoveryWarning = "The previous recovery copy could not be removed. Try again before changing projects."
            return false
        }
    }

    func offerRecovery(automatically: Bool = false) {
        guard !busy, prepareRecovery(), let recovery else { return }
        do {
            let scan = try recoveryQueue.sync { try recovery.scan() }
            guard let candidate = scan.candidates.first else {
                if scan.unreadableCount > 0 {
                    recoveryWarning = "A recovery copy could not be read. It remains in the recovery folder."
                } else if !automatically {
                    let alert = NSAlert(); alert.messageText = "No recovery copies available"
                    alert.informativeText = "Edits from an unexpected quit will appear here. Copies belonging to another open editor stay with that editor."
                    alert.runModal()
                }
                return
            }
            let snapshot = candidate.snapshot
            let alert = NSAlert()
            alert.messageText = "Recover your edit?"
            alert.icon = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Project recovery")
            let date = snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened)
            alert.informativeText = "\(snapshot.project.name)\nA local recovery copy from \(date) is available. Your saved project will stay unchanged."
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Not Now")
            alert.addButton(withTitle: "Discard Copy")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard confirmDiscard() else { return }
                cancelRecoveryWrite()
                // Secure the recovered state in this session before consuming the old copy.
                try recoveryQueue.sync { try recovery.write(snapshot) }
                invalidatePreview(); project = snapshot.project; fileURL = nil; recoveredEdit = true; dirty = true
                selectedAudio = nil; selectedClip = project.clips.first?.id; selectedAsset = project.assets.first?.id
                past = []; future = []; playheadFrame = 0
                do {
                    try recoveryQueue.sync { try recovery.discard(candidate) }
                    recoveryWarning = nil
                } catch { recoveryWarning = "Your edit was recovered. The earlier recovery copy could not be removed." }
                refreshPreview()
                status = "Edit recovered · Save to keep a project copy"
            case .alertThirdButtonReturn:
                try recoveryQueue.sync { try recovery.discard(candidate) }
            default: break // Not Now leaves the copy available from the File menu.
            }
        } catch { recoveryWarning = "Recovery could not be opened. Your existing copies remain on this Mac." }
    }

    func retryRecovery() {
        if dirty { flushRecovery() }
        else if prepareRecovery(), clearRecovery() { offerRecovery(automatically: true) }
    }

    func revealRecoveryCopies() {
        NSWorkspace.shared.open(recoveryDirectory)
    }
}
