// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import XCTest
@testable import LocalVideoCore

final class DirectorPlanTests: XCTestCase {
    private func fixture() -> VideoProject {
        var project = VideoProject()
        project.assets = [MediaAsset(path: "synthetic.mov", duration: 10, width: 1280, height: 720, audioStream: 1),
                          MediaAsset(path: "synthetic.wav", duration: 20, width: 0, height: 0, videoStream: -1, audioStream: 0)]
        return project
    }
    private func decode(_ value: String) throws -> DirectorPlan { try DirectorPlan.decode(Data(value.utf8)) }

    func testCompleteDraftIncludesTitleDissolveAndMusic() throws {
        let project = fixture(), first = UUID(), second = UUID(), music = UUID(), titleID = UUID()
        var title = TextTitle(style: .statement); title.text = "A new beginning"
        let plan = DirectorPlan(summary: "A clean opening with soft cuts and music", operations: [
            DirectorOperation(action: .renameProject, name: "First draft"),
            DirectorOperation(action: .setCanvas, width: 1920, height: 1080),
            DirectorOperation(action: .addVisual, clipID: first, assetID: project.assets[0].id, inFrame: 0, outFrame: 90, startFrame: 0),
            DirectorOperation(action: .addVisual, clipID: second, assetID: project.assets[0].id, inFrame: 90, outFrame: 180, startFrame: 90),
            DirectorOperation(action: .setDissolve, clipID: second, dissolveFrames: 15),
            DirectorOperation(action: .setVisualFades, clipID: first, fadeInFrames: 15),
            DirectorOperation(action: .addTitle, clipID: titleID, outFrame: 60, startFrame: 15, title: title),
            DirectorOperation(action: .setVisualFades, clipID: titleID, fadeInFrames: 8, fadeOutFrames: 8),
            DirectorOperation(action: .addAudio, clipID: music, assetID: project.assets[1].id, outFrame: 165, volume: 0.25),
            DirectorOperation(action: .setAudioFades, clipID: music, fadeInFrames: 15, fadeOutFrames: 30)
        ])
        let decoded = try DirectorPlan.decode(JSONEncoder().encode(plan))
        XCTAssertEqual(plan, decoded)
        let draft = try decoded.applying(to: project)
        XCTAssertEqual(draft.name, "First draft"); XCTAssertEqual(draft.width, 1920)
        XCTAssertEqual(draft.version, project.version); XCTAssertTrue(project.clips.isEmpty)
        XCTAssertEqual(draft.clips[1].startFrame, 75); XCTAssertEqual(draft.clips[1].dissolveFrom, first)
        XCTAssertEqual(draft.totalFrames, 165); XCTAssertEqual(draft.clips[2].lane, 1)
        XCTAssertEqual(try draft.asset(for: draft.clips[2]).title, title)
        XCTAssertEqual(draft.audioClips.first?.volume, 0.25)
        XCTAssertEqual(draft.audioClips.first?.fadeOutFrames, 30)
        try draft.validate()
        let defaultTitle = try DirectorPlan(operations: [DirectorOperation(action: .addTitle, title: title)]).applying(to: project)
        XCTAssertEqual(defaultTitle.clips[0].frames, 150); XCTAssertEqual(defaultTitle.clips[0].startFrame, 0)
        XCTAssertEqual(defaultTitle.clips[0].lane, 0)
        let overlay = try DirectorPlan(operations: [DirectorOperation(action: .addTitle, title: title)]).applying(to: draft)
        XCTAssertEqual(overlay.clips.last?.frames, 150); XCTAssertEqual(overlay.clips.last?.lane, 2)
    }

    func testAtomicFailurePreservesInput() throws {
        var project = fixture(); try project.append(project.assets[0].id)
        let original = project
        XCTAssertNil(project.clips[0].startFrame)
        XCTAssertEqual(try DirectorPlan(summary: "Which style would you like?").applying(to: project), original)
        XCTAssertEqual(try DirectorPlan(operations: [DirectorOperation(action: .renameProject, name: project.name)]).applying(to: project), original)
        XCTAssertEqual(try DirectorPlan(operations: [DirectorOperation(action: .setVisual, clipID: project.clips[0].id, opacity: project.clips[0].opacity)]).applying(to: project), original)
        XCTAssertEqual(try DirectorPlan(operations: [DirectorOperation(action: .setVisual, clipID: project.clips[0].id, inFrame: 0, outFrame: 300, startFrame: 0, lane: 0)]).applying(to: project), original)
        let plan = DirectorPlan(operations: [DirectorOperation(action: .renameProject, name: "Changed"),
                                             DirectorOperation(action: .setVisual, clipID: project.clips[0].id, outFrame: 301)])
        XCTAssertThrowsError(try plan.applying(to: project))
        XCTAssertEqual(project, original)
    }

