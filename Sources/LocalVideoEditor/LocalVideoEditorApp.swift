// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import SwiftUI

final class EditorDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var store: EditorStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.confirmDiscard() ?? true else { return .terminateCancel }
        store?.cleanup(); return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store?.confirmDiscard() ?? true else { return false }
        store?.dirty = false
        return true
    }
}

struct WindowHook: NSViewRepresentable {
    var delegate: EditorDelegate
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = delegate }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main struct PLSTKApp: App {
    @NSApplicationDelegateAdaptor(EditorDelegate.self) var delegate
    @StateObject private var store = EditorStore()
    var body: some Scene {
        Window("PLSTK", id: "editor") {
            EditorView(store: store)
                .ignoresSafeArea(.container, edges: .top)
                .background(WindowHook(delegate: delegate))
                .onAppear {
                    delegate.store = store
                    DispatchQueue.main.async { store.startRecovery() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in store.flushRecovery() }
                .frame(minWidth: 1000, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project", action: store.newProject).keyboardShortcut("n").disabled(store.busy)
                Button("Open Project…", action: store.openProject).keyboardShortcut("o").disabled(store.busy)
                Button("Import Media…", action: store.importMedia).keyboardShortcut("i").disabled(store.busy)
                Divider()
                Button("Recover Unsaved Edit…") { store.offerRecovery() }.disabled(store.busy)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { store.save() }.keyboardShortcut("s").disabled(store.busy)
                Button("Save Project As…") { store.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(store.busy)
                Divider()
                Button("Export MP4…", action: store.exportVideo).keyboardShortcut("e").disabled(!store.canPreview)
            }
            CommandMenu("Playback") {
                Button("Play / Pause", action: store.togglePlayback).keyboardShortcut(.space, modifiers: []).disabled(store.player == nil || store.busy)
                Button("Split at Playhead (B)", action: store.splitAtPlayhead).disabled(!store.canSplitAtPlayhead)
                Button("Render Preview", action: store.buildPreview).disabled(!store.canPreview)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: store.undo).keyboardShortcut("z").disabled(store.busy || store.past.isEmpty)
                Button("Redo", action: store.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store.busy || store.future.isEmpty)
            }
        }
    }
}
