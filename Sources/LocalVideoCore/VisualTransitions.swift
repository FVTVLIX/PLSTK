// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

extension Clip {
    public var fadeStart: Int64 { fadeSourceInFrame ?? inFrame }
    public var fadeEnd: Int64 { fadeSourceOutFrame ?? outFrame }
    public var hasValidVisualFades: Bool {
        fadeStart >= 0 && fadeStart <= inFrame && fadeEnd >= outFrame && fadeEnd < 30_000_000 &&
        fadeInFrames >= 0 && fadeOutFrames >= 0 && fadeInFrames <= fadeEnd - fadeStart &&
        fadeOutFrames <= fadeEnd - fadeStart - fadeInFrames
    }
    public var localFadeInFrames: Int64 { min(frames, max(0, fadeStart + fadeInFrames - inFrame)) }
    public var localFadeOutFrames: Int64 { min(frames, max(0, outFrame - fadeEnd + fadeOutFrames)) }
    public func fadeGain(at frame: Double) -> Double {
        let source = Double(inFrame) + frame
        let a = fadeInFrames == 0 ? 1 : min(1, max(0, (source - Double(fadeStart)) / Double(fadeInFrames)))
        let b = fadeOutFrames == 0 ? 1 : min(1, max(0, (Double(fadeEnd) - source) / Double(fadeOutFrames)))
        return a * b
    }
    public var fadeBreakpoints: [Int64] {
        Set([0, frames, fadeStart + fadeInFrames - inFrame, fadeEnd - fadeOutFrames - inFrame].map { min(frames, max(0, $0)) }).sorted()
    }
    public mutating func setVisualFades(fadeIn: Int64, fadeOut: Int64) throws {
        guard fadeIn >= 0, fadeOut >= 0, fadeIn <= frames, fadeOut <= frames - fadeIn else {
            throw EditorError("Choose fade durations that fit inside the clip.")
        }
        fadeInFrames = fadeIn; fadeOutFrames = fadeOut; fadeSourceInFrame = nil; fadeSourceOutFrame = nil
    }
    public mutating func fitVisualFades() {
        let a = min(max(0, fadeInFrames), frames), b = min(max(0, fadeOutFrames), frames - a)
        try? setVisualFades(fadeIn: a, fadeOut: b)
    }
}

extension VideoProject {
    public var hasVisualTransitions: Bool { hasDissolves || clips.contains { $0.fadeInFrames > 0 || $0.fadeOutFrames > 0 } }
    public var hasDissolves: Bool { clips.contains { $0.dissolveFrames > 0 } }
    public func outgoingDissolve(_ id: UUID) -> Int64 { clips.first { $0.dissolveFrom == id }?.dissolveFrames ?? 0 }
    public func dissolveGain(_ clip: Clip, at frame: Double) -> Double {
        let a = clip.dissolveFrames == 0 ? 1 : min(1, max(0, frame / Double(clip.dissolveFrames)))
        let duration = outgoingDissolve(clip.id)
        let b = duration == 0 ? 1 : min(1, max(0, (Double(clip.frames) - frame) / Double(duration)))
        return a * b
    }
    public func dissolvePredecessor(_ id: UUID) -> Clip? {
        guard let clip = clips.first(where: { $0.id == id }) else { return nil }
        if let from = clip.dissolveFrom { return clips.first { $0.id == from } }
        return clips.first { $0.id != id && $0.lane == clip.lane && position(of: $0) + $0.frames == position(of: clip) }
    }
    public mutating func setDissolve(_ id: UUID, frames: Int64) throws {
        guard frames >= 0, let index = clips.firstIndex(where: { $0.id == id }) else { throw EditorError("Select a visual clip first.") }
        let clip = clips[index], old = clip.dissolveFrames
        if frames == old { return }
        guard let previous = dissolvePredecessor(id) else {
            if frames == 0 { return }
            throw EditorError("Place this clip directly after another clip on the same track to dissolve between them.")
        }
        guard frames <= min(previous.frames, clip.frames) else { throw EditorError("Choose a dissolve that fits both clips.") }
        var next = self; next.materializePositions()
        let start = position(of: clip), shift = old - frames
        for i in next.clips.indices where next.clips[i].lane == clip.lane && next.clips[i].id != previous.id && next.position(of: next.clips[i]) >= start {
            next.clips[i].startFrame = next.position(of: next.clips[i]) + shift
        }
        next.clips[index].dissolveFrames = frames
        next.clips[index].dissolveFrom = frames == 0 ? nil : previous.id
        if frames > 0 {
            try next.clips[index].setVisualFades(fadeIn: 0, fadeOut: clip.localFadeOutFrames)
            if let p = next.clips.firstIndex(where: { $0.id == previous.id }) {
                try next.clips[p].setVisualFades(fadeIn: previous.localFadeInFrames, fadeOut: 0)
            }
        }
        try next.validate(); self = next
    }
    func validateDissolves() throws {
        var donors: Set<UUID> = []
        for clip in clips {
            guard clip.hasValidVisualFades else { throw EditorError("Visual fades must fit inside the clip.") }
            guard clip.dissolveFrames >= 0 else { throw EditorError("Choose a valid dissolve duration.") }
            if clip.dissolveFrames == 0 {
                guard clip.dissolveFrom == nil else { throw EditorError("Invalid dissolve link.") }; continue
            }
            guard let donor = clips.first(where: { $0.id == clip.dissolveFrom }), donor.id != clip.id,
                  donors.insert(donor.id).inserted, donor.lane == clip.lane,
                  clip.dissolveFrames <= min(donor.frames, clip.frames),
                  position(of: clip) == position(of: donor) + donor.frames - clip.dissolveFrames else {
                throw EditorError("This edit would break a dissolve. Remove the dissolve before moving or trimming its cut.")
            }
            let outgoing = outgoingDissolve(clip.id)
            guard outgoing >= 0, outgoing <= clip.frames, clip.dissolveFrames <= clip.frames - outgoing else {
                throw EditorError("The dissolves on both ends must fit inside the clip.")
            }
        }
    }
    func permitsOverlap(_ first: Clip, _ second: Clip) -> Bool {
        (second.dissolveFrom == first.id && second.dissolveFrames > 0) || (first.dissolveFrom == second.id && first.dissolveFrames > 0)
    }
    public mutating func removeVisual(_ id: UUID) {
        clips.removeAll { $0.id == id }
        for i in clips.indices where clips[i].dissolveFrom == id { clips[i].dissolveFrom = nil; clips[i].dissolveFrames = 0 }
    }
}
