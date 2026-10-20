// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVKit
import LocalVideoCore
import SwiftUI

private let accent = Color(white: 0.9)
private let panel = WorkspaceStyle.panel

// Use the native AVKit view directly; this also keeps playback controls accessible.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

private struct VisualMoveDraft { let frame: Int64; let lane: Int }

struct EditorView: View {
    @ObservedObject var store: EditorStore
    @State private var showClipTools = true
    @State private var search = ""
    @State private var activeTool = "Library"
    @State private var showLeft = true
    @State private var showDirector = true
    @State private var showTimeline = true
    @State private var leftWidth = 320.0
    @State private var directorWidth = 384.0
    @State private var timelineHeight = 240.0
    @State private var resizeOrigin: Double?
    @State private var mediaPreview: UUID?
    @State private var editingTitle = false
    @State private var zoom = 0.4
    @State private var trimDraft: TimelineTrimDraft?
    @State private var movingClip: UUID?
    @State private var moveDraft: VisualMoveDraft?
    @State private var gestureCancelled = false
    @StateObject private var timelineScroll = TimelineScrollController()
    @StateObject private var director = DirectorController()
    @State private var dragTranslation = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            header
            if let warning = store.recoveryWarning {
                HStack(spacing: 10) {
                    Label(warning, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Try again", action: store.retryRecovery)
                    Button("Show copies", action: store.revealRecoveryCopies)
                }.padding(.horizontal, 14).padding(.vertical, 8).background(Color.orange.opacity(0.12))
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        WorkspaceRail(selected: activeTool, select: selectTool)
                        if showLeft {
                            sidebar.frame(width: leftWidth)
                            resizeDivider(vertical: true) { delta, ended in
                                if resizeOrigin == nil { resizeOrigin = leftWidth }
                                leftWidth = min(480, max(320, (resizeOrigin ?? 320) + delta))
                                if ended { resizeOrigin = nil }
                            }
                        }
                        preview.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    }.frame(minHeight: 150, maxHeight: .infinity)
                    if showTimeline {
                        resizeDivider(vertical: false) { delta, ended in
                            if resizeOrigin == nil { resizeOrigin = timelineHeight }
                            timelineHeight = min(400, max(200, (resizeOrigin ?? 240) - delta))
                            if ended { resizeOrigin = nil }
                        }
                        timeline.frame(height: timelineHeight)
                    }
                    if store.busy { footer }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showDirector {
                    resizeDivider(vertical: true) { delta, ended in
                        if resizeOrigin == nil { resizeOrigin = directorWidth }
                        directorWidth = min(500, max(300, (resizeOrigin ?? 384) - delta))
                        if ended { resizeOrigin = nil }
                    }
                    DirectorPanel(store: store, director: director) { showDirector = false }.frame(width: directorWidth)
                }
            }
        }
        .background(WorkspaceStyle.content).tint(accent)
        .background(WorkspaceKeyboard(handle: handleWorkspaceKey))
        .alert("Couldn’t complete that action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task(id: store.project.assets.map { try? MediaVisualSource($0) }) {
            let sources = Set(store.project.assets.compactMap { try? MediaVisualSource($0) })
            await MediaVisualCache.shared.retainSources(sources)
        }
        .onChange(of: store.selectedClip) { _, id in editingTitle = false; store.cancelCanvasTransform(); if id != nil { showLeft = true; if activeTool != "Transitions" { showClipTools = true } } }
        .onChange(of: store.selectedAudio) { _, id in if id != nil { showLeft = true; if activeTool != "Transitions" { showClipTools = true } } }
        .onChange(of: store.selectionRevision) { _, _ in if activeTool != "Transitions" { showClipTools = true }; showLeft = true }
        .onChange(of: store.busy) { _, busy in
            if busy {
                if trimDraft != nil || movingClip != nil { gestureCancelled = true }
                trimDraft = nil; movingClip = nil; moveDraft = nil
                timelineScroll.cancel()
            }
        }
        .onChange(of: store.project) { _, project in
            director.projectChanged(project)
            if trimDraft != nil || movingClip != nil { gestureCancelled = true }
            trimDraft = nil; movingClip = nil; moveDraft = nil
            timelineScroll.cancel()
        }
        .onChange(of: timelineScroll.offset) { _, _ in refreshTimelineDrag() }
        .onChange(of: zoom) { _, _ in cancelTimelineDrag() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in cancelTimelineDrag() }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Text("PLSTK").font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1.5)
                .accessibilityLabel("PLSTK")
            Menu {
                Button("New Project", action: store.newProject)
                Button("Open Project…", action: store.openProject)
                Button("Save Project") { store.save() }
                Button("Save Project As…") { store.save(as: true) }
            } label: { Image(systemName: "square.grid.2x2"); Text("Projects") }
                .menuStyle(.borderlessButton).fixedSize().disabled(store.busy)
            Divider().frame(height: 16)
            TextField("Project name", text: Binding(get: { store.project.name }, set: { name in store.change { $0.name = name } }))
                .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 180)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7)).disabled(store.busy)
            if store.dirty { Circle().fill(.white.opacity(0.4)).frame(width: 4, height: 4) }
            Spacer()
            Menu {
                Button("Landscape") { store.change { $0.width = 1280; $0.height = 720 } }
                Button("Portrait") { store.change { $0.width = 1080; $0.height = 1920 } }
                Button("Square") { store.change { $0.width = 1080; $0.height = 1080 } }
            } label: { Image(systemName: store.project.width == store.project.height ? "square" : (store.project.width > store.project.height ? "rectangle" : "rectangle.portrait")); Text(store.project.width == store.project.height ? "Square" : (store.project.width > store.project.height ? "Landscape" : "Portrait")) }.menuStyle(.borderlessButton).fixedSize().disabled(store.busy)
            Button("Save") { store.save() }.disabled(store.busy)
            Button(action: store.exportVideo) {
                Text("Export").font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 6).background(.white).clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).disabled(!store.canPreview).opacity(store.canPreview ? 1 : 0.4)
            Button { showDirector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle Director ]")
        }.buttonStyle(.borderless).padding(.leading, 78).padding(.trailing, 12).frame(height: 40).background(WorkspaceStyle.chrome)
    }
    private var hasSelection: Bool { store.clip != nil || store.audioClip != nil }
    private var editingSelection: Bool { showClipTools && hasSelection }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                if editingSelection {
                    Button(action: backToLibrary) { Label("Library", systemImage: "chevron.left").font(.system(size: 12)) }
                        .buttonStyle(.plain).help("Back to Library").accessibilityLabel("Back to Library")
                    Spacer()
                    Text(store.audioClip != nil ? "Edit audio" : "Edit clip").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    Text(activeTool == "Layout" ? "Canvas" : activeTool).font(.system(size: 18, weight: .semibold)).tracking(-0.36)
                    Spacer()
                    if hasSelection {
                        Button { showClipTools = true } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.plain).help("Edit selected clip").accessibilityLabel("Edit selected clip")
                    }
                }
                Button { showLeft = false } label: { Image(systemName: "sidebar.left") }.buttonStyle(.plain).help("Collapse panel [")
                    .accessibilityLabel("Collapse panel")
            }.padding(.horizontal, 16).frame(height: 50)
            if editingSelection {
                ClipToolbox(store: store).id(store.selectedAudio ?? store.selectedClip)
            } else if activeTool == "Layout" {
                ProjectCanvasPanel(store: store)
            } else if activeTool == "Text" { TitlesPanel(store: store) }
            else if activeTool == "Transitions" { TransitionsPanel(store: store) }
            else if activeTool == "Audio" { audioPanel }
            else { library }
        }.frame(maxHeight: .infinity).background(panel)
    }
    private func backToLibrary() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        showClipTools = false; activeTool = "Library"; store.cancelCanvasTransform()
    }
    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project audio").font(.system(size: 12, weight: .medium))
            Button("Import audio…", systemImage: "plus", action: store.importMedia).disabled(store.busy)
            ForEach(store.project.assets.filter { $0.isAudioOnly }) { asset in
                Button { store.selectedAsset = asset.id; mediaPreview = asset.id } label: { Label(asset.name, systemImage: "waveform") }
                    .popover(isPresented: Binding(get: { mediaPreview == asset.id }, set: { if !$0 { mediaPreview = nil } })) {
                        LibraryMediaPreview(media: asset) { store.addAsset(asset.id); mediaPreview = nil }
                    }
            }
            Text("Choose a sound to preview it, then add it to the timeline.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Search project media…", text: $search).textFieldStyle(.roundedBorder)
                Spacer()
                Button("Add", systemImage: "plus", action: store.importMedia).help("Import media ⌘I").disabled(store.busy)
            }
            if !store.project.assets.contains(where: { !$0.isTitle }) {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 20, weight: .light)).padding(12)
                        .background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 14))
                    Text("No media yet").font(.system(size: 13, weight: .medium))
                    Text("Imported video, audio, and images appear here.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 210)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 30)
            } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.project.assets.filter { !$0.isTitle && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { asset in
                        Button { store.selectedAsset = asset.id; mediaPreview = asset.id } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                MediaThumbnail(media: asset).frame(height: 100).clipped()
                                    .overlay(alignment: .bottomTrailing) {
                                        Text(String(format: "%.1fs", asset.duration)).font(.system(size: 10, design: .monospaced))
                                            .padding(4).background(.black.opacity(0.7)).padding(5)
                                    }
                                Text(asset.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(asset.isAudioOnly ? "Audio" : (asset.isImage ? "Image" : "Video")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(7).background(store.selectedAsset == asset.id ? Color.white.opacity(0.08) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(store.selectedAsset == asset.id ? Color.white.opacity(0.35) : .clear))
                        }.buttonStyle(.plain).disabled(store.busy)
                        .popover(isPresented: Binding(get: { mediaPreview == asset.id }, set: { if !$0 { mediaPreview = nil } })) {
                            LibraryMediaPreview(media: asset) { store.addAsset(asset.id); mediaPreview = nil; showLeft = true }
                        }
                        .contextMenu {
                            Button("Add to timeline") { store.addAsset(asset.id) }
                            Button("Reveal original") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)]) }
                        }
                    }
                }
            }
            }
            if let asset = store.asset, !asset.isTitle {
                Button("Add to timeline", systemImage: "plus") { store.addAsset(asset.id) }.disabled(store.busy)
                Button("Relink media…", action: store.relink).font(.caption).disabled(store.busy)
            }
        }.padding(14).frame(maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in importDrop(urls, add: false) }
    }
    private var preview: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.black)
                if let player = store.player, store.previewProblem == nil { PlayerSurface(player: player) }
                else {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle").font(.system(size: 30, weight: .ultraLight))
                        Text(store.project.clips.isEmpty ? (store.project.audioClips.isEmpty ? "Your timeline is empty" : "Add video or an image to preview and export") : (store.previewProblem ?? "Preparing live preview…"))
                            .font(.system(size: 13, weight: .semibold))
                        if store.project.clips.isEmpty {
                            Text("Import footage to start your first cut.").font(.system(size: 12)).foregroundStyle(.secondary)
                            Button(action: store.importMedia) {
                                Label("Import media", systemImage: "square.and.arrow.up").font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
                                    .padding(.horizontal, 12).padding(.vertical, 9).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(store.busy)
                        }
                    }
                }
                if store.canTransformCanvas, let clip = store.clip {
                    CanvasTransformView(store: store, clip: clip).id(clip.id)
                }
            }.overlay(alignment: .topLeading) {
                if store.canTransformCanvas, store.sourceForClip?.isTitle == true, let clip = store.clip {
                    Button { editingTitle = true } label: { Label("Edit text", systemImage: "text.cursor") }
                        .buttonStyle(.bordered).padding(8).accessibilityLabel("Edit title in viewer")
                        .popover(isPresented: $editingTitle) {
                            TitleContentControls(store: store, clipID: clip.id).padding(18).frame(width: 300).preferredColorScheme(.dark)
                        }
                }
            }.aspectRatio(CGFloat(store.project.width) / CGFloat(store.project.height), contentMode: .fit)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            if !showTimeline {
                HStack {
                    Button(action: store.togglePlayback) { Image(systemName: store.isPlaying ? "pause" : "play") }.disabled(store.player == nil || store.busy)
                    Text(timecode(store.playheadFrame)).font(.system(size: 10, design: .monospaced))
                    Spacer()
                    Button("Show timeline") { showTimeline = true }
                }.buttonStyle(.borderless)
            }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.135))
            .dropDestination(for: URL.self) { urls, _ in importDrop(urls, add: true) }
    }
    private var timeline: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 12) {
                    Text(timecode(store.playheadFrame) + " / " + timecode(store.totalFrames)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Button(action: store.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(store.busy || store.past.isEmpty).help("Undo ⌘Z")
                    Button(action: store.redo) { Image(systemName: "arrow.uturn.forward") }.disabled(store.busy || store.future.isEmpty).help("Redo ⇧⌘Z")
                    Button(action: store.splitAtPlayhead) { Image(systemName: "rectangle.split.2x1") }.disabled(!store.canSplitAtPlayhead).help("Split at playhead B")
                    Button { store.snappingEnabled.toggle() } label: {
                        Image(systemName: "paperclip").padding(5).background(store.snappingEnabled ? Color.white.opacity(0.12) : .clear).clipShape(RoundedRectangle(cornerRadius: 5))
                    }.help("Toggle snapping S")
                    Button(action: store.addVisualTrack) { Image(systemName: "plus.rectangle.on.rectangle") }.help("Add visual track").disabled(store.busy || store.project.visualTrackCount >= 32)
                    Spacer()
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { log2(zoom) }, set: { zoom = pow(2, $0) }), in: log2(0.025)...log2(26.0)).frame(width: 90).accessibilityLabel("Timeline zoom")
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                    Button { showTimeline = false } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }.help("Hide timeline (backslash)")
                }
                HStack(spacing: 16) {
                    Button { store.seek(toFrame: 0) } label: { Image(systemName: "backward.end") }.help("Jump to beginning")
                    Button(action: store.togglePlayback) { Image(systemName: store.isPlaying ? "pause" : "play") }.help("Play / pause Space").disabled(store.player == nil || store.busy)
                    Button { store.seek(toFrame: max(0, store.totalFrames - 1)) } label: { Image(systemName: "forward.end") }.help("Jump to end")
                }
            }.buttonStyle(.borderless).padding(.horizontal, 12).frame(height: 38).background(Color(white: 20.0 / 255))
            GeometryReader { geometry in
                let available = max(200, geometry.size.width - 190)
                let duration = max(0, store.project.duration)
                let scale = 50 * zoom
                let width = max(available, max(duration * scale, timelineScroll.requiredWidth) + available * 0.5)
                let contentHeight = max(geometry.size.height, CGFloat(36 + visualLanes.count * 76 + activeAudioLanes.count * 60))
                ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading) {
                        Text(timecode(store.playheadFrame)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(height: 28)
                        ForEach(visualLanes, id: \.self) { lane in Label("Video \(lane + 1)", systemImage: "film").font(.system(size: 10)).frame(height: 68) }
                        ForEach(activeAudioLanes, id: \.self) { lane in Label("Audio \(lane + 1)", systemImage: "waveform").font(.system(size: 10)).frame(height: 52) }
                        Spacer()
                    }.padding(.leading, 12).frame(width: 190, height: contentHeight, alignment: .topLeading)
                    Divider()
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 8) {
                            timelineRuler(width: width, duration: width / scale)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                    guard !store.busy else { return }
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    store.seek(toFrame: Int64((max(0, value.location.x) / scale * 30).rounded()))
                                })
                            ForEach(visualLanes, id: \.self) { lane in
                                ZStack(alignment: .topLeading) {
                                    Rectangle().fill(Color.white.opacity(0.025)).frame(width: width, height: 68)
                                        .onTapGesture { if !store.busy { store.clearSelection() } }
                                    ForEach(store.project.clips.filter { $0.lane == lane }) { clip in
                                        timelineClip(clip, scale: scale)
                                            .offset(x: Double(store.project.position(of: clip)) / 30 * scale)
                                    }
                                }.frame(width: width, height: 68, alignment: .topLeading)
                                    .zIndex(store.project.clips.contains { $0.lane == lane && $0.id == movingClip } ? 10 : 0)
                            }
                            ForEach(activeAudioLanes, id: \.self) { lane in AudioTimelineLane(store: store, lane: lane, scale: scale, scrolling: timelineScroll) }
                            if store.project.clips.isEmpty && store.project.audioClips.isEmpty {
                                Text("Drop media to start").font(.system(size: 12)).foregroundStyle(.tertiary).padding(24)
                            }
                            Spacer(minLength: 0)
                        }.frame(width: width, alignment: .leading)
                            .frame(minHeight: contentHeight, alignment: .topLeading)
                            .coordinateSpace(name: "timeline")
                            .background(TimelineScrollProbe(controller: timelineScroll))
                            .overlay(alignment: .topLeading) {
                                Rectangle().fill(accent).frame(width: 1, height: contentHeight)
                                    .overlay(alignment: .top) { Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundStyle(accent) }
                                    .offset(x: CGFloat(Double(store.playheadFrame) / 30.0 * Double(scale))).allowsHitTesting(false)
                            }
                    }.coordinateSpace(name: "timelineViewport")
                }
                }
                .onChange(of: geometry.size) { _, _ in cancelTimelineDrag() }
            }
            HStack {
                if let trimDraft {
                    Text(String(format: "Trim · %.3f → %.3f s · release to apply", Double(trimDraft.clip.inFrame) / 30, Double(trimDraft.clip.outFrame) / 30))
                } else if movingClip != nil {
                    Text("Move clip · release to place; occupied positions are rejected")
                } else {
                    Text("Drag clips to place in time or change track · drag edges to trim · Esc cancels")
                }
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 25)
        }.background(Color(white: 26.0 / 255))
            .dropDestination(for: URL.self) { urls, _ in importDrop(urls, add: true) }
            .onExitCommand(perform: cancelTimelineDrag)
            .onDisappear(perform: cancelTimelineDrag)
    }
    private func timelineRuler(width: CGFloat, duration: Double) -> some View {
        Canvas { context, size in
            let scale = width / duration
            let intervals = [0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600, 900, 1800, 3600]
            let step = intervals.first { $0 * scale >= 72 } ?? 3600
            let minor = step / 10
            var index = 0
            while Double(index) * minor <= duration {
                let seconds = Double(index) * minor
                let x = seconds * scale
                let major = index % 10 == 0
                var tick = Path(); tick.move(to: CGPoint(x: x, y: major ? 20 : 24)); tick.addLine(to: CGPoint(x: x, y: 28))
                context.stroke(tick, with: .color(.white.opacity(0.15)))
                if major {
                    let label = step < 1 ? String(format: "%.1fs", seconds) : String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
                    context.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.gray), at: CGPoint(x: x + 4, y: 9), anchor: .topLeading)
                }
                index += 1
            }
        }.frame(height: 28)
    }
    private func timelineClip(_ clip: Clip, scale: Double) -> some View {
        let draft = movingClip == clip.id ? moveDraft : nil
        return TimelineClipCell(clip: clip, title: (try? store.project.asset(for: clip).name) ?? "Missing media",
                         media: try? store.project.asset(for: clip), width: CGFloat(clip.duration * scale), selected: store.selectedClip == clip.id,
                         moving: movingClip == clip.id, draft: trimDraft?.clip.id == clip.id ? trimDraft : nil,
                         select: { store.selectClip(clip) },
                         begin: { gestureCancelled = false }, cancel: cancelTimelineDrag,
                         move: { horizontal, vertical, ended in
            if ended && gestureCancelled { gestureCancelled = false; timelineScroll.end(clip.id); return }
            guard !store.busy, !gestureCancelled else { return }
            if !ended, movingClip == nil {
                store.player?.pause(); store.selectClip(clip); timelineScroll.begin(clip.id)
            }
            dragTranslation = CGSize(width: horizontal, height: vertical)
            updateMoveDraft(clip, scale: scale)
            if ended {
                let draft = moveDraft
                movingClip = nil; moveDraft = nil
                if let draft { store.placeVisual(clip.id, at: draft.frame, lane: draft.lane) }
                timelineScroll.end(clip.id)
            } else { movingClip = clip.id; trimDraft = nil }
        }, trim: { edge, points, ended in
            guard !store.busy else { return }
            if ended {
                defer { gestureCancelled = false; timelineScroll.end(clip.id) }
                guard !gestureCancelled, trimDraft?.clip.id == clip.id else { return }
                let distance = timelineScroll.distance(points)
                trimDraft = nil
                store.trimVisual(clip.id, edge: edge, delta: trimDragDelta(clip, edge: edge, points: distance, scale: scale))
            } else {
                guard !gestureCancelled else { return }
                if trimDraft == nil { store.player?.pause(); store.selectClip(clip); timelineScroll.begin(clip.id) }
                dragTranslation = CGSize(width: points, height: 0)
                updateTrimDraft(clip, edge: edge, scale: scale)
                movingClip = nil; moveDraft = nil
            }
        })
        .offset(x: draft.map { Double($0.frame - store.project.position(of: clip)) / 30 * scale } ?? 0,
                y: draft.map { Double(clip.lane - $0.lane) * 76 } ?? 0)
        .zIndex(draft != nil ? 10 : 0)
        .disabled(store.busy)
        .contextMenu {
            Button("Select clip") { store.selectClip(clip) }
            Button("Move to beginning") { store.placeVisual(clip.id, at: 0, lane: clip.lane) }.disabled(store.busy)
            Button("Move to end") { store.placeVisual(clip.id, at: store.project.videoFrames, lane: clip.lane) }.disabled(store.busy)
        }
    }
    private func updateMoveDraft(_ clip: Clip, scale: Double) {
        let delta = TimelineSnapping.frameDelta(points: timelineScroll.distance(dragTranslation.width), pointsPerSecond: scale)
        let raw = max(0, min(30_000_000, store.project.position(of: clip) + delta))
        let frame = max(0, store.snapTimelineFrame(raw, excluding: clip.id, scale: scale))
        let lane = min(store.project.visualTrackCount - 1, max(0, clip.lane - Int((dragTranslation.height / 76).rounded())))
        moveDraft = VisualMoveDraft(frame: frame, lane: lane)
        timelineScroll.extend(to: Double(frame + clip.frames) / 30 * scale)
    }
    private func updateTrimDraft(_ clip: Clip, edge: TrimEdge, scale: Double) {
        let delta = trimDragDelta(clip, edge: edge, points: timelineScroll.distance(dragTranslation.width), scale: scale)
        guard let candidate = try? store.project.trimmedClip(clip.id, edge: edge, delta: delta) else { return }
        let effective = edge == .start ? candidate.inFrame - clip.inFrame : candidate.outFrame - clip.outFrame
        trimDraft = TimelineTrimDraft(clip: candidate, edge: edge, offset: CGFloat(Double(effective) / 30 * scale))
        timelineScroll.extend(to: Double(store.project.position(of: clip) + clip.frames + (edge == .end ? effective : 0)) / 30 * scale)
    }
    private func refreshTimelineDrag() {
        guard !gestureCancelled, !store.busy else { return }
        if let id = movingClip, let clip = store.project.clips.first(where: { $0.id == id }) {
            updateMoveDraft(clip, scale: 50 * zoom)
        } else if let draft = trimDraft, let clip = store.project.clips.first(where: { $0.id == draft.clip.id }) {
            updateTrimDraft(clip, edge: draft.edge, scale: 50 * zoom)
        }
    }
    private func cancelTimelineDrag() {
        if trimDraft != nil || movingClip != nil { gestureCancelled = true }
        trimDraft = nil; movingClip = nil; moveDraft = nil
        timelineScroll.cancel()
    }
    private var footer: some View {
        HStack(spacing: 14) {
            Circle().fill(store.busy ? Color.orange : accent).frame(width: 6, height: 6)
            Text(store.status).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            if store.busy {
                ProgressView(value: store.progress).frame(width: 110)
                Button("Cancel", action: store.cancel).controlSize(.small)
            }
            Spacer()
            Text("LOCAL EDITOR").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.tertiary)
        }.padding(.horizontal, 12).padding(.vertical, 5).background(WorkspaceStyle.chrome)
    }
    private func importDrop(_ urls: [URL], add: Bool) -> Bool {
        guard !store.busy, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        store.importURLs(urls, addToTimeline: add)
        return true
    }
    private func trimDragDelta(_ clip: Clip, edge: TrimEdge, points: Double, scale: Double) -> Int64 {
        let delta = TimelineSnapping.frameDelta(points: points, pointsPerSecond: scale)
        let start = store.project.position(of: clip)
        let boundary = edge == .start ? start : start + clip.frames
        let snapped = store.snapTimelineFrame(boundary + delta, excluding: clip.id, scale: scale) - boundary
        return edge == .start ? max(-start, snapped) : snapped
    }
    private var visualLanes: [Int] { Array((0..<store.project.visualTrackCount).reversed()) }
    private var activeAudioLanes: [Int] { Array(Set(store.project.audioClips.map(\.lane))).sorted() }
    private func selectTool(_ tool: String) {
        let wasSelected = activeTool == tool && showLeft && !editingSelection
        activeTool = tool; showLeft = !wasSelected; showClipTools = false
        store.cancelCanvasTransform()
    }
    private func resizeDivider(vertical: Bool, resize: @escaping (Double, Bool) -> Void) -> some View {
        Rectangle().fill(Color.white.opacity(0.04))
            .frame(width: vertical ? 4 : nil, height: vertical ? nil : 4)
            .contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .global).onChanged { value in resize(Double(vertical ? value.translation.width : value.translation.height), false) }
                .onEnded { value in resize(Double(vertical ? value.translation.width : value.translation.height), true) })
    }
    private func handleWorkspaceKey(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !store.busy else { return false }
        if modifiers == .command, key == "\u{f702}" { store.seek(toFrame: 0); return true }
        if modifiers == .command, key == "\u{f703}" { store.seek(toFrame: max(0, store.totalFrames - 1)); return true }
        if modifiers == .command, key == "d" { store.duplicateClip(); return true }
        guard modifiers.isEmpty else { return false }
        if store.canvasDraft != nil {
            if key == "\u{1b}" { store.cancelCanvasTransform() }
            return true
        }
        switch key.lowercased() {
        case "b": store.splitAtPlayhead()
        case "s": store.snappingEnabled.toggle()
        case "m":
            if let audio = store.audioClip {
                store.updateAudio(audio.id, start: Double(audio.startFrame) / 30, sourceIn: Double(audio.inFrame) / 30,
                    sourceOut: Double(audio.outFrame) / 30, lane: audio.lane, volume: audio.volume, muted: !audio.muted)
            } else if let clip = store.clip {
                store.change { project in
                    if let index = project.clips.firstIndex(where: { $0.id == clip.id }) { project.clips[index].muted.toggle() }
                }
            }
        case "[": showLeft.toggle()
        case "]": showDirector.toggle()
        case "\\": showTimeline.toggle()
        case "\u{7f}": store.removeClip()
        case "\u{f702}": store.seek(toFrame: store.playheadFrame - 1)
        case "\u{f703}": store.seek(toFrame: store.playheadFrame + 1)
        default: return false
        }
        return true
    }
    private func sectionTitle(_ text: String, detail: String? = nil) -> some View {
        HStack {
            Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.4)
            if let detail { Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary) }
        }.foregroundStyle(.secondary)
    }
    private func timecode(_ frame: Int64) -> String {
        String(format: "%02d:%02d:%02d", frame / 1800, (frame / 30) % 60, frame % 30)
    }

}

// The media library shares the same bounded cache as timeline thumbnail strips.
struct MediaThumbnail: View {
    let media: MediaAsset
    @State private var image: CGImage?
    var body: some View {
        let source = try? MediaVisualSource(media)
        ZStack {
            Rectangle().fill(Color(white: 0.14))
            if media.isAudioOnly { Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(.secondary) }
            else if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "film").foregroundStyle(.tertiary) }
        }.task(id: source) {
            image = nil
            guard let source, !media.isAudioOnly else { return }
            let result = try? await MediaVisualCache.shared.thumbnail(source, frame: 0)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
