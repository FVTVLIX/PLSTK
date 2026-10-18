// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

struct VisualPlacementView: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    @State private var start = 0.0
    @State private var lane = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Placement").font(.system(size: 12, weight: .semibold))
            LabeledContent("Start") {
                TextField("Timeline start", value: $start, format: .number.precision(.fractionLength(3)))
                    .frame(width: 90).textFieldStyle(.roundedBorder)
            }
            Picker("Track", selection: $lane) {
                ForEach(0..<store.project.visualTrackCount, id: \.self) { Text("Video \($0 + 1)").tag($0) }
            }
            HStack {
                Button("Apply Placement") {
                    guard start.isFinite, start >= 0, start <= 1_000_000 else { store.error = "Enter a valid timeline start in seconds."; return }
                    store.placeVisual(clip.id, at: Int64((start * 30).rounded()), lane: lane)
                }
                Button { store.addVisualTrack() } label: { Image(systemName: "plus") }.help("Add visual track")
                    .disabled(store.project.visualTrackCount >= 32)
            }
            Text("Higher tracks appear above lower tracks. Same-track clips cannot overlap.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(store.busy)
            .onAppear(perform: synchronize)
            .onChange(of: clip) { _, _ in synchronize() }
    }
    private func synchronize() { start = Double(store.project.position(of: clip)) / 30; lane = clip.lane }
}
