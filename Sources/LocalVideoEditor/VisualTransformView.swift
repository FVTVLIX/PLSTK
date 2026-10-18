// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

struct VisualTransformView: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var percent = 100.0
    @State private var rotation = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transform").font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { field("X", value: $x); field("Y", value: $y) }
                GridRow { field("Scale %", value: $percent); field("Rotation °", value: $rotation) }
            }
            HStack {
                Button("Apply Transform") { apply(VisualTransform(x: x, y: y, scale: percent / 100, rotation: rotation)) }
                Spacer()
                Button("Reset") { apply(VisualTransform()) }.disabled(clip.transform == VisualTransform() && x == 0 && y == 0 && percent == 100 && rotation == 0)
            }
            Text("Position in pixels · rotation clockwise · scale from centre")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.disabled(store.busy)
            .onAppear(perform: synchronize)
            .onChange(of: clip.transform) { _, _ in synchronize() }
            .onChange(of: store.canvasDraft) { _, draft in load(draft ?? clip.transform) }
    }
    private func field(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
    private func apply(_ transform: VisualTransform) {
        store.change { project in
            if let index = project.clips.firstIndex(where: { $0.id == clip.id }) { project.clips[index].transform = transform }
        }
        if let saved = store.project.clips.first(where: { $0.id == clip.id }), saved.transform == transform { load(transform) }
    }
    private func synchronize() { load(clip.transform) }
    private func load(_ transform: VisualTransform) { x = transform.x; y = transform.y; percent = transform.scale * 100; rotation = transform.rotation }
}
