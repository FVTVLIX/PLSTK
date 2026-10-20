// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

/// A bounded editing request. It cannot read files, execute code, or publish media.
public enum DirectorAction: String, Codable, Sendable, CaseIterable {
    case addVisual = "add_visual", setVisual = "set_visual", removeVisual = "remove_visual"
    case splitVisual = "split_visual", setVisualFades = "set_visual_fades", setDissolve = "set_dissolve"
    case addTitle = "add_title", updateTitle = "update_title"
    case addAudio = "add_audio", setAudio = "set_audio", removeAudio = "remove_audio", setAudioFades = "set_audio_fades"
    case setCanvas = "set_canvas", renameProject = "rename_project"
}

public struct DirectorOperation: Codable, Equatable, Sendable {
    public var action: DirectorAction
    public var clipID: UUID?
    public var assetID: UUID?
    public var inFrame: Int64?
    public var outFrame: Int64?
    public var startFrame: Int64?
    public var lane: Int?
    public var opacity: Double?
    public var muted: Bool?
    public var volume: Double?
    public var transform: VisualTransform?
    public var fadeInFrames: Int64?
    public var fadeOutFrames: Int64?
    public var dissolveFrames: Int64?
    public var title: TextTitle?
    public var width: Int?
    public var height: Int?
    public var name: String?

    public init(action: DirectorAction, clipID: UUID? = nil, assetID: UUID? = nil,
                inFrame: Int64? = nil, outFrame: Int64? = nil, startFrame: Int64? = nil, lane: Int? = nil,
                opacity: Double? = nil, muted: Bool? = nil, volume: Double? = nil, transform: VisualTransform? = nil,
                fadeInFrames: Int64? = nil, fadeOutFrames: Int64? = nil, dissolveFrames: Int64? = nil,
                title: TextTitle? = nil, width: Int? = nil, height: Int? = nil, name: String? = nil) {
        self.action = action; self.clipID = clipID; self.assetID = assetID
        self.inFrame = inFrame; self.outFrame = outFrame; self.startFrame = startFrame; self.lane = lane
        self.opacity = opacity; self.muted = muted; self.volume = volume; self.transform = transform
        self.fadeInFrames = fadeInFrames; self.fadeOutFrames = fadeOutFrames; self.dissolveFrames = dissolveFrames
        self.title = title; self.width = width; self.height = height; self.name = name
    }

    fileprivate func checkBounds() throws {
        for frame in [inFrame, outFrame, startFrame, fadeInFrames, fadeOutFrames, dissolveFrames].compactMap({ $0 }) {
            guard (0..<30_000_000).contains(frame) else { throw EditorError("Director frame values must be between zero and 29999999.") }
        }
        if let lane { guard (0..<32).contains(lane) else { throw EditorError("Director visual tracks must be between zero and 31.") } }
        for value in [opacity, volume].compactMap({ $0 }) {
            guard value.isFinite, (0...1).contains(value) else { throw EditorError("Director opacity and volume must be between zero and one.") }
        }
        if let transform { guard transform.isValid else { throw EditorError("Director requested an invalid transform.") } }
        if let title { try title.validate() }
        if let name {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw EditorError("Choose a project name with 1 to 200 visible characters.")
            }
        }
        for dimension in [width, height].compactMap({ $0 }) {
            guard (2...16384).contains(dimension), dimension % 2 == 0 else { throw EditorError("Director canvas dimensions must be even numbers between 2 and 16384.") }
        }
        let complete: Bool
        switch action {
        case .addVisual, .addAudio: complete = assetID != nil
        case .setVisual, .removeVisual, .setVisualFades, .setAudio, .removeAudio, .setAudioFades: complete = clipID != nil
        case .splitVisual: complete = clipID != nil && inFrame != nil
        case .setDissolve: complete = clipID != nil && dissolveFrames != nil
        case .addTitle: complete = title != nil
        case .updateTitle: complete = clipID != nil && title != nil
        case .setCanvas: complete = width != nil && height != nil
        case .renameProject: complete = name != nil
        }
        guard complete else { throw EditorError("Director omitted a required field for \(action.rawValue).") }
        // Reject unused parameters so mistakes cannot silently become different edits.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        let fields: Set<String>
        switch action {
        case .addVisual, .setVisual: fields = ["clipID", "assetID", "inFrame", "outFrame", "startFrame", "lane", "opacity", "muted", "transform"]
        case .removeVisual, .removeAudio: fields = ["clipID"]
        case .splitVisual: fields = ["clipID", "inFrame"]
        case .setVisualFades, .setAudioFades: fields = ["clipID", "fadeInFrames", "fadeOutFrames"]
        case .setDissolve: fields = ["clipID", "dissolveFrames"]
        case .addTitle: fields = ["clipID", "title", "startFrame", "outFrame", "lane"]
        case .updateTitle: fields = ["clipID", "title"]
        case .addAudio, .setAudio: fields = ["clipID", "assetID", "inFrame", "outFrame", "startFrame", "lane", "volume", "muted"]
        case .setCanvas: fields = ["width", "height"]
        case .renameProject: fields = ["name"]
        }
        guard Set(object.keys).subtracting(fields.union(["action"])).isEmpty else {
            throw EditorError("Director included a field that does not apply to \(action.rawValue).")
        }
    }
}

