// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import LocalVideoCore
import SwiftUI

/// Drag state belongs to the workspace; the project changes only on release.
struct TimelineTrimDraft {
    let clip: Clip
    let edge: TrimEdge
    let offset: CGFloat
}

struct TimelineClipCell: View {
    let clip: Clip
    let title: String
    let media: MediaAsset?
    let width: CGFloat
    let selected: Bool
    let moving: Bool
    let draft: TimelineTrimDraft?
    let select: () -> Void
    let begin: () -> Void
    let cancel: () -> Void
    @State private var gestureActive = false
    @GestureState private var dragging = false
    let move: (Double, Double, Bool) -> Void
    let trim: (TrimEdge, Double, Bool) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            clipBody
            trimOutline
            // Narrow clips retain their time width; numeric trim controls remain in the inspector.
            if width >= 24 {
                handle(.start).offset(x: trimOffset(.start))
                handle(.end).offset(x: width - 8 + trimOffset(.end))
            }
        }.frame(width: width, height: 68)
            .zIndex(draft != nil ? 2 : 0)
            .onChange(of: dragging) { _, active in
                if !active { if gestureActive { cancel() }; gestureActive = false }
            }
            .help("Drag to place in time or move between tracks. Drag an edge to trim. Small clips can be trimmed in the inspector.")
    }
    private var clipBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Text(String(format: "%.2fs", draft?.clip.duration ?? clip.duration))
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 11).frame(height: 18)
            TimelineMediaVisuals(clip: clip, media: media, width: width)
        }
            .frame(width: width, height: 68, alignment: .leading)
            .background(Color(red: 0.24, green: 0.28, blue: 0.39))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.white : Color.black.opacity(0.5), lineWidth: selected ? 2 : 1))
            .clipped().opacity(moving ? 0.45 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("timelineViewport"))
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { value in
                    if !gestureActive { gestureActive = true; begin() }
                    move(Double(value.translation.width), Double(value.translation.height), false)
                }
                .onEnded { value in
                    move(Double(value.translation.width), Double(value.translation.height), true); gestureActive = false
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(String(format: "%.2f", clip.duration)) seconds")
            .accessibilityAddTraits(.isButton).accessibilityAction { select() }
    }
    @ViewBuilder private var trimOutline: some View {
        if let draft {
            let left: CGFloat = draft.edge == .start ? draft.offset : 0
            let right: CGFloat = draft.edge == .end ? draft.offset : 0
            RoundedRectangle(cornerRadius: 4).stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .frame(width: max(1, width + right - left), height: 68).offset(x: left)
                .allowsHitTesting(false)
        }
    }
    private func trimOffset(_ edge: TrimEdge) -> CGFloat {
        guard let draft, draft.edge == edge else { return 0 }
        return draft.offset
    }
    private func handle(_ edge: TrimEdge) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(selected ? 0.55 : 0.20))
            .frame(width: 8, height: 68)
            .overlay { Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: 18) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("timelineViewport"))
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { value in
                    if !gestureActive { gestureActive = true; begin() }
                    trim(edge, Double(value.translation.width), false)
                }
                .onEnded { value in
                    trim(edge, Double(value.translation.width), true); gestureActive = false
                })
            .accessibilityLabel(edge == .start ? "Trim start" : "Trim end")
    }
}
