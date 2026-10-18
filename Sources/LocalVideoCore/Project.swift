// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

public struct EditorError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var duration: Double
    public var width: Int
    public var height: Int
    public var rotation: Int
    public var frameRate: Double
    public var videoStream: Int
    public var audioStream: Int?
    public var title: TextTitle?
    public var isTitle: Bool { title != nil }
    public var isImage: Bool { image == true || isTitle }
    private var image: Bool?
    public var isAudioOnly: Bool { videoStream == -1 }
    public var name: String { title.map { String($0.text.prefix(60)).replacingOccurrences(of: "\n", with: " ") } ?? URL(fileURLWithPath: path).lastPathComponent }

    public init(id: UUID = UUID(), path: String, duration: Double, width: Int, height: Int,
                rotation: Int = 0, frameRate: Double = 30, videoStream: Int = 0, audioStream: Int? = nil, isImage: Bool = false) {
        self.id = id; self.path = path; self.duration = duration; self.width = width
        self.height = height; self.rotation = rotation; self.frameRate = frameRate
        self.videoStream = videoStream; self.audioStream = audioStream; self.image = isImage ? true : nil
    }
}

/// All clip times are integral frames in the project's fixed 30 fps timebase.
public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public var opacity: Double = 1
    public var imageTransparency = true
    public var transform = VisualTransform()
    public var startFrame: Int64?
    public var lane: Int = 0
    public var muted = false
    public var id: UUID = UUID()
    public var assetID: UUID
    public var inFrame: Int64
    public var outFrame: Int64
    public var frames: Int64 { outFrame - inFrame }
    public var startSeconds: Double { Double(inFrame) / 30 }
    public var duration: Double { Double(frames) / 30 }
    public init(id: UUID = UUID(), assetID: UUID, inFrame: Int64, outFrame: Int64, muted: Bool = false, startFrame: Int64? = nil, lane: Int = 0, transform: VisualTransform = VisualTransform(), opacity: Double = 1, imageTransparency: Bool = true) {
        self.id = id; self.assetID = assetID; self.inFrame = inFrame; self.outFrame = outFrame; self.muted = muted; self.startFrame = startFrame; self.lane = lane; self.transform = transform; self.opacity = opacity; self.imageTransparency = imageTransparency
    }
    private enum CodingKeys: String, CodingKey { case id, assetID, inFrame, outFrame, muted, startFrame, lane, transform, opacity, imageTransparency }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); assetID = try values.decode(UUID.self, forKey: .assetID)
        inFrame = try values.decode(Int64.self, forKey: .inFrame); outFrame = try values.decode(Int64.self, forKey: .outFrame)
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        startFrame = try values.decodeIfPresent(Int64.self, forKey: .startFrame)
        lane = try values.decodeIfPresent(Int.self, forKey: .lane) ?? 0
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        // Missing in versions 1–5: preserve their opaque fitted image canvas.
        imageTransparency = try values.decodeIfPresent(Bool.self, forKey: .imageTransparency) ?? false
        transform = try values.decodeIfPresent(VisualTransform.self, forKey: .transform) ?? VisualTransform()
    }
}

public struct AudioClip: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var assetID: UUID
    public var inFrame: Int64
    public var outFrame: Int64
    public var startFrame: Int64
    public var lane: Int
    public var volume: Double
    public var muted: Bool
    public var fadeInFrames: Int64 = 0
    public var fadeOutFrames: Int64 = 0
    public var fadeSourceInFrame: Int64?
    public var fadeSourceOutFrame: Int64?
    public var effectiveVolume: Double { muted ? 0 : volume }
    public var frames: Int64 { outFrame - inFrame }
    public var endFrame: Int64 { startFrame + frames }
    public init(id: UUID = UUID(), assetID: UUID, inFrame: Int64, outFrame: Int64,
                startFrame: Int64 = 0, lane: Int = 0, volume: Double = 1, muted: Bool = false, fadeInFrames: Int64 = 0, fadeOutFrames: Int64 = 0) {
        self.id = id; self.assetID = assetID; self.inFrame = inFrame; self.outFrame = outFrame
        self.startFrame = startFrame; self.lane = lane; self.volume = volume; self.muted = muted
        self.fadeInFrames = fadeInFrames; self.fadeOutFrames = fadeOutFrames
    }
    private enum CodingKeys: String, CodingKey { case id, assetID, inFrame, outFrame, startFrame, lane, volume, muted, fadeInFrames, fadeOutFrames, fadeSourceInFrame, fadeSourceOutFrame }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); assetID = try values.decode(UUID.self, forKey: .assetID)
        inFrame = try values.decode(Int64.self, forKey: .inFrame); outFrame = try values.decode(Int64.self, forKey: .outFrame)
        startFrame = try values.decode(Int64.self, forKey: .startFrame); lane = try values.decode(Int.self, forKey: .lane)
        fadeInFrames = try values.decodeIfPresent(Int64.self, forKey: .fadeInFrames) ?? 0
        fadeOutFrames = try values.decodeIfPresent(Int64.self, forKey: .fadeOutFrames) ?? 0
        fadeSourceInFrame = try values.decodeIfPresent(Int64.self, forKey: .fadeSourceInFrame)
        fadeSourceOutFrame = try values.decodeIfPresent(Int64.self, forKey: .fadeSourceOutFrame)
        volume = try values.decode(Double.self, forKey: .volume); muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