public struct DirectorPlan: Codable, Equatable, Sendable {
    public var version: Int
    public var summary: String
    public var operations: [DirectorOperation]
    public init(version: Int = 1, summary: String = "", operations: [DirectorOperation] = []) {
        self.version = version; self.summary = summary; self.operations = operations
    }
    public static func decode(_ data: Data) throws -> DirectorPlan {
        guard data.count <= 262_144 else { throw EditorError("Director response exceeds the 256 KB limit.") }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EditorError("Director must return a JSON edit plan.") }
            try checkKeys(root, allowed: ["version", "summary", "operations"])
            guard let entries = root["operations"] as? [[String: Any]], entries.count <= 64 else { throw EditorError("Director plans support at most 64 operations.") }
            let allowed: Set<String> = ["action", "clipID", "assetID", "inFrame", "outFrame", "startFrame", "lane", "opacity", "muted", "volume", "transform", "fadeInFrames", "fadeOutFrames", "dissolveFrames", "title", "width", "height", "name"]
            for entry in entries {
                try checkKeys(entry, allowed: allowed)
                if let transform = entry["transform"] as? [String: Any] { try checkKeys(transform, allowed: ["x", "y", "scale", "rotation"]) }
                if let title = entry["title"] as? [String: Any] { try checkKeys(title, allowed: ["text", "style", "size", "color", "alignment"]) }
            }
            let result = try JSONDecoder().decode(DirectorPlan.self, from: data)
            try result.checkBounds()
            return result
        } catch let error as EditorError { throw error }
        catch { throw EditorError("Director returned an invalid edit plan. Check the response format and values.") }
    }
    private static func checkKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw EditorError("Director returned unsupported edit plan fields.") }
    }
    private func checkBounds() throws {
        guard version == 1 else { throw EditorError("Unsupported Director plan version.") }
        guard operations.count <= 64, summary.count <= 2000 else { throw EditorError("Director plan exceeds the operation or summary limit.") }
        for operation in operations { try operation.checkBounds() }
    }
    public func applying(to project: VideoProject) throws -> VideoProject {
        try checkBounds()
        try project.validate()
        guard !operations.isEmpty else { return project }
        var next = project
        let changesTiming = operations.contains { operation in
            switch operation.action {
            case .addVisual, .removeVisual, .splitVisual, .addTitle: return true
            case .setDissolve:
                guard let clip = project.clips.first(where: { $0.id == operation.clipID }) else { return true }
                return operation.dissolveFrames != clip.dissolveFrames
            case .setVisual:
                guard let clip = project.clips.first(where: { $0.id == operation.clipID }) else { return true }
                return (operation.inFrame.map { $0 != clip.inFrame } ?? false) ||
                    (operation.outFrame.map { $0 != clip.outFrame } ?? false) ||
                    (operation.startFrame.map { $0 != project.position(of: clip) } ?? false) ||
                    (operation.lane.map { $0 != clip.lane } ?? false)
            default: return false
            }
        }
        if changesTiming { next.materializePositions() }
        for operation in operations { try next.applyDirector(operation) }
        try next.validate()
        return next
    }

    public static let contract = """
    Return only one JSON object: {"version":1,"summary":"Describe the edit briefly","operations":[]}.
    No markdown, file paths, network requests, commands, arbitrary code, or extra fields. Maximum 64 operations, 256 KB JSON, and 2000 summary characters. Use only asset and clip UUIDs from the supplied project, or generate a unique clipID for a new clip. Operations execute in order as one atomic edit. The entire result must be valid.
    All times are integer frames at 30 fps. Frame values are 0 through 29999999. Source outFrame is exclusive. startFrame is a timeline position. Visual lane is 0 through 31, with higher lanes above lower lanes; audio lane is 0 or 1. Clips cannot overlap on a lane except through set_dissolve. Direct set operations can temporarily overlap when rearranging a batch. Complete rearrangements before title updates, splits, or dissolves, which validate their intermediate state.
    Each operation has an action and only its applicable fields:
    add_visual: assetID required; optional clipID, inFrame (default 0), outFrame (default source end, images 150), startFrame (default timeline end), lane (default 0), opacity (0 to 1, default 1), muted (default false), transform.
    set_visual: clipID required; optional assetID, inFrame, outFrame, startFrame, lane, opacity, muted, transform. Trimming fits existing fades to the new duration. Other edits preserve fades.
    remove_visual: clipID required. Does not close gaps.
    split_visual: clipID and inFrame required. Here inFrame means a LOCAL offset inside the selected clip, not a source frame. The second fragment gets a new generated ID.
    set_visual_fades: clipID required; optional fadeInFrames, fadeOutFrames (unspecified end is preserved). Their sum must fit the clip.
    set_dissolve: clipID and dissolveFrames required. The clip must immediately follow another on its visual lane. Overlaps those clips and shifts this and later clips on that lane earlier; zero removes the dissolve and restores their timing. Does not shift independent audio or other visual lanes. Finish rearranging before applying dissolves.
    add_title: title required; optional clipID, startFrame (default 0), outFrame (duration, default 150), lane (default free lane above overlapping visuals). Creates an editable title asset. title has text, style (simple, statement, caption), size (0.025 to 0.25 of canvas height), color (white, yellow, black), alignment (left, center, right). Supply all five title fields. Text is 1 to 1000 characters, at most eight lines.
    update_title: clipID and complete title required. Shared title assets are copied for independent editing.
    add_audio: assetID with audio required; optional clipID, inFrame (default 0), outFrame (default source end), startFrame (default 0), lane (default 0), volume (0 to 1, default 1), muted (default false).
    set_audio: clipID required; optional assetID, inFrame, outFrame, startFrame, lane, volume, muted. Trimming fits existing fades.
    remove_audio: clipID required. Does not close gaps.
    set_audio_fades: clipID required; optional fadeInFrames, fadeOutFrames; their sum must fit the clip.
    set_canvas: width and height required; even integers between 2 and 16384.
    rename_project: name required; 1 to 200 visible characters.
    transform has x,y (canvas pixel offsets, positive Y down, magnitude at most 32768), scale (0.05 to 4), rotation (degrees, -360 to 360). Supply all four fields.
    Example: {"version":1,"summary":"A gentle opening","operations":[{"action":"set_visual_fades","clipID":"00000000-0000-0000-0000-000000000001","fadeInFrames":15,"fadeOutFrames":15}]}
    """
}

