// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

struct TransitionsPanel: View {
    @ObservedObject var store: EditorStore
    @State private var precise = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let clip = store.clip {
                    Text("Soften a scene change").font(.system(size: 14, weight: .medium))
                    if let media = try? store.project.asset(for: clip) {
                        Text(media.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    VisualTransitionControls(store: store, clipID: clip.id)
                    Button { precise = true } label: { Label("Fine tune", systemImage: "slider.horizontal.3") }
                        .popover(isPresented: $precise, arrowEdge: .leading) {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("Fine tune").font(.headline)
                                    Spacer()
                                    Button { precise = false } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).accessibilityLabel("Close fine tune")
                                }
                                VisualTransitionPrecision(store: store, clipID: clip.id)
                            }.padding(20).frame(width: 310)
                        }
                } else {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("Select a visual clip").font(.system(size: 14, weight: .medium))
                    Text("Choose footage, an image, or a title in the timeline to add a fade or a dissolve.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(16)
        }.disabled(store.busy).onChange(of: store.selectedClip) { _, _ in precise = false }
    }
}

struct VisualTransitionControls: View {
    @ObservedObject var store: EditorStore
    let clipID: UUID
    private var clip: Clip? { store.project.clips.first { $0.id == clipID } }
    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 18) {
                presets("Fade in", symbol: "sunrise", value: clip.localFadeInFrames, limit: clip.frames - clip.localFadeOutFrames) { frames in
                    editFade(entering: true, frames: frames)
                }
                presets("Fade out", symbol: "sunset", value: clip.localFadeOutFrames, limit: clip.frames - clip.localFadeInFrames) { frames in
                    editFade(entering: false, frames: frames)
                }
                Divider().opacity(0.4)
                if let previous = store.project.dissolvePredecessor(clipID) {
                    presets("Dissolve from previous", symbol: "rectangle.on.rectangle", value: clip.dissolveFrames,
                        limit: min(previous.frames - previous.dissolveFrames, clip.frames - store.project.outgoingDissolve(clipID))) { frames in
                        store.change { try $0.setDissolve(clipID, frames: frames) }
                    }
                } else {
                    Label("Dissolve from previous", systemImage: "rectangle.on.rectangle").font(.system(size: 12, weight: .medium))
                    Text("Place this clip directly after another on the same track to blend them.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DisclosureGroup("How dissolves work") {
                    Text("A dissolve overlaps both clips and moves following clips on this track earlier. Other tracks stay in place. Sound in the clips blends too. Remove a dissolve before moving or trimming its cut.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                }.font(.system(size: 11))
            }
        }
    }
    private func presets(_ label: String, symbol: String, value: Int64, limit: Int64, apply: @escaping (Int64) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(label, systemImage: symbol).font(.system(size: 12, weight: .medium))
            HStack(spacing: 5) {
                ForEach(Array(zip(["Off", "Short", "Medium", "Long"], [Int64(0), 8, 15, 30])), id: \.0) { name, frames in
                    Button { apply(min(frames, max(0, limit))) } label: {
                        VStack(spacing: 7) {
                            Image(systemName: frames == 0 ? "circle.slash" : (frames == 8 ? "circle.lefthalf.filled" : (frames == 15 ? "circle.bottomhalf.filled" : "circle.fill")))
                                .font(.system(size: 16, weight: .light))
                            Text(name).font(.system(size: 10))
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(value == frames ? .white.opacity(0.16) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).disabled(frames > limit && frames > 0)
                        .accessibilityLabel("\(label) \(name)").accessibilityAddTraits(value == frames ? [.isSelected] : [])
                }
            }
        }
    }
    private func editFade(entering: Bool, frames: Int64) {
        store.change { project in
            guard let i = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
            let clip = project.clips[i]
            try project.clips[i].setVisualFades(fadeIn: entering ? frames : clip.localFadeInFrames,
                fadeOut: entering ? clip.localFadeOutFrames : frames)
        }
    }
}

struct VisualTransitionPrecision: View {
    @ObservedObject var store: EditorStore
    let clipID: UUID
    @State private var fadeIn = 0.0
    @State private var fadeOut = 0.0
    @State private var dissolve = 0.0
    private var clip: Clip? { store.project.clips.first { $0.id == clipID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transition durations").font(.system(size: 13, weight: .semibold))
            field("Fade in", value: $fadeIn)
            field("Fade out", value: $fadeOut)
            field("Dissolve", value: $dissolve).disabled(store.project.dissolvePredecessor(clipID) == nil)
            Text("Durations are in seconds and round to the nearest frame.").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Apply transitions") {
                store.change { project in
                    guard [fadeIn, fadeOut, dissolve].allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1_000_000 }) else {
                        throw EditorError("Enter valid transition durations.")
                    }
                    try project.setDissolve(clipID, frames: Int64((dissolve * 30).rounded()))
                    if let i = project.clips.firstIndex(where: { $0.id == clipID }) {
                        try project.clips[i].setVisualFades(fadeIn: Int64((fadeIn * 30).rounded()), fadeOut: Int64((fadeOut * 30).rounded()))
                    }
                }
            }
        }.onAppear(perform: load).onChange(of: clip) { _, _ in load() }
    }
    private func load() {
        fadeIn = Double(clip?.localFadeInFrames ?? 0) / 30
        fadeOut = Double(clip?.localFadeOutFrames ?? 0) / 30
        dissolve = Double(clip?.dissolveFrames ?? 0) / 30
    }
    private func field(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number.precision(.fractionLength(3))).textFieldStyle(.roundedBorder).frame(width: 90)
                .accessibilityLabel("\(label) seconds")
        }.font(.system(size: 12))
    }
}
