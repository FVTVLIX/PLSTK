// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

/// A contextual toolbox: simple actions first, precise values only on request.
struct ClipToolbox: View {
    @ObservedObject var store: EditorStore
    @State private var tool: ClipTool?
    @State private var precise = false
    @State private var details = false

    private var audio: AudioClip? { store.audioClip }
    private var visual: Clip? { store.clip }
    private var media: MediaAsset? {
        let id = audio?.assetID ?? visual?.assetID
        return store.project.assets.first { $0.id == id }
    }
    private var tools: [ClipTool] {
        if audio != nil { return [.sound, .fades, .trim, .arrange] }
        var items: [ClipTool] = [.size, .rotate, .appearance, media?.isImage == true ? .duration : .trim]
        if media?.isTitle == true { items.insert(.text, at: 0) }
        if media?.audioStream != nil { items.append(.sound) }
        items.append(.arrange)
        return items
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let media {
                    HStack(spacing: 12) {
                        MediaThumbnail(media: media).frame(width: 58, height: 46).clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(media.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(audio != nil ? "Audio clip" : (media.isTitle ? "Text title" : (media.isImage ? "Image clip" : "Video clip")))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { details = true } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).help("Clip details").accessibilityLabel("Clip details")
                            .popover(isPresented: $details) { mediaDetails(media).padding(20).frame(width: 280) }
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(tools) { item in
                        Button { tool = tool == item ? nil : item; precise = false } label: {
                            VStack(spacing: 9) {
                                Image(systemName: item.symbol).font(.system(size: 20, weight: .light)).frame(height: 24)
                                Text(item.title).font(.system(size: 11, weight: .medium))
                            }.frame(maxWidth: .infinity).frame(height: 72)
                                .background(tool == item ? Color.white.opacity(0.15) : Color.white.opacity(0.045))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(tool == item ? 0.3 : 0.05)))
                        }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityAddTraits(tool == item ? [.isSelected] : [])
                    }
                }
                if let tool {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(tool.title, systemImage: tool.symbol).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button { self.tool = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                                .buttonStyle(.plain).help("Close tool").accessibilityLabel("Close tool")
                        }
                        controls(tool)
                        Button { precise = true } label: { Label("Fine tune", systemImage: "slider.horizontal.3").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .popover(isPresented: $precise) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 16) {
                                        HStack {
                                            Text("Fine tune · \(tool.title)").font(.system(size: 14, weight: .semibold))
                                            Spacer()
                                            Button { precise = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                                                .accessibilityLabel("Close fine tune")
                                        }
                                        precisionControls(tool)
                                    }.padding(20)
                                }.frame(width: 330).frame(maxHeight: 540).preferredColorScheme(.dark)
                            }
                    }.padding(16).background(Color.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Label(audio != nil ? "Shape the sound with a tool above." : "Pick a tool, or adjust the clip in the viewer.", systemImage: "cursorarrow")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                }
                Divider().opacity(0.4)
                HStack(spacing: 8) {
                    ToolboxAction("Split", symbol: "scissors", action: store.splitAtPlayhead).disabled(!store.canSplitAtPlayhead)
                    if visual != nil { ToolboxAction("Duplicate", symbol: "plus.square.on.square", action: store.duplicateClip) }
                    ToolboxAction("Delete", symbol: "trash", action: store.removeClip)
                }
            }.padding(16)
        }.disabled(store.busy)
            .onAppear { if media?.isTitle == true { tool = .text } }
            .onChange(of: store.selectedClip) { _, _ in tool = nil; precise = false; details = false }
            .onChange(of: store.selectedAudio) { _, _ in tool = nil; precise = false; details = false }
    }
    @ViewBuilder private func controls(_ tool: ClipTool) -> some View {
        switch tool {
        case .text:
            if let visual { TitleContentControls(store: store, clipID: visual.id) }
        case .size:
            Text("Drag the clip to move it. Pull a corner to resize.").toolboxHint()
            HStack {
                ToolboxAction("Fit", symbol: "arrow.down.right.and.arrow.up.left") { transform { $0 = VisualTransform() } }
                ToolboxAction("Inset", symbol: "rectangle.inset.filled") { transform { $0.x = 0; $0.y = 0; $0.scale = 0.5 } }
                ToolboxAction("Centre", symbol: "viewfinder") { transform { $0.x = 0; $0.y = 0 } }
            }
            if let visual {
                ToolboxSlider(value: visual.transform.scale, range: 0.05...4, title: "Size", leading: "minus.magnifyingglass", trailing: "plus.magnifyingglass") { value in transform { $0.scale = value } }
            }
        case .rotate:
            HStack {
                ToolboxAction("Turn left", symbol: "rotate.left") { transform { $0.rotation = normalized($0.rotation - 90) } }
                ToolboxAction("Turn right", symbol: "rotate.right") { transform { $0.rotation = normalized($0.rotation + 90) } }
                ToolboxAction("Straighten", symbol: "arrow.uturn.backward") { transform { $0.rotation = 0 } }
            }
            if let visual {
                ToolboxSlider(value: normalized(visual.transform.rotation), range: -180...180, title: "Rotation", leading: "rotate.left", trailing: "rotate.right") { value in transform { $0.rotation = value } }
            }
        case .appearance:
            if let visual {
                Text("Let the layer below show through.").toolboxHint()
                ToolboxSlider(value: visual.opacity, range: 0...1, title: "Opacity", leading: "circle.dotted", trailing: "circle.fill") { value in
                    editVisual { $0.opacity = value }
                }
                if media?.isImage == true && media?.isTitle != true {
                    Toggle(isOn: Binding(get: { visual.imageTransparency }, set: { value in editVisual { $0.imageTransparency = value } })) {
                        Label("Transparent background", systemImage: "square.on.square.dashed")
                    }.toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                }
            }
        case .sound:
            let muted = audio?.muted ?? visual?.muted ?? false
            Button { mute(!muted) } label: {
                Label(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12)).frame(maxWidth: .infinity).padding(10)
                    .background(.white.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
            if let audio {
                ToolboxSlider(value: audio.volume, range: 0...1, title: "Volume", leading: "speaker", trailing: "speaker.wave.3") { value in
                    store.change { project in if let i = project.audioClips.firstIndex(where: { $0.id == audio.id }) { project.audioClips[i].volume = value } }
                }
            }
        case .fades:
            Text("Pull the round handles on the audio clip to soften its start or end.").toolboxHint()
            HStack {
                fadeAction("Fade in", symbol: "chart.line.uptrend.xyaxis", entering: true)
                fadeAction("Fade out", symbol: "chart.line.downtrend.xyaxis", entering: false)
                ToolboxAction("Clear", symbol: "arrow.uturn.backward") {
                    if let audio { store.setAudioFades(audio.id, fadeIn: 0, fadeOut: 0) }
                }
            }
            if let audio {
                ToolboxSlider(value: Double(audio.localFadeInFrames), range: 0...Double(max(1, audio.frames - audio.localFadeOutFrames)), title: "Fade in", leading: "waveform", trailing: "chart.line.uptrend.xyaxis") { value in
                    store.setAudioFades(audio.id, fadeIn: Int64(value.rounded()), fadeOut: audio.localFadeOutFrames)
                }.disabled(audio.frames <= audio.localFadeOutFrames)
                ToolboxSlider(value: Double(audio.localFadeOutFrames), range: 0...Double(max(1, audio.frames - audio.localFadeInFrames)), title: "Fade out", leading: "waveform", trailing: "chart.line.downtrend.xyaxis") { value in
                    store.setAudioFades(audio.id, fadeIn: audio.localFadeInFrames, fadeOut: Int64(value.rounded()))
                }.disabled(audio.frames <= audio.localFadeInFrames)
            }
        case .trim:
            Text(audio != nil ? "Split at the playhead, or open Fine tune to choose the part you want." : "Drag a clip edge in the timeline to shorten it, or split at the playhead.").toolboxHint()
            ToolboxAction("Split here", symbol: "scissors", action: store.splitAtPlayhead).disabled(!store.canSplitAtPlayhead)
        case .duration:
            Text("Choose how long the image stays on screen.").toolboxHint()
            HStack {
                durationAction("Brief", seconds: 3, symbol: "hourglass.bottomhalf.filled")
                durationAction("Standard", seconds: 5, symbol: "hourglass")
                durationAction("Long", seconds: 10, symbol: "hourglass.tophalf.filled")
            }
        case .arrange:
            Text("Drag the clip along the timeline to move it.").toolboxHint()
            HStack {
                ToolboxAction("To start", symbol: "backward.end") { moveToStart() }
                ToolboxAction("To playhead", symbol: "playhead") { moveToPlayhead() }
            }
            if let visual {
                HStack {
                    ToolboxAction("Layer down", symbol: "square.3.layers.3d.bottom.filled") { store.placeVisual(visual.id, at: store.project.position(of: visual), lane: visual.lane - 1) }.disabled(visual.lane == 0)
                    ToolboxAction("Layer up", symbol: "square.3.layers.3d.top.filled") { raiseLayer(visual) }.disabled(visual.lane >= 31)
                }
            } else if let audio {
                ToolboxAction("Switch lane", symbol: "arrow.up.arrow.down") {
                    store.change { project in if let i = project.audioClips.firstIndex(where: { $0.id == audio.id }) { project.audioClips[i].lane = 1 - audio.lane } }
                }
            }
        }
    }
    @ViewBuilder private func precisionControls(_ tool: ClipTool) -> some View {
        if audio != nil {
            AudioClipInspector(store: store, section: tool == .sound ? .sound : (tool == .fades ? .fades : (tool == .trim ? .trim : .arrange)))
        } else if let visual, let media {
            switch tool {
            case .text: TitleTypographyControls(store: store, clipID: visual.id)
            case .size, .rotate: VisualTransformView(store: store, clip: visual)
            case .appearance: VisualAppearanceView(store: store, clip: visual, isImage: media.isImage && !media.isTitle)
            case .arrange: VisualPlacementView(store: store, clip: visual)
            case .trim, .duration: PreciseTrimView(store: store, clip: visual, isImage: media.isImage)
            default: Toggle("Mute clip", isOn: Binding(get: { visual.muted }, set: mute))
            }
        }
    }
    private func mediaDetails(_ media: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clip details").font(.headline)
            Text(media.name).textSelection(.enabled)
            if !media.isAudioOnly && !media.isTitle { LabeledContent("Dimensions", value: "\(media.width) × \(media.height)") }
            if !media.isTitle {
                LabeledContent("Source duration", value: String(format: "%.2f seconds", media.duration))
                Button("Reveal original") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: media.path)]) }
            } else { Text("Text is stored inside your project.") }
        }.font(.system(size: 12))
    }
    private func normalized(_ angle: Double) -> Double { (angle + 540).truncatingRemainder(dividingBy: 360) - 180 }
    private func editVisual(_ edit: (inout Clip) -> Void) {
        guard let visual else { return }
        store.change { project in if let i = project.clips.firstIndex(where: { $0.id == visual.id }) { edit(&project.clips[i]) } }
    }
    private func transform(_ edit: (inout VisualTransform) -> Void) { editVisual { edit(&$0.transform) } }
    private func mute(_ muted: Bool) {
        if let audio {
            store.change { project in if let i = project.audioClips.firstIndex(where: { $0.id == audio.id }) { project.audioClips[i].muted = muted } }
        } else { editVisual { $0.muted = muted } }
    }
    private func durationAction(_ title: String, seconds: Double, symbol: String) -> some View {
        ToolboxAction(title, symbol: symbol) {
            if let visual { store.trim(start: visual.startSeconds, end: visual.startSeconds + seconds) }
        }.help("\(title) · \(Int(seconds)) seconds")
    }
    private func fadeAction(_ title: String, symbol: String, entering: Bool) -> some View {
        ToolboxAction(title, symbol: symbol) {
            guard let audio else { return }
            let length = min(Int64(30), audio.frames / 2)
            store.setAudioFades(audio.id, fadeIn: entering ? length : min(audio.localFadeInFrames, audio.frames - length),
                fadeOut: entering ? min(audio.localFadeOutFrames, audio.frames - length) : length)
        }
    }
    private func moveToStart() {
        if let audio { store.moveAudio(audio.id, to: 0) }
        else if let visual { store.placeVisual(visual.id, at: 0, lane: visual.lane) }
    }
    private func moveToPlayhead() {
        if let audio { store.moveAudio(audio.id, to: store.playheadFrame) }
        else if let visual { store.placeVisual(visual.id, at: store.playheadFrame, lane: visual.lane) }
    }
    private func raiseLayer(_ visual: Clip) {
        store.change { project in
            project.visualTrackCount = max(project.visualTrackCount, visual.lane + 2)
            try project.placeVisual(visual.id, at: project.position(of: visual), lane: visual.lane + 1)
        }
    }
}

