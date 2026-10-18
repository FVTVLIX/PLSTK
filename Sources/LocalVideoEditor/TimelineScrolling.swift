// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import LocalVideoCore
import SwiftUI

@MainActor final class TimelineScrollController: ObservableObject {
    @Published private(set) var offset = 0.0
    @Published private(set) var requiredWidth = 0.0
    @Published private(set) var cancellation = 0
    private(set) var owner: UUID?
    private var initialOffset = 0.0
    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    func attach(_ scrollView: NSScrollView?) {
        guard self.scrollView !== scrollView else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; self.scrollView = scrollView
        guard let scrollView else { cancel(); return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readOffset() }
            }
        readOffset()
    }
    private func readOffset() {
        let value = Double(scrollView?.contentView.bounds.minX ?? 0)
        if offset != value { offset = value }
    }
    func begin(_ id: UUID) {
        guard owner != id else { return }
        stopTimer(); readOffset(); owner = id; initialOffset = offset; requiredWidth = 0
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func distance(_ translation: Double) -> Double {
        TimelineNavigation.dragDistance(translation: translation, initialOffset: initialOffset, currentOffset: offset)
    }
    func extend(to end: Double) {
        guard owner != nil, end.isFinite else { return }
        let value = max(0, end)
        if value > requiredWidth { requiredWidth = value }
    }
    func end(_ id: UUID) {
        guard owner == id else { return }
        stopTimer(); owner = nil; requiredWidth = 0
    }
    func cancel() {
        guard owner != nil else { stopTimer(); return }
        stopTimer(); owner = nil; requiredWidth = 0; cancellation += 1
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func tick() {
        guard owner != nil, let scrollView, let window = scrollView.window,
              NSApp.isActive, window.isKeyWindow, NSEvent.pressedMouseButtons & 1 != 0 else { stopTimer(); return }
        let clip = scrollView.contentView
        let screen = NSEvent.mouseLocation
        let point = clip.convert(window.convertPoint(fromScreen: screen), from: nil)
        let visible = clip.visibleRect.intersection(clip.bounds)
        guard !visible.isEmpty, point.y >= visible.minY, point.y <= visible.maxY else {
            lastTick = ProcessInfo.processInfo.systemUptime; return
        }
        let now = ProcessInfo.processInfo.systemUptime
        advance(pointer: Double(point.x - clip.bounds.minX), elapsed: now - lastTick)
        lastTick = now
    }
    /// The native scrolling step is separate from pointer sampling for isolated verification.
    func advance(pointer: Double, elapsed: Double) {
        guard owner != nil, let scrollView else { return }
        let clip = scrollView.contentView
        let velocity = TimelineNavigation.edgeVelocity(pointer: pointer, viewport: Double(clip.bounds.width))
        let maximum = max(0, Double(scrollView.documentView?.frame.width ?? 0) - Double(clip.bounds.width))
        let next = TimelineNavigation.scrollOffset(offset, velocity: velocity, elapsed: elapsed, maximum: maximum)
        guard next != offset else { return }
        clip.scroll(to: NSPoint(x: next, y: clip.bounds.minY)); scrollView.reflectScrolledClipView(clip)
        readOffset()
    }
    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

struct TimelineScrollProbe: NSViewRepresentable {
    let controller: TimelineScrollController
    final class Probe: NSView {
        weak var controller: TimelineScrollController?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        func connect() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.controller?.attach(self.window == nil ? nil : self.enclosingScrollView)
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.controller = controller; return view }
    func updateNSView(_ view: Probe, context: Context) { view.controller = controller; view.connect() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.controller?.attach(nil); view.controller = nil }
}
