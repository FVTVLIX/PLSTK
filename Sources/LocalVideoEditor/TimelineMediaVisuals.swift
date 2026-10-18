// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import LocalVideoCore
import SwiftUI

struct TimelineMediaVisuals: View {
    let clip: Clip
    let media: MediaAsset?
    let width: CGFloat
    var body: some View {
        let source = media.flatMap { try? MediaVisualSource($0) }
        let count = min(20, max(1, Int(ceil(width / 64))))
        let frames = (0..<count).map { clip.inFrame + Int64(Double(clip.frames - 1) * Double($0) / Double(count)) }
        VStack(spacing: 0) {
            TimelineFilmstrip(source: source, frames: frames).frame(height: 32)
            TimelineWaveform(source: source, clip: clip).frame(height: 18)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct FilmstripRequest: Hashable {
    let source: MediaVisualSource?
    let frames: [Int64]
}

private struct TimelineFilmstrip: View {
    let source: MediaVisualSource?
    let frames: [Int64]
    @State private var images: [Int64: CGImage] = [:]
    @State private var loading = false
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                    ZStack {
                        Color.black.opacity(0.3)
                        if let image = images[frame] {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else { Image(systemName: "film").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    }.frame(width: geometry.size.width / CGFloat(frames.count), height: 32).clipped()
                }
            }
            if !loading && images.isEmpty && geometry.size.width > 80 {
                Text(source == nil ? "Media unavailable" : "No thumbnails").font(.system(size: 9))
                    .padding(3).background(.black.opacity(0.7)).padding(.leading, 10)
            }
        }.task(id: FilmstripRequest(source: source, frames: frames)) {
            images = [:]; loading = true
            defer { if !Task.isCancelled { loading = false } }
            guard let source else { loading = false; return }
            for frame in frames {
                guard !Task.isCancelled else { return }
                if let image = try? await MediaVisualCache.shared.thumbnail(source, frame: frame) {
                    guard !Task.isCancelled else { return }
                    images[frame] = image
                }
            }
        }
    }
}

struct TimelineWaveform: View {
    let source: MediaVisualSource?
    let clip: Clip
    @State private var waveform: AudioWaveform?
    @State private var failed = false
    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.32)
            if let waveform {
                Canvas { context, size in
                    var path = Path()
                    for x in stride(from: 0.0, to: size.width, by: 3) {
                        let start = clip.startSeconds + Double(x / size.width) * clip.duration
                        let end = clip.startSeconds + Double(min(size.width, x + 3) / size.width) * clip.duration
                        // Square-root display compression makes quiet peaks legible.
                        let peak = sqrt(Double(waveform.peak(from: start, to: end)))
                        let height = max(0.5, peak * (size.height - 2))
                        path.move(to: CGPoint(x: x + 1, y: (size.height - height) / 2))
                        path.addLine(to: CGPoint(x: x + 1, y: (size.height + height) / 2))
                    }
                    context.stroke(path, with: .color(Color(red: 0.66, green: 0.79, blue: 0.98)), lineWidth: 1.5)
                }
            } else {
                Text(source == nil ? "Media unavailable" : source?.audioStream == nil ? "No audio" : failed ? "Waveform unavailable" : "Loading audio…")
                    .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 11)
            }
        }.task(id: source) {
            waveform = nil; failed = false
            guard let source, source.audioStream != nil else { return }
            do {
                let result = try await MediaVisualCache.shared.waveform(source)
                guard !Task.isCancelled else { return }
                waveform = result
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
