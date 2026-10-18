// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation
import XCTest
@testable import LocalVideoCore

final class ProjectRecoveryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-Recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func project() throws -> VideoProject {
        var project = VideoProject()
        project.name = "Recover this edit"
        project.assets = [MediaAsset(path: directory.appendingPathComponent("missing source.mov").path, duration: 5, width: 320, height: 180)]
        try project.append(project.assets[0].id)
        return project
    }

    func testUnexpectedExitRestoresLatestEditWithoutChangingSavedFile() throws {
        let saved = directory.appendingPathComponent("original.localvideo")
        var edit = try project()
        try ProjectFile.save(edit, to: saved)
        let original = try Data(contentsOf: saved)
        var session: ProjectRecovery? = try ProjectRecovery(directory: directory)
        try session!.write(RecoverySnapshot(project: edit, originalFileURL: saved))
        edit.clips[0].opacity = 0.4
        try edit.split(edit.clips[0].id, at: 30)
        try session!.write(RecoverySnapshot(project: edit, originalFileURL: saved))
        session = nil // Releasing the process lease models an unexpected exit.
        let next = try ProjectRecovery(directory: directory)
        let candidate = try XCTUnwrap(next.scan().candidates.first)
        XCTAssertEqual(candidate.snapshot.project, edit)
        XCTAssertEqual(candidate.snapshot.originalFileURL, saved)
        XCTAssertEqual(try Data(contentsOf: saved), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathExtension("backup").path))
        // A recovered edit can itself survive another unexpected exit.
        try next.write(candidate.snapshot)
        try next.discard(candidate)
        XCTAssertEqual(try Data(contentsOf: saved), original)
        let observer = try ProjectRecovery(directory: directory)
        XCTAssertTrue(try observer.scan().candidates.isEmpty)
    }

    func testActiveEditorsAndClaimedCopiesAreNotOfferedTwice() throws {
        var first: ProjectRecovery? = try ProjectRecovery(directory: directory)
        try first!.write(RecoverySnapshot(project: project(), originalFileURL: nil))
        let second = try ProjectRecovery(directory: directory)
        XCTAssertTrue(try second.scan().candidates.isEmpty)
        first = nil
        var candidates = try second.scan().candidates
        XCTAssertEqual(candidates.count, 1)
        let third = try ProjectRecovery(directory: directory)
        XCTAssertTrue(try third.scan().candidates.isEmpty)
        candidates.removeAll() // Not Now: retain bytes, release the lease.
        XCTAssertEqual(try third.scan().candidates.count, 1)
    }

    func testSaveOrDiscardRemovesOnlyTheCurrentWorkingCopy() throws {
        let otherID = UUID()
        let other = directory.appendingPathComponent(otherID.uuidString + ".recovery")
        let snapshot = RecoverySnapshot(project: try project(), originalFileURL: nil)
        try JSONEncoder().encode(snapshot).write(to: other)
        var session: ProjectRecovery? = try ProjectRecovery(directory: directory)
        try session!.write(snapshot)
        try session!.clear()
        try session!.clear()
        session = nil
        let next = try ProjectRecovery(directory: directory)
        let candidate = try XCTUnwrap(next.scan().candidates.first)
        XCTAssertEqual(candidate.id, otherID)
        try next.discard(candidate)
        XCTAssertTrue(try next.scan().candidates.isEmpty)
    }

    func testUnreadableCopyDoesNotHideOlderValidEditOrDeleteEvidence() throws {
        var older: ProjectRecovery? = try ProjectRecovery(directory: directory)
        let snapshot = RecoverySnapshot(project: try project(), originalFileURL: nil, updatedAt: Date(timeIntervalSince1970: 100))
        try older!.write(snapshot); older = nil
        let invalid = directory.appendingPathComponent(UUID().uuidString + ".recovery")
        let bytes = Data("interrupted or unsupported data".utf8)
        try bytes.write(to: invalid)
        let next = try ProjectRecovery(directory: directory)
        let scan = try next.scan()
        XCTAssertEqual(scan.unreadableCount, 1)
        XCTAssertEqual(scan.candidates.map(\.snapshot), [snapshot])
        XCTAssertEqual(try Data(contentsOf: invalid), bytes)
    }

    func testInvalidEditCannotReplaceGoodRecoveryAndPathsStayAbsolute() throws {
        var session: ProjectRecovery? = try ProjectRecovery(directory: directory)
        let valid = RecoverySnapshot(project: try project(), originalFileURL: directory.appendingPathComponent("edit.localvideo"))
        try session!.write(valid)
        var bad = valid
        bad.project.clips[0].outFrame = 999
        XCTAssertThrowsError(try session!.write(bad))
        bad = valid; bad.project.assets[0].path = "relative.mov"
        XCTAssertThrowsError(try session!.write(bad))
        session = nil
        let next = try ProjectRecovery(directory: directory)
        XCTAssertEqual(try next.scan().candidates.first?.snapshot, valid)
    }

    func testStorageFailurePreservesThePreviousRecoveryCopy() throws {
        let folder = directory.appendingPathComponent("working")
        let parked = directory.appendingPathComponent("retained")
        var session: ProjectRecovery? = try ProjectRecovery(directory: folder)
        let snapshot = RecoverySnapshot(project: try project(), originalFileURL: nil)
        try session!.write(snapshot)
        try FileManager.default.moveItem(at: folder, to: parked)
        try Data("unavailable folder".utf8).write(to: folder)
        XCTAssertThrowsError(try session!.write(snapshot))
        XCTAssertThrowsError(try ProjectRecovery(directory: folder))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: parked, to: folder)
        session = nil
        let next = try ProjectRecovery(directory: folder)
        XCTAssertEqual(try next.scan().candidates.first?.snapshot, snapshot)
    }

    func testCopiesAreNewestFirstAndPrivateToTheCurrentUser() throws {
        for time in [10.0, 30.0, 20.0] {
            let session = try ProjectRecovery(directory: directory)
            try session.write(RecoverySnapshot(project: project(), originalFileURL: nil, updatedAt: Date(timeIntervalSince1970: time)))
        }
        let next = try ProjectRecovery(directory: directory)
        let scan = try next.scan()
        XCTAssertEqual(scan.candidates.map { $0.snapshot.updatedAt.timeIntervalSince1970 }, [30, 20, 10])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "recovery" {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
}
