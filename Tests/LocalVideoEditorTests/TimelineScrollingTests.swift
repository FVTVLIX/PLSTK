// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import SwiftUI
import XCTest
@testable import LocalVideoEditor
import LocalVideoCore

final class TimelineScrollingTests: XCTestCase {
    @MainActor private func viewport() -> (TimelineScrollController, NSScrollView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 160))
        scroll.borderType = .noBorder
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 2400, height: 160))
        let controller = TimelineScrollController(); controller.attach(scroll)
        return (controller, scroll)
    }
    func testProbeConnectsToHorizontalViewportInsideVerticalScroll() async throws {
        let (window, controller) = await MainActor.run {
            let controller = TimelineScrollController()
            let root = ScrollView(.vertical) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 80, height: 300)
                    ScrollView(.horizontal) {
                        Color.clear.frame(width: 2400, height: 300)
                            .background(TimelineScrollProbe(controller: controller))
                    }.frame(width: 400, height: 160)
                }
            }.frame(width: 480, height: 160)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            window.contentView?.layoutSubtreeIfNeeded()
            return (window, controller)
        }
        // SwiftUI mounts its native scroll hierarchy on the next run loop pass.
        try await Task.sleep(nanoseconds: 150_000_000)
        await MainActor.run {
            window.contentView?.layoutSubtreeIfNeeded()
            let id = UUID(); controller.begin(id)
            controller.advance(pointer: 399, elapsed: 1.0 / 60)
            XCTAssertGreaterThan(controller.offset, 5, "The probe must use the horizontal scroll view, not the enclosing vertical one")
            controller.end(id); window.close()
        }
    }
    func testNativeScrollUpdatesDragDistanceAndStopsAtBothBounds() async {
        await MainActor.run {
            let (controller, scroll) = viewport(); let id = UUID()
            controller.begin(id)
            for _ in 0..<10 { controller.advance(pointer: 400, elapsed: 1.0 / 60) }
            XCTAssertEqual(controller.offset, 100, accuracy: 0.1)
            XCTAssertEqual(controller.distance(25), 125, accuracy: 0.1)
            XCTAssertEqual(scroll.contentView.bounds.minX, 100, accuracy: 0.1)
            for _ in 0..<500 { controller.advance(pointer: 400, elapsed: 1.0 / 60) }
            XCTAssertEqual(controller.offset, 2000, accuracy: 0.1)
            for _ in 0..<500 { controller.advance(pointer: 0, elapsed: 1.0 / 60) }
            XCTAssertEqual(controller.offset, 0, accuracy: 0.1)
            controller.end(id)
        }
    }
    func testScrollingAnAlreadyScrolledViewportDoesNotJumpAtDragStart() async {
        await MainActor.run {
            let (controller, scroll) = viewport()
            scroll.contentView.scroll(to: NSPoint(x: 600, y: 0))
            let id = UUID(); controller.begin(id)
            XCTAssertEqual(controller.distance(0), 0, accuracy: 0.1)
            controller.advance(pointer: 400, elapsed: 1.0 / 60)
            XCTAssertEqual(controller.distance(-25), -15, accuracy: 0.1)
            XCTAssertEqual(TimelineSnapping.frameDelta(points: controller.distance(-25), pointsPerSecond: 30), -15)
            controller.end(id)
        }
    }
    func testCancelAndReleaseStopScrollingAndDiscardExtraWorkingRoom() async {
        await MainActor.run {
            let (controller, scroll) = viewport(); let id = UUID()
            controller.begin(id); controller.extend(to: 3000)
            XCTAssertEqual(controller.requiredWidth, 3000)
            controller.advance(pointer: 400, elapsed: 1.0 / 60)
            let position = controller.offset
            controller.cancel()
            XCTAssertNil(controller.owner); XCTAssertEqual(controller.requiredWidth, 0)
            controller.advance(pointer: 400, elapsed: 1.0 / 60)
            XCTAssertEqual(controller.offset, position)
            XCTAssertEqual(scroll.contentView.bounds.minX, position, accuracy: 0.1)
            controller.begin(id); XCTAssertEqual(controller.distance(0), 0, accuracy: 0.1)
            controller.end(UUID()); XCTAssertEqual(controller.owner, id)
            controller.end(id); XCTAssertNil(controller.owner)
        }
    }
    func testNativeScrollCreatesOnlyDraftDistanceUntilTheCallerCommits() async throws {
        try await MainActor.run {
            let (controller, scroll) = viewport()
            var project = VideoProject(); let id = try project.addTitle(TextTitle(), at: 30)
            let original = project; controller.begin(id)
            controller.advance(pointer: 400, elapsed: 1.0 / 60)
            let delta = TimelineSnapping.frameDelta(points: controller.distance(20), pointsPerSecond: 30)
            XCTAssertEqual(project, original)
            try project.placeVisual(id, at: 30 + delta, lane: 0)
            XCTAssertEqual(project.clips[0].startFrame, 60)
            XCTAssertEqual(project.clips[0].inFrame, original.clips[0].inFrame)
            XCTAssertEqual(project.clips[0].outFrame, original.clips[0].outFrame)
            controller.end(id)
            withExtendedLifetime(scroll) {}
        }
    }
}
