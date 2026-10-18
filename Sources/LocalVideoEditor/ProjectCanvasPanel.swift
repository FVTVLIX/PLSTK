// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

struct ProjectCanvasPanel: View {
    @ObservedObject var store: EditorStore
    @State private var advanced = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose a shape for your video.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    shape("Landscape", symbol: "rectangle", width: 1280, height: 720)
                    shape("Portrait", symbol: "rectangle.portrait", width: 1080, height: 1920)
                    shape("Square", symbol: "square", width: 1080, height: 1080)
                }
                Divider()
                Toggle(isOn: Binding(get: { store.project.videoVolume == 0 }, set: { muted in store.change { $0.videoVolume = muted ? 0 : 1 } })) {
                    Label("Mute video sound", systemImage: "speaker.slash")
                }.toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                DisclosureGroup("Export details", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Output size", selection: Binding(get: { "\(store.project.width)x\(store.project.height)" }, set: { value in
                            let parts = value.split(separator: "x").compactMap { Int($0) }
                            if parts.count == 2 { store.change { $0.width = parts[0]; $0.height = parts[1] } }
                        })) {
                            if !["1280x720", "1920x1080", "3840x2160", "1080x1920", "1080x1080"].contains("\(store.project.width)x\(store.project.height)") {
                                Text("\(store.project.width) × \(store.project.height)").tag("\(store.project.width)x\(store.project.height)")
                            }
                            Text("720p · landscape").tag("1280x720")
                            Text("1080p · landscape").tag("1920x1080")
                            Text("4K · landscape").tag("3840x2160")
                            Text("1080p · portrait").tag("1080x1920")
                            Text("Square").tag("1080x1080")
                        }
                        Text("MP4 · H.264 + AAC · 30 fps").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(16)
        }.disabled(store.busy)
    }
    private func shape(_ title: String, symbol: String, width: Int, height: Int) -> some View {
        let selected = Double(store.project.width) / Double(store.project.height) == Double(width) / Double(height)
        return Button { store.change { $0.width = width; $0.height = height } } label: {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 26, weight: .ultraLight)).frame(height: 34)
                Text(title).font(.system(size: 10))
            }.frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(.white.opacity(selected ? 0.15 : 0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(selected ? 0.25 : 0.05)))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
