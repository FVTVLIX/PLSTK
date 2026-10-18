// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation
import XCTest
@testable import LocalVideoCore

final class ProjectTests: XCTestCase {
    func sample() throws -> VideoProject {
        var project = VideoProject()
        project.assets = [MediaAsset(path: "/tmp/source.mov", duration: 10.01, width: 1920, height: 1080)]
        try project.append(project.assets[0].id)
        return project
    }
    func testSplitPreservesSourceRangeAndTotalDuration() throws {
        var project = try sample()
        project.clips[0].inFrame = 30
        project.clips[0].outFrame = 180
        let id = project.clips[0].id, duration = project.duration
        try project.split(id, at: 45)
        try project.validate()
        XCTAssertEqual(project.clips.map(\.inFrame), [30, 75])
        XCTAssertEqual(project.clips.map(\.outFrame), [75, 180])
        XCTAssertEqual(project.duration, duration)
        XCTAssertEqual(project.clips[0].id, id)
        XCTAssertNotEqual(project.clips[1].id, id)
    }
    func testRejectsOutOfBoundsAndUnsupportedSchema() throws {
        var project = try sample()
        project.clips[0].outFrame = 301
        XCTAssertThrowsError(try project.validate())
        project.clips[0].outFrame = 300
        project.clips[0].inFrame = 300
        XCTAssertThrowsError(try project.validate())
        project.clips[0].inFrame = 0
        project.version = 99
        XCTAssertThrowsError(try project.validate())
    }
    func testSaveReloadRelativeAssetsAndBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("edit.localvideo")
        var project = try sample()
        project.assets[0].path = directory.appendingPathComponent("media/source.mov").path
        try ProjectFile.save(project, to: url)
        XCTAssertEqual(try ProjectFile.load(url), project)
        let stored = try JSONDecoder().decode(VideoProject.self, from: Data(contentsOf: url))
        XCTAssertEqual(stored.assets[0].path, "media/source.mov")
        let original = try Data(contentsOf: url)
        project.name = "Changed"
        try ProjectFile.save(project, to: url)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("backup")), original)
    }
    func testCancelledBeforeLaunchDoesNotRunProcess() throws {
        let job = MediaJob(); job.cancel()
        XCTAssertThrowsError(try job.run(URL(fileURLWithPath: "/usr/bin/true"), [])) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
    func testFailedWorkerPreservesExistingExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("invalid.mov")
        let target = directory.appendingPathComponent("out.mp4")
        try Data("not a movie".utf8).write(to: source)
        let original = Data("previous export".utf8)
        try original.write(to: target)
        var project = try sample(); project.assets[0].path = source.path
        XCTAssertThrowsError(try VideoRenderer.render(project, to: target, job: MediaJob()))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["invalid.mov", "out.mp4"])
    }
    func testRenderRejectsSourceOverwrite() throws {
        var project = try sample()
        project.assets[0].path = "/tmp/missing-input.mp4"
        XCTAssertThrowsError(try VideoRenderer.render(project, to: URL(fileURLWithPath: project.assets[0].path), job: MediaJob()))
    }
}
