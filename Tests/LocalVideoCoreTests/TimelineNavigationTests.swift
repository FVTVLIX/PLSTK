// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import XCTest
@testable import LocalVideoCore

final class TimelineNavigationTests: XCTestCase {
    func testEdgeSpeedIsDirectionalProgressiveAndQuietInTheCenter() {
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: 200, viewport: 400), 0)
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: 0, viewport: 400), -600)
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: 400, viewport: 400), 600)
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: 28, viewport: 400), -150)
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: 372, viewport: 400), 150)
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: -100, viewport: 400), 0)
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: 500, viewport: 400), 0)
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: 4, viewport: 8), 0)
    }
    func testScrollStepsClampBoundariesAndLongTimerGaps() {
        XCTAssertEqual(TimelineNavigation.scrollOffset(5, velocity: -600, elapsed: 1.0 / 60, maximum: 200), 0)
        XCTAssertEqual(TimelineNavigation.scrollOffset(195, velocity: 600, elapsed: 1.0 / 60, maximum: 200), 200)
        XCTAssertEqual(TimelineNavigation.scrollOffset(100, velocity: 600, elapsed: 5, maximum: 1000), 130)
        XCTAssertEqual(TimelineNavigation.scrollOffset(100, velocity: 600, elapsed: -1, maximum: 1000), 100)
        XCTAssertEqual(TimelineNavigation.edgeVelocity(pointer: .nan, viewport: 0), 0)
        XCTAssertEqual(TimelineNavigation.scrollOffset(.nan, velocity: 600, elapsed: 1, maximum: 1000), 0)
    }
    func testDragAccountsForScrollOnceAndStillSupportsSnappingAndTrimBounds() throws {
        let distance = TimelineNavigation.dragDistance(translation: 20, initialOffset: 300, currentOffset: 390)
        XCTAssertEqual(distance, 110)
        let delta = TimelineSnapping.frameDelta(points: distance, pointsPerSecond: 30)
        XCTAssertEqual(delta, 110)
        XCTAssertEqual(TimelineSnapping.nearestFrame(delta, candidates: [111, 180], tolerance: 6), 111)
        var project = VideoProject(); let id = try project.addTitle(TextTitle(), at: 0)
        let original = project
        let candidate = try project.trimmedClip(id, edge: .start, delta: delta)
        XCTAssertEqual(candidate.inFrame, 110); XCTAssertEqual(candidate.frames, 40)
        XCTAssertEqual(project, original)
        let backward = TimelineNavigation.dragDistance(translation: -20, initialOffset: 390, currentOffset: 300)
        XCTAssertEqual(backward, -110)
    }
}
