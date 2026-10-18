// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

extension AudioClip {
    /// Source anchors preserve the envelope when a split divides a fade.
    public var fadeStart: Int64 { fadeSourceInFrame ?? inFrame }
    public var fadeEnd: Int64 { fadeSourceOutFrame ?? outFrame }
    public var hasValidFades: Bool {
        guard fadeStart >= 0, fadeStart <= inFrame, inFrame >= 0, outFrame > inFrame, fadeEnd >= outFrame, fadeEnd < 30_000_000,
              fadeInFrames >= 0, fadeOutFrames >= 0, fadeInFrames <= fadeEnd - fadeStart else { return false }
        return fadeOutFrames <= fadeEnd - fadeStart - fadeInFrames
    }
    public var localFadeInFrames: Int64 { min(frames, max(0, fadeStart + fadeInFrames - inFrame)) }
    public var localFadeOutFrames: Int64 { min(frames, max(0, outFrame - (fadeEnd - fadeOutFrames))) }
    public func fadeGain(at frame: Double) -> Double {
        let sourceFrame = Double(inFrame) + frame
        let entering = fadeInFrames == 0 ? 1 : min(1, max(0, (sourceFrame - Double(fadeStart)) / Double(fadeInFrames)))
        let leaving = fadeOutFrames == 0 ? 1 : min(1, max(0, (Double(fadeEnd) - sourceFrame) / Double(fadeOutFrames)))
        return entering * leaving
    }
    /// Breakpoints relative to this trimmed clip; native ramps use the same linear envelope as export.
    public var fadeBreakpoints: [Int64] {
        Set([0, frames, fadeStart + fadeInFrames - inFrame, fadeEnd - fadeOutFrames - inFrame]
            .map { min(frames, max(0, $0)) }).sorted()
    }
    public mutating func setFades(fadeIn: Int64, fadeOut: Int64) throws {
        guard fadeIn >= 0, fadeOut >= 0, fadeIn <= frames, fadeOut <= frames - fadeIn else {
            throw EditorError("Fade durations must be nonnegative and together fit inside the audio clip.")
        }
        fadeInFrames = fadeIn; fadeOutFrames = fadeOut
        fadeSourceInFrame = nil; fadeSourceOutFrame = nil
    }
}

extension VideoProject {
    public mutating func splitAudio(_ id: UUID, at frame: Int64) throws {
        guard let index = audioClips.firstIndex(where: { $0.id == id }) else { throw EditorError("Audio clip no longer exists.") }
        let original = audioClips[index]
        guard frame > 0, frame < original.frames else { throw EditorError("Split must be inside the audio clip.") }
        var first = original, second = original
        first.fadeSourceInFrame = original.fadeStart; first.fadeSourceOutFrame = original.fadeEnd
        second.fadeSourceInFrame = original.fadeStart; second.fadeSourceOutFrame = original.fadeEnd
        first.outFrame = original.inFrame + frame
        second.id = UUID(); second.inFrame = first.outFrame; second.startFrame += frame
        audioClips[index] = first; audioClips.insert(second, at: index + 1)
    }
}