private extension VideoProject {
    mutating func applyDirector(_ op: DirectorOperation) throws {
        func required<T>(_ value: T?) throws -> T {
            guard let value else { throw EditorError("Director omitted a required field for \(op.action.rawValue).") }; return value
        }
        func visualIndex() throws -> Int {
            let id = try required(op.clipID)
            guard let index = clips.firstIndex(where: { $0.id == id }) else { throw EditorError("Director referenced a visual clip that does not exist.") }; return index
        }
        func audioIndex() throws -> Int {
            let id = try required(op.clipID)
            guard let index = audioClips.firstIndex(where: { $0.id == id }) else { throw EditorError("Director referenced an audio clip that does not exist.") }; return index
        }
        func newID() throws -> UUID {
            let id = op.clipID ?? UUID()
            guard !clips.contains(where: { $0.id == id }), !audioClips.contains(where: { $0.id == id }) else { throw EditorError("Director requested a duplicate clip identifier.") }; return id
        }
        func asset(_ id: UUID) throws -> MediaAsset {
            guard let asset = assets.first(where: { $0.id == id }) else { throw EditorError("Director referenced an asset that does not exist.") }; return asset
        }
        func endFrame(_ source: MediaAsset) throws -> Int64 {
            let end = floor(source.duration * 30 + 0.0001)
            guard end.isFinite, end >= 1, end < 30_000_000 else { throw EditorError("Director source duration is outside the supported range.") }
            return source.isImage ? 150 : Int64(end)
        }
        func checkRange(_ start: Int64, _ end: Int64) throws {
            guard start >= 0, end > start, end < 30_000_000 else { throw EditorError("Director requested an invalid source range.") }
        }
        switch op.action {
        case .addVisual:
            let id = try newID(), media = try asset(required(op.assetID))
            guard !media.isAudioOnly else { throw EditorError("Choose a visual asset for add_visual.") }
            let first = op.inFrame ?? 0, last = try op.outFrame ?? endFrame(media), lane = op.lane ?? 0
            try checkRange(first, last)
            visualTrackCount = max(visualTrackCount, lane + 1)
            clips.append(Clip(id: id, assetID: media.id, inFrame: first, outFrame: last, muted: op.muted ?? false,
                              startFrame: op.startFrame ?? videoFrames, lane: lane, transform: op.transform ?? VisualTransform(), opacity: op.opacity ?? 1))
        case .setVisual:
            let i = try visualIndex()
            let first = op.inFrame ?? clips[i].inFrame, last = op.outFrame ?? clips[i].outFrame
            try checkRange(first, last)
            if let id = op.assetID { _ = try asset(id); clips[i].assetID = id }
            let trimmed = first != clips[i].inFrame || last != clips[i].outFrame
            clips[i].inFrame = first; clips[i].outFrame = last
            if trimmed { clips[i].fitVisualFades() }
            if let start = op.startFrame, start != position(of: clips[i]) { clips[i].startFrame = start }
            if let lane = op.lane { clips[i].lane = lane; visualTrackCount = max(visualTrackCount, lane + 1) }
            if let value = op.opacity { clips[i].opacity = value }
            if let value = op.muted { clips[i].muted = value }
            if let value = op.transform { clips[i].transform = value }
        case .removeVisual:
            let i = try visualIndex(); removeVisual(clips[i].id)
        case .splitVisual:
            let i = try visualIndex(); try split(clips[i].id, at: required(op.inFrame))
        case .setVisualFades:
            let i = try visualIndex()
            try clips[i].setVisualFades(fadeIn: op.fadeInFrames ?? clips[i].localFadeInFrames, fadeOut: op.fadeOutFrames ?? clips[i].localFadeOutFrames)
        case .setDissolve:
            let i = try visualIndex(); try setDissolve(clips[i].id, frames: required(op.dissolveFrames))
        case .addTitle:
            let id = try newID(), title = try required(op.title), start = op.startFrame ?? 0, duration = op.outFrame ?? 150
            try checkRange(0, duration)
            let highest = clips.filter { position(of: $0) < start + duration && position(of: $0) + $0.frames > start }.map(\.lane).max() ?? -1
            let lane = op.lane ?? (highest + 1)
            guard lane < 32 else { throw EditorError("Director needs a free visual track for the title.") }
            var media = MediaAsset(path: "", duration: Double(duration) / 30, width: width, height: height, isImage: true)
            media.title = title; assets.append(media)
            visualTrackCount = max(visualTrackCount, lane + 1)
            clips.append(Clip(id: id, assetID: media.id, inFrame: 0, outFrame: duration, startFrame: start, lane: lane))
        case .updateTitle:
            let i = try visualIndex(); try updateTitle(clips[i].id, to: required(op.title))
        case .addAudio:
            let id = try newID(), media = try asset(required(op.assetID))
            guard media.audioStream != nil else { throw EditorError("Director selected an asset without audio.") }
            let first = op.inFrame ?? 0, last = try op.outFrame ?? endFrame(media), lane = op.lane ?? 0
            try checkRange(first, last)
            guard lane < 2 else { throw EditorError("Director audio lane must be zero or one.") }
            audioClips.append(AudioClip(id: id, assetID: media.id, inFrame: first, outFrame: last, startFrame: op.startFrame ?? 0, lane: lane, volume: op.volume ?? 1, muted: op.muted ?? false))
        case .setAudio:
            let i = try audioIndex(), first = op.inFrame ?? audioClips[i].inFrame, last = op.outFrame ?? audioClips[i].outFrame
            try checkRange(first, last)
            if let id = op.assetID { _ = try asset(id); audioClips[i].assetID = id }
            let trimmed = first != audioClips[i].inFrame || last != audioClips[i].outFrame
            audioClips[i].inFrame = first; audioClips[i].outFrame = last
            if trimmed {
                let enter = min(audioClips[i].fadeInFrames, last - first), exit = min(audioClips[i].fadeOutFrames, last - first - enter)
                try audioClips[i].setFades(fadeIn: enter, fadeOut: exit)
            }
            if let start = op.startFrame { audioClips[i].startFrame = start }
            if let lane = op.lane { guard lane < 2 else { throw EditorError("Director audio lane must be zero or one.") }; audioClips[i].lane = lane }
            if let value = op.volume { audioClips[i].volume = value }
            if let value = op.muted { audioClips[i].muted = value }
        case .removeAudio:
            audioClips.remove(at: try audioIndex())
        case .setAudioFades:
            let i = try audioIndex()
            try audioClips[i].setFades(fadeIn: op.fadeInFrames ?? audioClips[i].localFadeInFrames, fadeOut: op.fadeOutFrames ?? audioClips[i].localFadeOutFrames)
        case .setCanvas:
            width = try required(op.width); height = try required(op.height)
        case .renameProject:
            name = try required(op.name)
        }
    }
}
