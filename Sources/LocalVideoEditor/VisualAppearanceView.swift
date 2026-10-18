// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

struct VisualAppearanceView: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    let isImage: Bool
    @State private var opacity = 100.0
    @State private var transparency = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Visual").font(.system(size: 12, weight: .semibold))
            LabeledContent("Opacity %") {
                TextField("Opacity %", value: $opacity, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).frame(width: 90).accessibilityLabel("Opacity %")
            }.font(.system(size: 11))
            if isImage {
                Toggle("Use image transparency", isOn: $transparency).font(.system(size: 11))
            }
            Button("Apply Visual") {
                store.change { project in
                    guard let index = project.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                    project.clips[index].opacity = opacity / 100
                    project.clips[index].imageTransparency = transparency
                }
            }
            Text("0% hides the visual; audio keeps playing.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.disabled(store.busy)
            .onAppear(perform: synchronize)
            .onChange(of: clip) { _, _ in synchronize() }
    }
    private func synchronize() { opacity = clip.opacity * 100; transparency = clip.imageTransparency }
}
