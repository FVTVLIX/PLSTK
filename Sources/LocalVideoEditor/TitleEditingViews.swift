// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

struct TitlesPanel: View {
    @ObservedObject var store: EditorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a title").font(.system(size: 14, weight: .medium))
                Text("Choose a style, then make it yours. Titles appear at the playhead above your footage.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(TitleStyle.allCases, id: \.self) { style in
                    Button { store.addTitle(style) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
                                Text(style == .statement ? "YOUR STORY" : (style == .caption ? "A moment to remember" : "Your title"))
                                    .font(.system(size: style == .statement ? 24 : 18, weight: style == .statement ? .bold : .regular))
                                    .padding(8).background(style == .caption ? Color.black : .clear, in: RoundedRectangle(cornerRadius: 5))
                            }.frame(height: 100)
                            HStack { Label(style.name, systemImage: style.symbol); Spacer(); Image(systemName: "plus.circle") }
                                .font(.system(size: 12))
                        }.padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel("Add \(style.name) title")
                }
            }.padding(16)
        }.disabled(store.busy)
    }
}

struct TitleContentControls: View {
    @ObservedObject var store: EditorStore
    let clipID: UUID
    @State private var text = ""
    private var title: TextTitle? { store.project.clips.first { $0.id == clipID }.flatMap { try? store.project.asset(for: $0).title } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: $text).font(.system(size: 14)).frame(height: 90)
                .padding(5).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Title text")
            Button("Apply text") { edit { $0.text = text } }.disabled(text == title?.text)
            HStack {
                ForEach(TitleStyle.allCases, id: \.self) { style in
                    Button { edit { value in
                        let preset = TextTitle(style: style); value.style = style; value.size = preset.size
                    } } label: {
                        VStack(spacing: 6) { Image(systemName: style.symbol); Text(style.name).font(.system(size: 10)) }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(title?.style == style ? .white.opacity(0.14) : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityLabel("\(style.name) title style")
                }
            }
            HStack(spacing: 14) {
                Text("Color").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(TitleColor.allCases, id: \.self) { color in
                    Button { edit { $0.color = color } } label: {
                        Circle().fill(Color(cgColor: color.color)).frame(width: 22, height: 22)
                            .padding(3).overlay(Circle().stroke(.white.opacity(title?.color == color ? 0.9 : 0.15)))
                    }.buttonStyle(.plain).accessibilityLabel("\(color.rawValue.capitalized) text")
                }
            }
            HStack {
                position("Top", symbol: "rectangle.topthird.inset.filled", offset: -0.28)
                position("Centre", symbol: "rectangle.center.inset.filled", offset: 0)
                position("Bottom", symbol: "rectangle.bottomthird.inset.filled", offset: 0.28)
            }
            Text("Drag in the viewer to position your title. Pull a corner to resize it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.onAppear { text = title?.text ?? "" }
            .onChange(of: title?.text) { _, value in text = value ?? "" }
    }
    private func edit(_ action: (inout TextTitle) -> Void) {
        guard var value = title else { return }; action(&value); store.updateTitle(clipID, to: value)
    }
    private func position(_ name: String, symbol: String, offset: Double) -> some View {
        ToolboxAction(name, symbol: symbol) {
            store.change { project in
                if let i = project.clips.firstIndex(where: { $0.id == clipID }) {
                    project.clips[i].transform.x = 0
                    project.clips[i].transform.y = Double(project.height) * offset
                }
            }
        }.accessibilityLabel("Title \(name.lowercased())")
    }
}

struct TitleTypographyControls: View {
    @ObservedObject var store: EditorStore
    let clipID: UUID
    @State private var size = 9.0
    @State private var alignment: TitleAlignment = .center
    private var title: TextTitle? { store.project.clips.first { $0.id == clipID }.flatMap { try? store.project.asset(for: $0).title } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Size % of canvas height") {
                TextField("Title size %", value: $size, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).frame(width: 70).accessibilityLabel("Title size %")
            }.font(.system(size: 11))
            Picker("Alignment", selection: $alignment) {
                ForEach(TitleAlignment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            Button("Apply typography") {
                guard var value = title else { return }
                value.size = size / 100; value.alignment = alignment
                store.updateTitle(clipID, to: value)
            }
            Text("System typography. Long text wraps and shrinks to fit the canvas. Use up to eight lines.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.onAppear(perform: load).onChange(of: title) { _, _ in load() }
    }
    private func load() { size = (title?.size ?? 0.09) * 100; alignment = title?.alignment ?? .center }
}

extension EditorStore {
    func addTitle(_ style: TitleStyle) {
        var added: UUID?
        change { added = try $0.addTitle(TextTitle(style: style), at: playheadFrame) }
        if let added, let clip = project.clips.first(where: { $0.id == added }) { selectClip(clip) }
    }
    func updateTitle(_ id: UUID, to value: TextTitle) {
        change { try $0.updateTitle(id, to: value) }
        if let clip = project.clips.first(where: { $0.id == id }) { selectedAsset = clip.assetID }
    }
}
