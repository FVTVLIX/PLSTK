// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import XCTest
@testable import LocalVideoCore

final class DirectorContextTests: XCTestCase {
    func testSnapshotRemovesPathsAndHasStableRevisionAndSelection() throws {
        var p = VideoProject()
        p.assets = [MediaAsset(path: "/private/footage/launch.mp4", duration: 4, width: 320, height: 180, audioStream: 1)]
        try p.append(p.assets[0].id)
        let revision = try DirectorContext.revision(p)
        let json = try DirectorContext.snapshot(p, selectedClip: p.clips[0].id, playhead: 30)
        XCTAssertFalse(json.contains("/private/footage")); XCTAssertFalse(json.contains("\"path\""))
        XCTAssertTrue(json.contains("launch.mp4")); XCTAssertTrue(json.contains(revision))
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(value["selectedClipID"] as? String,p.clips[0].id.uuidString)
        XCTAssertEqual(value["playheadFrame"] as? Int,30)
        XCTAssertEqual(try DirectorContext.revision(p),revision)
        p.clips[0].muted = true; XCTAssertNotEqual(try DirectorContext.revision(p),revision)
    }
    func testWarningsDistinguishGapsAndIntendedLayering() throws {
        var p = VideoProject()
        let first = try p.addTitle(TextTitle(), at: 0)
        XCTAssertTrue(DirectorContext.warnings(p).isEmpty)
        try p.placeVisual(first,at:30,lane:0)
        XCTAssertEqual(DirectorContext.warnings(p).count,1)
        p.clips[0].opacity = 0
        XCTAssertEqual(DirectorContext.warnings(p).count,2)
        p.clips.removeAll(); XCTAssertEqual(DirectorContext.warnings(p).count,1)
    }
    func testOriginalStyleInstructionsStateCapabilityLimitsAndContract() {
        for look in DirectorLook.allCases {
            XCTAssertTrue(look.instructions.contains(DirectorPlan.contract))
            XCTAssertTrue(look.instructions.contains("untrusted"))
            XCTAssertTrue(look.instructions.contains("sparse samples"))
        }
    }
}