public struct VideoProject: Codable, Equatable, Sendable {
    public var version = 8
    public var visualTrackCount = 1
    public var name = "Untitled edit"
    public var width = 1280
    public var height = 720
    public var assets: [MediaAsset] = []
    public var clips: [Clip] = []
    public var audioClips: [AudioClip] = []
    public var videoVolume: Double = 1
    public init() {}
    private enum CodingKeys: String, CodingKey { case visualTrackCount, version, name, width, height, assets, clips, audioClips, videoVolume }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard (1...8).contains(storedVersion) else { throw EditorError("Unsupported project version: \(storedVersion).") }
        version = 8
        name = try values.decode(String.self, forKey: .name)
        width = try values.decode(Int.self, forKey: .width); height = try values.decode(Int.self, forKey: .height)
        assets = try values.decode([MediaAsset].self, forKey: .assets)
        clips = try values.decode([Clip].self, forKey: .clips)
        visualTrackCount = try values.decodeIfPresent(Int.self, forKey: .visualTrackCount) ?? max(1, (clips.map(\.lane).max() ?? 0) + 1)
        if storedVersion >= 2 {
            audioClips = try values.decode([AudioClip].self, forKey: .audioClips)
            videoVolume = try values.decode(Double.self, forKey: .videoVolume)
        }
    }
    public func position(of clip: Clip) -> Int64 {
        if let start = clip.startFrame { return start }
        var cursor: Int64 = 0
        for entry in clips where entry.lane == clip.lane {
            if entry.id == clip.id { return cursor }
            cursor = max(cursor, (entry.startFrame ?? cursor) + entry.frames)
        }
        return cursor
    }
    public mutating func materializePositions() {
        let positions = clips.map { position(of: $0) }
        for index in clips.indices { clips[index].startFrame = positions[index] }
    }
    public var videoFrames: Int64 { clips.map { position(of: $0) + $0.frames }.max() ?? 0 }
    public var totalFrames: Int64 { max(videoFrames, audioClips.map(\.endFrame).max() ?? 0) }
    public var duration: Double { Double(totalFrames) / 30 }
    public func asset(for clip: Clip) throws -> MediaAsset {
        guard let asset = assets.first(where: { $0.id == clip.assetID }) else {
            throw EditorError("A timeline clip refers to a missing asset.")
        }
        return asset
    }
    public func validate(requireMedia: Bool = false) throws {
        guard version == 8 else { throw EditorError("Unsupported project version: \(version).") }
        guard width >= 2, height >= 2, width <= 16384, height <= 16384,
              width % 2 == 0, height % 2 == 0 else {
            throw EditorError("Output dimensions must be even numbers between 2 and 16384.")
        }
        guard Set(assets.map(\.id)).count == assets.count,
              Set((clips.map(\.id) + audioClips.map(\.id))).count == clips.count + audioClips.count else { throw EditorError("Duplicate project identifiers.") }
        guard clips.allSatisfy({ $0.inFrame >= 0 && $0.outFrame > $0.inFrame && $0.outFrame < 30_000_000 && ($0.startFrame.map { (0...30_000_000).contains($0) } ?? true) }) else { throw EditorError("Invalid visual clip range or position.") }
        for asset in assets {
            try asset.title?.validate()
            guard asset.duration.isFinite, asset.duration > 0, asset.duration < 1_000_000,
                  (asset.isAudioOnly ? (asset.width == 0 && asset.height == 0 && asset.audioStream != nil) : (asset.width > 0 && asset.height > 0 && asset.videoStream >= 0)),
                  (asset.audioStream.map({ $0 >= 0 }) ?? true),
                  (!asset.isImage || (!asset.isAudioOnly && asset.audioStream == nil)) else { throw EditorError("Invalid media metadata.") }
        }
        guard (1...32).contains(visualTrackCount) else { throw EditorError("Use between 1 and 32 visual tracks.") }
        for clip in clips {
            guard clip.opacity.isFinite, (0...1).contains(clip.opacity) else { throw EditorError("Opacity must be between 0% and 100%.") }
            guard clip.transform.isValid else { throw EditorError("Transform requires finite offsets, scale 5–400%, and rotation between −360° and 360°.") }
            guard (0..<visualTrackCount).contains(clip.lane), position(of: clip) >= 0, position(of: clip) <= 30_000_000 else { throw EditorError("Invalid visual clip placement.") }
            let media = try asset(for: clip)
            guard !media.isAudioOnly, clip.inFrame >= 0, clip.outFrame > clip.inFrame,
                  Double(clip.outFrame) <= (media.isImage ? 29_999_999 : floor(media.duration * 30 + 0.0001)) else {
                throw EditorError("A trim is outside the source: \(media.name). Use at least one frame.")
            }
        }
        for lane in 0..<visualTrackCount {
            let ordered = clips.filter { $0.lane == lane }.sorted { position(of: $0) < position(of: $1) }
            for pair in zip(ordered, ordered.dropFirst()) where position(of: pair.0) + pair.0.frames > position(of: pair.1) {
                throw EditorError("Visual clips overlap on the same track. Choose another track.")
            }
        }
        guard videoVolume.isFinite, (0...1).contains(videoVolume) else { throw EditorError("Volume must be between 0 and 100 percent.") }
        for clip in audioClips {
            guard clip.hasValidFades else { throw EditorError("Audio fades must fit inside the clip and cannot overlap.") }
            guard let media = assets.first(where: { $0.id == clip.assetID }), media.audioStream != nil,
                  clip.inFrame >= 0, clip.outFrame > clip.inFrame,
                  Double(clip.outFrame) <= floor(media.duration * 30 + 0.0001),
                  clip.startFrame >= 0, clip.startFrame <= 30_000_000, (0..<2).contains(clip.lane),
                  clip.volume.isFinite, (0...1).contains(clip.volume) else { throw EditorError("Invalid audio clip range, lane or volume.") }
        }
        for lane in 0..<2 {
            let ordered = audioClips.filter { $0.lane == lane }.sorted { $0.startFrame < $1.startFrame }
            for pair in zip(ordered, ordered.dropFirst()) where pair.0.endFrame > pair.1.startFrame {
                throw EditorError("Audio clips overlap on the same lane. Move one to the other audio lane.")
            }
        }
        if requireMedia {
            for asset in assets where clips.contains(where: { $0.assetID == asset.id }) || audioClips.contains(where: { $0.assetID == asset.id }) {
                guard asset.isTitle || FileManager.default.isReadableFile(atPath: asset.path) else {
                    throw EditorError("Missing media: \(asset.path). Select the asset and use Relink.")
                }
            }
        }
    }
    public mutating func append(_ assetID: UUID) throws {
        guard let asset = assets.first(where: { $0.id == assetID }) else { throw EditorError("Select media first.") }
        if asset.isAudioOnly { try appendAudio(assetID); return }
        let clip = Clip(assetID: assetID, inFrame: 0, outFrame: Int64(floor(asset.duration * 30)))
        clips.append(clip)
        do { try validate() } catch { clips.removeLast(); throw error }
    }
    public mutating func appendAudio(_ assetID: UUID, at frame: Int64 = 0) throws {
        guard let asset = assets.first(where: { $0.id == assetID }), asset.audioStream != nil else { throw EditorError("This media has no audio.") }
        let frames = Int64(floor(asset.duration * 30))
        let start = max(0, frame)
        let lane = (0..<2).first { lane in
            !audioClips.contains { $0.lane == lane && $0.startFrame < start + frames && $0.endFrame > start }
        }
        let position = lane == nil ? max(start, audioClips.filter { $0.lane == 0 }.map(\.endFrame).max() ?? 0) : start
        audioClips.append(AudioClip(assetID: assetID, inFrame: 0, outFrame: frames, startFrame: position, lane: lane ?? 0))
        do { try validate() } catch { audioClips.removeLast(); throw error }
    }
    public mutating func split(_ id: UUID, at frame: Int64) throws {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[index]
        guard frame > 0, frame < clip.frames else { throw EditorError("Split must be inside the clip.") }
        clips[index].outFrame = clip.inFrame + frame
        clips.insert(Clip(assetID: clip.assetID, inFrame: clip.inFrame + frame, outFrame: clip.outFrame, muted: clip.muted, startFrame: clip.startFrame.map { $0 + frame }, lane: clip.lane, transform: clip.transform, opacity: clip.opacity, imageTransparency: clip.imageTransparency), at: index + 1)
    }
}

public enum ProjectFile {
    public static func load(_ url: URL) throws -> VideoProject {
        var project = try JSONDecoder().decode(VideoProject.self, from: Data(contentsOf: url))
        for index in project.assets.indices {
            let path = project.assets[index].path
            if !project.assets[index].isTitle && !path.hasPrefix("/") {
                project.assets[index].path = url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.path
            }
        }
        try project.validate()
        return project
    }
    public static func save(_ project: VideoProject, to url: URL) throws {
        try project.validate()
        var stored = project
        let base = url.deletingLastPathComponent().standardizedFileURL.path + "/"
        for index in stored.assets.indices {
            if !stored.assets[index].isTitle && stored.assets[index].path.hasPrefix(base) { stored.assets[index].path.removeFirst(base.count) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("backup")
            try Data(contentsOf: url).write(to: backup, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}