    func testBatchReorderingAllowsTemporaryOverlapForVideoAndAudio() throws {
        var project = fixture(); let asset = project.assets[0].id
        project.clips = [Clip(assetID: asset, inFrame: 0, outFrame: 60, startFrame: 0),
                         Clip(assetID: asset, inFrame: 60, outFrame: 120, startFrame: 60)]
        project.audioClips = [AudioClip(assetID: asset, inFrame: 0, outFrame: 60),
                              AudioClip(assetID: asset, inFrame: 60, outFrame: 120, startFrame: 60)]
        let plan = DirectorPlan(operations: [
            DirectorOperation(action: .setVisual, clipID: project.clips[0].id, startFrame: 60),
            DirectorOperation(action: .setVisual, clipID: project.clips[1].id, startFrame: 0),
            DirectorOperation(action: .setAudio, clipID: project.audioClips[0].id, startFrame: 60),
            DirectorOperation(action: .setAudio, clipID: project.audioClips[1].id, startFrame: 0)
        ])
        let result = try plan.applying(to: project)
        XCTAssertEqual(result.clips.map(\.startFrame), [60, 0])
        XCTAssertEqual(result.audioClips.map(\.startFrame), [60, 0])
    }

    func testStrictJSONRejectsUnknownFieldsActionsAndMalformedStructure() throws {
        let examples = [
            "{\"version\":2,\"summary\":\"\",\"operations\":[]}",
            "{\"version\":1,\"summary\":\"\",\"operations\":[],\"shell\":\"anything\"}",
            "{\"version\":1,\"summary\":\"\",\"operations\":[{\"action\":\"export\"}]}",
            "{\"version\":1,\"summary\":\"\",\"operations\":[{\"action\":\"rename_project\",\"name\":\"x\",\"path\":\"a\"}]}",
            "{\"version\":1,\"summary\":\"\",\"operations\":[{\"action\":\"rename_project\",\"name\":\"x\",\"opacity\":0.5}]}",
            "{\"version\":1,\"summary\":\"\",\"operations\":[{\"action\":\"set_visual\",\"transform\":{\"x\":0,\"y\":0,\"scale\":1,\"rotation\":0,\"script\":\"x\"}}]}",
            "{\"version\":1,\"summary\":\"\",\"operations\":[{\"action\":\"add_title\",\"title\":{\"text\":\"x\",\"style\":\"simple\",\"size\":0.09,\"color\":\"white\",\"alignment\":\"center\",\"fontPath\":\"x\"}}]}",
            "{\"version\":1,\"summary\":\"\",\"operations\":[{\"action\":\"set_canvas\",\"width\":1280}]}",
            "{\"version\":1,\"summary\":\"\",\"operations\":null}", "[]", "not json"
        ]
        for example in examples { XCTAssertThrowsError(try decode(example), example) }
    }

    func testLimitsAndInvalidNumbersDoNotReachArithmetic() throws {
        let project = fixture()
        let cases = [DirectorOperation(action: .addVisual, assetID: project.assets[0].id, inFrame: Int64.min, outFrame: Int64.max),
                     DirectorOperation(action: .addVisual, assetID: project.assets[0].id, lane: Int.max),
                     DirectorOperation(action: .setCanvas, width: Int.max, height: 720),
                     DirectorOperation(action: .addAudio, assetID: project.assets[1].id, lane: 2),
                     DirectorOperation(action: .addVisual, assetID: project.assets[0].id, opacity: .nan),
                     DirectorOperation(action: .addVisual, assetID: project.assets[0].id, transform: VisualTransform(scale: .infinity)),
                     DirectorOperation(action: .addVisual, assetID: project.assets[0].id, inFrame: 30, outFrame: 29)]
        for operation in cases { XCTAssertThrowsError(try DirectorPlan(operations: [operation]).applying(to: project)) }
        XCTAssertThrowsError(try DirectorPlan(operations: Array(repeating: DirectorOperation(action: .renameProject, name: "x"), count: 65)).applying(to: project))
        XCTAssertThrowsError(try DirectorPlan(summary: String(repeating: "x", count: 2001)).applying(to: project))
        XCTAssertThrowsError(try DirectorPlan.decode(Data(repeating: 32, count: 262_145)))
    }