private enum ClipTool: String, Identifiable {
    case text, size, rotate, appearance, trim, duration, sound, fades, arrange
    var id: Self { self }
    var title: String {
        switch self {
        case .text: return "Text & style"
        case .size: return "Size & position"
        case .rotate: return "Rotate"
        case .appearance: return "Opacity"
        case .trim: return "Trim & split"
        case .duration: return "Duration"
        case .sound: return "Sound"
        case .fades: return "Fades"
        case .arrange: return "Arrange"
        }
    }
    var symbol: String {
        switch self {
        case .text: return "textformat"
        case .size: return "arrow.up.left.and.arrow.down.right"
        case .rotate: return "rotate.right"
        case .appearance: return "circle.lefthalf.filled"
        case .trim: return "scissors"
        case .duration: return "clock"
        case .sound: return "speaker.wave.2"
        case .fades: return "waveform.path"
        case .arrange: return "square.3.layers.3d"
        }
    }
}

struct ToolboxAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, symbol: String, action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.action = action }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 17, weight: .light)).frame(height: 22)
                Text(title).font(.system(size: 10)).lineLimit(1)
            }.frame(maxWidth: .infinity).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

/// Local slider feedback; a completed gesture creates one normal undoable edit.
struct ToolboxSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let title: String
    let leading: String
    let trailing: String
    let commit: (Double) -> Void
    @State private var draft: Double?
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                Image(systemName: leading).frame(width: 18)
                Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, draft ?? value)) }, set: { draft = $0 }), in: range) { active in
                    editing = active
                    if !active, let draft { commit(draft); self.draft = nil }
                }.accessibilityLabel(title)
                Image(systemName: trailing).frame(width: 18)
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }.onChange(of: value) { _, _ in if !editing { draft = nil } }
    }
}

private extension Text {
    func toolboxHint() -> some View { font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
}

private struct PreciseTrimView: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    let isImage: Bool
    @State private var start = 0.0
    @State private var end = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !isImage { field("Source in", value: $start) }
            field(isImage ? "Duration" : "Source out", value: Binding(get: { isImage ? end - start : end }, set: { end = isImage ? start + $0 : $0 }))
            Button(isImage ? "Apply duration" : "Apply trim") { store.trim(start: start, end: end) }
        }.onAppear(perform: load).onChange(of: clip) { _, _ in load() }
    }
    private func load() { start = clip.startSeconds; end = Double(clip.outFrame) / 30 }
    private func field(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) { TextField(label, value: value, format: .number.precision(.fractionLength(3))).textFieldStyle(.roundedBorder).frame(width: 90) }
    }
}
