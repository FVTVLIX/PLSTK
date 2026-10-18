// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

struct AudioFadeOverlay: View {
    @ObservedObject var store: EditorStore
    let clip: AudioClip
    let scale: Double
    @State private var draft: AudioClip?
    @State private var original: AudioClip?
    @State private var cancelled = false
    @GestureState private var dragging = false

    private var width: Double { Double(clip.frames) / 30 * scale }
    var body: some View {
        let value = draft ?? clip
        ZStack(alignment: .topLeading) {
            Path { path in
                for (index, frame) in value.fadeBreakpoints.enumerated() {
                    let point = CGPoint(x: Double(frame) / 30 * scale, y: 46 - value.fadeGain(at: Double(frame)) * 26)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(.white.opacity(0.85), lineWidth: 1).allowsHitTesting(false)
            if store.selectedAudio == clip.id, width >= 40, !store.busy {
                handle(.start, x: min(width - 8, max(8, Double(value.localFadeInFrames) / 30 * scale)))
                handle(.end, x: min(width - 8, max(8, width - Double(value.localFadeOutFrames) / 30 * scale)))
            }
            if draft != nil {
                Text(String(format: "%.2f / %.2f s", Double(value.fadeInFrames) / 30, Double(value.fadeOutFrames) / 30))
                    .font(.system(size: 9, design: .monospaced)).padding(2).background(.black.opacity(0.8))
                    .position(x: width / 2, y: 8).allowsHitTesting(false)
            }
        }.frame(width: width, height: 48)
            .onChange(of: store.project) { _, _ in cancel() }
            .onChange(of: store.selectedAudio) { _, id in if id != clip.id { cancel() } }
            .onChange(of: store.busy) { _, busy in if busy { cancel() } }
            .onExitCommand(perform: cancel)
            .onChange(of: dragging) { _, active in
                if !active { draft = nil; original = nil; cancelled = false }
            }
    }
    private func handle(_ edge: TrimEdge, x: Double) -> some View {
        Circle().fill(.white).frame(width: 7, height: 7).padding(6).contentShape(Circle())
            .position(x: x, y: edge == .start ? 22 : 32)
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { event in
                    if original == nil {
                        original = clip; cancelled = false; store.player?.pause()
                    }
                    guard !cancelled, var next = original else { return }
                    let delta = TimelineSnapping.frameDelta(points: event.translation.width, pointsPerSecond: scale)
                    let entering = next.localFadeInFrames, leaving = next.localFadeOutFrames
                    let value = edge == .start ? min(next.frames - leaving, max(0, entering + delta))
                        : min(next.frames - entering, max(0, leaving - delta))
                    try? next.setFades(fadeIn: edge == .start ? value : entering, fadeOut: edge == .end ? value : leaving)
                    draft = next
                }.onEnded { _ in
                    let value = cancelled ? nil : draft
                    draft = nil; original = nil; cancelled = false
                    if let value { store.setAudioFades(clip.id, fadeIn: value.fadeInFrames, fadeOut: value.fadeOutFrames) }
                })
            .accessibilityLabel(edge == .start ? "Audio fade in handle" : "Audio fade out handle")
            .help(edge == .start ? "Drag right for a longer fade in" : "Drag left for a longer fade out")
    }
    private func cancel() { draft = nil; if original != nil { cancelled = true } }
}
