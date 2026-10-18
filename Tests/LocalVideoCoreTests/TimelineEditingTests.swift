// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import XCTest
@testable import LocalVideoCore

final class TimelineEditingTests: XCTestCase {
    private func project() throws -> VideoProject {
        var project = VideoProject()
        project.assets = [MediaAsset(path: "/tmp/first.mp4", duration: 10, width: 320, height: 180)]
        project.clips = [Clip(assetID: project.assets[0].id, inFrame: 30, outFrame: 90),
                         Clip(assetID: project.assets[0].id, inFrame: 120, outFrame: 150),
                         Clip(assetID: project.assets[0].id, inFrame: 180, outFrame: 270)]
        try project.validate()
        return project
    }
    func testRippleTrimsClampToSourceAndKeepOneFrame() throws {
        var project = try project()
        let id = project.clips[0].id, neighbors = Array(project.clips.dropFirst())
        try project.rippleTrim(id, edge: .start, delta: .max)
        XCTAssertEqual(project.clips[0].inFrame, 89)
        XCTAssertEqual(project.clips[0].frames, 1)
        try project.rippleTrim(id, edge: .start, delta: .min)
        XCTAssertEqual(project.clips[0].inFrame, 0)
        try project.rippleTrim(id, edge: .end, delta: .max)
        XCTAssertEqual(project.clips[0].outFrame, 300)
        try project.rippleTrim(id, edge: .end, delta: .min)
        XCTAssertEqual(project.clips[0].outFrame, 1)
        XCTAssertEqual(project.clips[0].id, id)
        XCTAssertEqual(Array(project.clips.dropFirst()), neighbors)
        try project.validate()
    }
    func testTrimDraftLeavesProjectUnchangedAndCommitHasExpectedDuration() throws {
        var project = try project()
        let original = project
        let id = project.clips[0].id
        let candidate = try project.trimmedClip(id, edge: .start, delta: 15)
        XCTAssertEqual(candidate.inFrame, 45)
        XCTAssertEqual(project, original)
        try project.rippleTrim(id, edge: .start, delta: 15)
        XCTAssertEqual(project.duration, original.duration - 0.5, accuracy: 0.00001)
        XCTAssertEqual(project.clips[0].assetID, original.clips[0].assetID)
        try project.validate()
    }
    func testReorderKeepsIDsAndSourceRangesInBothDirections() throws {
        var project = try project()
        let original = project.clips
        try project.moveClip(original[0].id, to: 2)
        XCTAssertEqual(project.clips, [original[1], original[2], original[0]])
        try project.moveClip(original[0].id, to: 0)
        XCTAssertEqual(project.clips, original)
        try project.moveClip(original[1].id, to: 1)
        XCTAssertEqual(project.clips, original)
        XCTAssertThrowsError(try project.moveClip(original[0].id, to: 3))
        XCTAssertThrowsError(try project.moveClip(UUID(), to: 0))
        XCTAssertEqual(project.clips, original)
    }
    func testInsertionUsesOtherClipMidpointsAndSupportsBothEnds() throws {
        let project = try project()
        let first = project.clips[0].id, last = project.clips[2].id
        // Midpoints at 30, 75 and 135 frames; the dragged clip is excluded.
        XCTAssertEqual(project.insertionIndex(moving: first, atFrame: -100), 0)
        XCTAssertEqual(project.insertionIndex(moving: first, atFrame: 74), 0)
        XCTAssertEqual(project.insertionIndex(moving: first, atFrame: 75), 1)
        XCTAssertEqual(project.insertionIndex(moving: first, atFrame: 1000), 2)
        XCTAssertEqual(project.insertionIndex(moving: last, atFrame: 29), 0)
        XCTAssertEqual(project.insertionIndex(moving: last, atFrame: 30), 1)
        XCTAssertEqual(project.insertionIndex(moving: last, atFrame: 1000), 2)
        XCTAssertNil(project.insertionIndex(moving: first, atFrame: .nan))
        XCTAssertNil(project.insertionIndex(moving: UUID(), atFrame: 0))
    }
    func testMagneticSnappingRespectsToleranceAndClosestBoundary() {
        XCTAssertEqual(TimelineSnapping.nearestFrame(98, candidates: [0, 90, 100], tolerance: 3), 100)
        XCTAssertEqual(TimelineSnapping.nearestFrame(95, candidates: [0, 100], tolerance: 3), 95)
        XCTAssertEqual(TimelineSnapping.nearestFrame(10, candidates: [], tolerance: 4), 10)
    }
    func testSnappingRoundsPositiveAndNegativeDragToFrames() {
        XCTAssertEqual(TimelineSnapping.frameDelta(points: 5, pointsPerSecond: 100), 2)
        XCTAssertEqual(TimelineSnapping.frameDelta(points: -5, pointsPerSecond: 100), -2)
        XCTAssertEqual(TimelineSnapping.frameDelta(points: 1, pointsPerSecond: 100), 0)
        XCTAssertEqual(TimelineSnapping.frameDelta(points: .infinity, pointsPerSecond: 100), 0)
        XCTAssertEqual(TimelineSnapping.frameDelta(points: 10, pointsPerSecond: 0), 0)
    }
}
