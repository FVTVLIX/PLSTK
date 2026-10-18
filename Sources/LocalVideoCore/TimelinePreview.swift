// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import Foundation

/// An unrendered, local playback composition derived from the canonical edit.
private final class PreviewPlayerItem: AVPlayerItem {
    var resources: PreviewResources?
}

public struct TimelinePreview {
    private let resources: PreviewResources
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    private let visualTracks: [UUID: (CMPersistentTrackID, CGAffineTransform, Float)]

    public func playerItem() -> AVPlayerItem {
        let item = PreviewPlayerItem(asset: composition)
        item.resources = resources
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }

    public static func build(_ project: VideoProject) async throws -> TimelinePreview {
        try project.validate(requireMedia: true)
        guard !project.clips.isEmpty else { throw EditorError("Add a clip to preview.") }
        let resources = try PreviewResources()
        let composition = AVMutableComposition()
        var visualTracks: [UUID: (CMPersistentTrackID, CGAffineTransform, Float)] = [:]
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        var layers: [(Clip, AVMutableVideoCompositionLayerInstruction)] = []
        var audioParameters: [AVAudioMixInputParameters] = []
        for clip in project.clips {
            try Task.checkCancellation()
            let cursor = CMTime(value: project.position(of: clip), timescale: 30)
            let media = try project.asset(for: clip)
            let url = media.isImage ? try await StillImage.movie(media, frames: clip.frames, width: project.width, height: project.height, directory: resources.directory, preserveAlpha: clip.imageTransparency, opacity: clip.opacity) : URL(fileURLWithPath: media.path)
            let source = AVURLAsset(url: url)
            guard let video = try await source.loadTracks(withMediaType: .video).first,
                  let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw EditorError("Cannot preview \(media.name). Try Render Preview for this format.")
            }
            let sourceVideoRange = try await video.load(.timeRange)
            let start = CMTimeAdd(sourceVideoRange.start, CMTime(value: media.isImage ? 0 : clip.inFrame, timescale: 30))
            let duration = CMTime(value: clip.frames, timescale: 30)
            let range = CMTimeRange(start: start, duration: duration)
            // Never silently shorten a clip: unsupported source ranges use the rendered fallback.
            guard CMTimeCompare(range.end, sourceVideoRange.end) <= 0 else {
                throw EditorError("The source range of \(media.name) needs Render Preview.")
            }
            try destination.insertTimeRange(range, of: video, at: cursor)

            let naturalSize = try await video.load(.naturalSize)
            let preferred = try await video.load(.preferredTransform)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: destination)
            layer.setTransform(fitTransform(size: naturalSize, preferred: preferred,
                                            output: CGSize(width: project.width, height: project.height))
                .concatenating(clip.transform.canvasTransform(width: project.width, height: project.height)), at: cursor)
            // Transparent still opacity is baked into the proxy: multiplying it again in
            // AVFoundation layer instructions corrupts partially transparent source pixels.
            let layerOpacity: Float = media.isImage && clip.imageTransparency ? 1 : Float(clip.opacity)
            visualTracks[clip.id] = (destination.trackID, fitTransform(size: naturalSize, preferred: preferred, output: CGSize(width: project.width, height: project.height)), layerOpacity)
            layer.setOpacity(layerOpacity, at: cursor)
            layers.append((clip, layer))