    func testMissingReferencesDuplicateIDsAndRequiredFieldsFail() throws {
        var project = fixture(); try project.append(project.assets[0].id)
        let cases = [DirectorOperation(action: .removeVisual, clipID: UUID()),
                     DirectorOperation(action: .splitVisual, clipID: UUID(), inFrame: 20),
                     DirectorOperation(action: .setAudio, clipID: UUID(), volume: 0.5),
                     DirectorOperation(action: .addVisual, assetID: UUID()),
                     DirectorOperation(action: .addVisual, clipID: project.clips[0].id, assetID: project.assets[0].id),
                     DirectorOperation(action: .addTitle), DirectorOperation(action: .setCanvas, width: 1280),
                     DirectorOperation(action: .addAudio, assetID: project.assets[0].id, outFrame: 301)]
        for operation in cases { XCTAssertThrowsError(try DirectorPlan(operations: [operation]).applying(to: project)) }
    }

    func testSplitUsesLocalOffsetPreservesFadeAndProjectFormat() throws {
        var project = fixture()
        var clip = Clip(assetID: project.assets[0].id, inFrame: 60, outFrame: 180, startFrame: 30)
        try clip.setVisualFades(fadeIn: 90, fadeOut: 30); project.clips = [clip]
        let result = try DirectorPlan(operations: [DirectorOperation(action: .splitVisual, clipID: clip.id, inFrame: 45)]).applying(to: project)
        XCTAssertEqual(result.clips.map(\.inFrame), [60, 105]); XCTAssertEqual(result.clips.map(\.outFrame), [105, 180])
        XCTAssertEqual(result.clips.map(\.startFrame), [30, 75]); XCTAssertNotEqual(result.clips[0].id, result.clips[1].id)
        XCTAssertEqual(result.clips[1].fadeGain(at: 0), clip.fadeGain(at: 45), accuracy: 0.00001)
        XCTAssertEqual(result.version, project.version)
        let reopened = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(result, reopened)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        legacy["version"] = 8
        let migrated = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        let edited = try DirectorPlan(operations: [DirectorOperation(action: .renameProject, name: "Migrated draft")]).applying(to: migrated)
        XCTAssertEqual(edited.version, migrated.version)
        XCTAssertEqual(edited.clips[0].assetID, migrated.clips[0].assetID)
    }

    func testTitleUpdateIsIndependentAndRemoveActionsWork() throws {
        var project = fixture(); let id = try project.addTitle(TextTitle(), at: 0)
        var copy = project.clips[0]; copy.id = UUID(); copy.startFrame = 150; project.clips.append(copy)
        var title = TextTitle(style: .caption); title.text = "Independent"
        let audioID = UUID()
        let result = try DirectorPlan(operations: [DirectorOperation(action: .updateTitle, clipID: id, title: title),
                                                   DirectorOperation(action: .addAudio, clipID: audioID, assetID: project.assets[1].id, outFrame: 60),
                                                   DirectorOperation(action: .removeAudio, clipID: audioID),
                                                   DirectorOperation(action: .removeVisual, clipID: copy.id)]).applying(to: project)
        XCTAssertEqual(try result.asset(for: result.clips[0]).title, title)
        XCTAssertEqual(try project.asset(for: copy).title?.text, "Your title")
        XCTAssertTrue(result.audioClips.isEmpty); XCTAssertEqual(result.clips.count, 1)
        XCTAssertEqual(result.assets.count, project.assets.count + 1)
    }

    func testTrimsFitFadesAndOrdinaryEditsPreserveThem() throws {
        var project = fixture(); try project.append(project.assets[0].id)
        try project.clips[0].setVisualFades(fadeIn: 90, fadeOut: 90)
        project.audioClips = [AudioClip(assetID: project.assets[1].id, inFrame: 0, outFrame: 300, fadeInFrames: 90, fadeOutFrames: 90)]
        let kept = try DirectorPlan(operations: [DirectorOperation(action: .setVisual, clipID: project.clips[0].id, opacity: 0.8)]).applying(to: project)
        XCTAssertEqual(kept.clips[0].fadeOutFrames, 90)
        let trimmed = try DirectorPlan(operations: [DirectorOperation(action: .setVisual, clipID: project.clips[0].id, outFrame: 120),
                                                    DirectorOperation(action: .setAudio, clipID: project.audioClips[0].id, outFrame: 120)]).applying(to: project)
        XCTAssertEqual(trimmed.clips[0].fadeInFrames, 90); XCTAssertEqual(trimmed.clips[0].fadeOutFrames, 30)
        XCTAssertEqual(trimmed.audioClips[0].fadeInFrames, 90); XCTAssertEqual(trimmed.audioClips[0].fadeOutFrames, 30)
    }
}
