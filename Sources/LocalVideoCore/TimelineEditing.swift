// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

public enum TrimEdge: String, Sendable { case start, end }

extension VideoProject {
    /// Ripple trim: change the source range, keeping the sequence gapless.
    /// Delta is relative to the original edge, in the project's 30 fps frames.
    public func trimmedClip(_ id: UUID, edge: TrimEdge, delta: Int64) throws -> Clip {
        guard var clip = clips.first(where: { $0.id == id }) else { throw EditorError("Clip no longer exists.") }
        let source = try asset(for: clip)
        // Clamp the delta before adding it, including extreme pointer/keyboard inputs.
        switch edge {
        case .start:
            clip.inFrame += min(max(delta, -clip.inFrame), clip.frames - 1)
        case .end:
            let maximum = source.isImage ? 29_999_999 : Int64(floor(source.duration * 30 + 0.0001))
            clip.outFrame += min(max(delta, 1 - clip.frames), maximum - clip.outFrame)
        }
        return clip
    }

    public mutating func rippleTrim(_ id: UUID, edge: TrimEdge, delta: Int64) throws {
        let replacement = try trimmedClip(id, edge: edge, delta: delta)
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index] = replacement
    }

    /// Final array index after removing and reinserting the clip.
    public mutating func moveClip(_ id: UUID, to index: Int) throws {
        guard clips.indices.contains(index), let source = clips.firstIndex(where: { $0.id == id }) else {
            throw EditorError("Invalid timeline move.")
        }
        let clip = clips.remove(at: source)
        clips.insert(clip, at: index)
    }

    /// Compare the pointer to the other clips' midpoints in the original timeline.
    /// The dragged clip's space stays in place until the user releases the gesture.
    public func insertionIndex(moving id: UUID, atFrame frame: Double) -> Int? {
        guard frame.isFinite, clips.contains(where: { $0.id == id }) else { return nil }
        var cursor = 0.0, index = 0
        for clip in clips {
            if clip.id != id {
                if frame < cursor + Double(clip.frames) / 2 { return index }
                index += 1
            }
            cursor += Double(clip.frames)
        }
        return index
    }
}

public enum TimelineSnapping {
    public static func nearestFrame(_ frame: Int64, candidates: [Int64], tolerance: Int64) -> Int64 {
        guard tolerance >= 0 else { return frame }
        return candidates.filter { abs(Double($0) - Double(frame)) <= Double(tolerance) }
            .min { abs(Double($0) - Double(frame)) < abs(Double($1) - Double(frame)) } ?? frame
    }

    public static func frameDelta(points: Double, pointsPerSecond: Double) -> Int64 {
        guard points.isFinite, pointsPerSecond.isFinite, pointsPerSecond > 0 else { return 0 }
        // Project media is bounded below one million seconds. Keep conversion finite.
        let frames = (points / pointsPerSecond * 30).rounded()
        return Int64(min(30_000_000, max(-30_000_000, frames)))
    }
}

extension VideoProject {
    public mutating func insertVisual(_ assetID: UUID, at frame: Int64) throws {
        guard let media = assets.first(where: { $0.id == assetID }), !media.isAudioOnly else { throw EditorError("Choose visual media.") }
        materializePositions()
        var clip = Clip(assetID: assetID, inFrame: 0, outFrame: Int64(floor(media.duration * 30)), startFrame: max(0, frame))
        clip.lane = try availableVisualLane(at: max(0, frame), frames: clip.frames)
        clips.append(clip)
    }
    public mutating func availableVisualLane(at start: Int64, frames: Int64) throws -> Int {
        if let lane = (0..<visualTrackCount).first(where: { lane in
            !clips.contains { $0.lane == lane && position(of: $0) < start + frames && position(of: $0) + $0.frames > start }
        }) { return lane }
        guard visualTrackCount < 32 else { throw EditorError("All 32 visual tracks are occupied at this time.") }
        visualTrackCount += 1; return visualTrackCount - 1
    }
    public mutating func placeVisual(_ id: UUID, at start: Int64, lane: Int) throws {
        guard start >= 0, start <= 30_000_000, (0..<visualTrackCount).contains(lane),
              let index = clips.firstIndex(where: { $0.id == id }) else { throw EditorError("Invalid visual placement.") }
        var next = self; next.materializePositions()
        next.clips[index].startFrame = start; next.clips[index].lane = lane
        try next.validate(); self = next
    }
}
