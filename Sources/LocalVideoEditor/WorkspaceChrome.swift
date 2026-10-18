// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import SwiftUI

// Dimensions and surfaces verified against Cardboard 1.3.1's shipped editor.
enum WorkspaceStyle {
    static let chrome = Color(white: 10.0 / 255)
    static let panel = Color(white: 21.0 / 255)
    static let content = Color(white: 23.0 / 255)
}

struct WorkspaceRail: View {
    let selected: String
    let select: (String) -> Void
    private let tools: [(String, String, Bool)] = [
        ("Library", "folder", true), ("Layout", "square.grid.2x2", true),
        ("Audio", "music.note", true), ("Captions", "captions.bubble", false),
        ("Text", "textformat", true), ("Transitions", "circle.lefthalf.filled", false),
        ("Effects", "wand.and.stars", false)
    ]
    var body: some View {
        VStack(spacing: 12) {
            ForEach(tools, id: \.0) { name, symbol, available in
                Button { select(name) } label: {
                    Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                        .frame(width: 34, height: 34)
                        .background(selected == name ? Color.white.opacity(0.10) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(!available)
                    .accessibilityLabel(name).help(available ? name : "\(name) — not implemented yet")
            }
            Spacer()
        }.padding(.top, 14).frame(width: 46).background(WorkspaceStyle.chrome)
    }
}

struct DirectorPanel: View {
    var hide: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New chat").font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer()
                Button(action: hide) { Image(systemName: "sidebar.right") }.buttonStyle(.plain).help("Hide Director ]")
            }.padding(12)
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(.tertiary)
                Text("Your editing assistant").font(.system(size: 13, weight: .medium))
                Text("Your assistant will be available here soon.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }.padding(24)
            Spacer()
            VStack(alignment: .leading) {
                Text("Describe the edit…").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                HStack {
                    Image(systemName: "paperclip").foregroundStyle(.tertiary)
                    Spacer()
                    Text("Assistant unavailable").font(.system(size: 10)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).foregroundStyle(.tertiary)
                }
            }.padding(16).frame(height: 118).background(Color(white: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))
                .padding(12).accessibilityElement(children: .combine).accessibilityLabel("Assistant unavailable. Chat editing unavailable.")
        }.frame(maxHeight: .infinity).background(WorkspaceStyle.panel)
    }
}

/// Scope plain editing keys to this window, and let text fields receive text.
struct WorkspaceKeyboard: NSViewRepresentable {
    let handle: (String, NSEvent.ModifierFlags) -> Bool
    final class Coordinator {
        var handle: (String, NSEvent.ModifierFlags) -> Bool
        weak var view: NSView?
        var monitor: Any?
        init(_ handle: @escaping (String, NSEvent.ModifierFlags) -> Bool) { self.handle = handle }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(handle) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let coordinator, let window = coordinator.view?.window, event.window === window,
                  !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            return coordinator.handle(event.charactersIgnoringModifiers ?? "", flags) ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
}
