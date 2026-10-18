// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

enum AudioInspectorSection { case sound, fades, trim, arrange }

struct AudioClipInspector: View {
    @ObservedObject var store: EditorStore
    let section: AudioInspectorSection
    @State private var start = 0.0
    @State private var sourceIn = 0.0
    @State private var sourceOut = 0.0
    @State private var volume = 100.0
    @State private var lane = 0
    @State private var fadeIn = 0.0
    @State private var fadeOut = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if section == .arrange {
                field("Timeline start", value: $start)
                Picker("Lane", selection: $lane) { Text("Audio 1").tag(0); Text("Audio 2").tag(1) }
            }
            if section == .trim {
                field("Source in", value: $sourceIn)
                field("Source out", value: $sourceOut)
            }
            if section == .sound { field("Volume %", value: $volume) }
            if section == .fades {
                field("Fade in", value: $fadeIn)
                field("Fade out", value: $fadeOut)
            }
            Button("Apply Audio") {
                if let clip = store.audioClip { store.updateAudio(clip.id, start: start, sourceIn: sourceIn, sourceOut: sourceOut, lane: lane, volume: volume / 100, fadeIn: fadeIn, fadeOut: fadeOut) }
            }.disabled(store.busy)
            if section == .fades, let clip = store.audioClip, clip.fadeSourceInFrame != nil {
                Text("This split retains its original fade timing. Changing fade durations starts a new envelope for this clip.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Times are seconds, snapped to timeline frames.").font(.caption).foregroundStyle(.tertiary)
        }.onAppear(perform: load).onChange(of: store.audioClip) { _, _ in load() }
    }
    private func field(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(3)))
                .textFieldStyle(.roundedBorder).frame(width: 78).disabled(store.busy)
        }.font(.caption)
    }
    private func load() {
        guard let clip = store.audioClip else { return }
        start = Double(clip.startFrame) / 30; sourceIn = Double(clip.inFrame) / 30
        sourceOut = Double(clip.outFrame) / 30; volume = clip.volume * 100; lane = clip.lane
        fadeIn = Double(clip.fadeInFrames) / 30; fadeOut = Double(clip.fadeOutFrames) / 30
    }
}

struct AudioTimelineLane: View {
    @ObservedObject var store: EditorStore
    let lane: Int
    let scale: Double
    @State private var moving: UUID?
    @State private var proposed: Int64 = 0
    var body: some View {
        ZStack(alignment: .leading) {
            Color.white.opacity(0.025).onTapGesture { if !store.busy { store.clearSelection() } }
            ForEach(store.project.audioClips.filter { $0.lane == lane }) { audio in
                let source = store.project.assets.first { $0.id == audio.assetID }
                let waveformSource = source.flatMap { try? MediaVisualSource($0) }
                let clip = Clip(id: audio.id, assetID: audio.assetID, inFrame: audio.inFrame, outFrame: audio.outFrame)
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Text(source?.name ?? "Missing audio").lineLimit(1)
                        Spacer(minLength: 0)
                        if audio.effectiveVolume == 0 { Image(systemName: "speaker.slash") }
                        else { Image(systemName: "speaker.wave.2") }
                    }.font(.system(size: 9)).padding(.horizontal, 8).frame(height: 18)
                    TimelineWaveform(source: waveformSource, clip: clip)
                }.frame(width: Double(audio.frames) / 30 * scale, height: 48)
                    .background(Color(red: 0.18, green: 0.32, blue: 0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(store.selectedAudio == audio.id ? .white : .clear))
                    .contentShape(Rectangle()).onTapGesture { store.selectAudio(audio) }
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
                        .onChanged { value in
                            guard !store.busy else { return }
                            if moving == nil { store.player?.pause(); store.selectAudio(audio) }
                            moving = audio.id
                            proposed = max(0, store.snapTimelineFrame(audio.startFrame + TimelineSnapping.frameDelta(points: value.translation.width, pointsPerSecond: scale), excluding: audio.id, scale: scale))
                        }
                        .onEnded { _ in
                            guard !store.busy, moving == audio.id else { moving = nil; return }
                            let frame = proposed; moving = nil; store.moveAudio(audio.id, to: frame)
                        })
                    .overlay { AudioFadeOverlay(store: store, clip: audio, scale: scale) }
                    .offset(x: Double(moving == audio.id ? proposed : audio.startFrame) / 30 * scale)
                    .accessibilityElement(children: .contain).accessibilityLabel("\(source?.name ?? "Audio"), Audio \(lane + 1)")
                    .accessibilityAddTraits(.isButton).accessibilityAction { store.selectAudio(audio) }
                    .help("Drag to place audio. Use the inspector for source trim, lane, volume and fades. Drag the circular handles to set fades.")
            }
        }.frame(height: 52).clipped().disabled(store.busy)
            .onChange(of: store.project) { _, _ in moving = nil }
            .onExitCommand { moving = nil }
    }
}