            if media.audioStream != nil, let audio = try await source.loadTracks(withMediaType: .audio).first {
                // Intersect instead of resetting timestamps: delayed audio retains its source offset.
                let audioRange = try await audio.load(.timeRange)
                let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if overlap.isValid, CMTimeCompare(overlap.duration, .zero) > 0 {
                    guard let destinationAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw EditorError("Cannot create preview audio track.")
                    }
                    let audioStart = CMTimeAdd(cursor, CMTimeSubtract(overlap.start, range.start))
                    try destinationAudio.insertTimeRange(overlap, of: audio, at: audioStart)
                    let parameters = AVMutableAudioMixInputParameters(track: destinationAudio)
                    parameters.setVolume(Float(clip.muted ? 0 : project.videoVolume), at: .zero)
                    audioParameters.append(parameters)
                }
            }
        }
        let boundaries = Set([Int64(0), project.totalFrames] + project.clips.flatMap { [project.position(of: $0), project.position(of: $0) + $0.frames] }).sorted()
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: CMTime(value: start, timescale: 30), duration: CMTime(value: end - start, timescale: 30))
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            // Highest track first; uncovered areas reveal lower tracks.
            let active = layers.filter { project.position(of: $0.0) <= start && project.position(of: $0.0) + $0.0.frames > start }.sorted { $0.0.lane > $1.0.lane }
            instruction.layerInstructions = active.map { $0.1 }
            instructions.append(instruction)
        }
        for clip in project.audioClips {
            try Task.checkCancellation()
            let media = project.assets.first { $0.id == clip.assetID }!
            let asset = AVURLAsset(url: URL(fileURLWithPath: media.path))
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw EditorError("Cannot preview audio: \(media.name)") }
            let sourceRange = CMTimeRange(start: CMTime(value: clip.inFrame, timescale: 30), duration: CMTime(value: clip.frames, timescale: 30))
            let available = try await audio.load(.timeRange)
            let overlap = CMTimeRangeGetIntersection(sourceRange, otherRange: available)
            if overlap.isValid, CMTimeCompare(overlap.duration, .zero) > 0 {
                guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw EditorError("Cannot create audio preview track.") }
                let position = CMTimeAdd(CMTime(value: clip.startFrame, timescale: 30), CMTimeSubtract(overlap.start, sourceRange.start))
                try destination.insertTimeRange(overlap, of: audio, at: position)
                let parameters = AVMutableAudioMixInputParameters(track: destination)
                let points = clip.fadeBreakpoints
                parameters.setVolume(Float(clip.effectiveVolume * clip.fadeGain(at: 0)), at: .zero)
                for (start, end) in zip(points, points.dropFirst()) where end > start {
                    parameters.setVolumeRamp(fromStartVolume: Float(clip.effectiveVolume * clip.fadeGain(at: Double(start))),
                        toEndVolume: Float(clip.effectiveVolume * clip.fadeGain(at: Double(end))),
                        timeRange: CMTimeRange(start: CMTime(value: clip.startFrame + start, timescale: 30),
                                               duration: CMTime(value: end - start, timescale: 30)))
                }
                audioParameters.append(parameters)
            }
        }
        if CMTimeCompare(composition.duration, CMTime(value: project.totalFrames, timescale: 30)) < 0 {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: CMTime(value: project.totalFrames, timescale: 30)))
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = audioParameters
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: project.width, height: project.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = instructions
        try Task.checkCancellation()
        return TimelinePreview(resources: resources, composition: composition, videoComposition: videoComposition, audioMix: mix, visualTracks: visualTracks)
    }

    /// Copies only composition instructions; source media and image proxies are reused during a gesture.
    public func transforming(_ id: UUID, to transform: VisualTransform) -> AVVideoComposition {
        guard transform.isValid, let (track, fitted, opacity) = visualTracks[id],
              let result = videoComposition.mutableCopy() as? AVMutableVideoComposition else { return videoComposition }
        let matrix = fitted.concatenating(transform.canvasTransform(width: Int(result.renderSize.width), height: Int(result.renderSize.height)))
        result.instructions = videoComposition.instructions.map { original in
            guard let instruction = original as? AVVideoCompositionInstruction,
                  let copy = instruction.mutableCopy() as? AVMutableVideoCompositionInstruction else { return original }
            copy.layerInstructions = instruction.layerInstructions.map { layer in
                guard layer.trackID == track else { return layer }
                let changed = AVMutableVideoCompositionLayerInstruction()
                changed.trackID = track
                changed.setTransform(matrix, at: instruction.timeRange.start)
                changed.setOpacity(opacity, at: instruction.timeRange.start)
                return changed
            }
            return copy
        }
        return result
    }

    static func fitTransform(size: CGSize, preferred: CGAffineTransform, output: CGSize) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: size).applying(preferred)
        let scale = min(output.width / bounds.width, output.height / bounds.height)
        return preferred
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (output.width - bounds.width * scale) / 2,
                                            y: (output.height - bounds.height * scale) / 2))
    }
}
