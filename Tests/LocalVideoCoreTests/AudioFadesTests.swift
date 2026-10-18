// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import XCTest
@testable import LocalVideoCore

final class AudioFadesTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-fades-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture() throws -> VideoProject {
        let video = directory.appendingPathComponent("blue.mp4"), audio = directory.appendingPathComponent("tone.m4a")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-f","lavfi","-i","color=blue:s=160x90:r=30:d=4","-c:v","libx264","-pix_fmt","yuv420p",video.path])
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-f","lavfi","-i","sine=frequency=440:sample_rate=48000:duration=4","-c:a","aac",audio.path])
        var project = VideoProject(); project.width = 160; project.height = 90
        project.assets = [try MediaProbe.read(video),try MediaProbe.read(audio)]
        try project.append(project.assets[0].id)
        project.audioClips = [AudioClip(assetID: project.assets[1].id,inFrame: 6,outFrame: 96,startFrame: 15,volume: 0.8,fadeInFrames: 30,fadeOutFrames: 30)]
        return project
    }
    private func samples(_ url: URL) throws -> [Float] {
        let data = try MediaJob().run(MediaTools.find("ffmpeg"),["-v","error","-i",url.path,"-f","f32le","-ac","1","-ar","48000","pipe:1"])
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    private func rms(_ values: [Float], at seconds: Double) -> Double {
        let a = Int(seconds * 48000), b = min(values.count, a + 2400)
        guard a >= 0, b > a else { return 0 }
        return sqrt(values[a..<b].reduce(0.0) { $0 + Double($1 * $1) } / Double(b - a))
    }
    private func render(_ project: VideoProject) async throws -> ([Float],[Float]) {
        let preview = try await TimelinePreview.build(project)
        let live = directory.appendingPathComponent(UUID().uuidString + ".m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: preview.composition,presetName: AVAssetExportPresetAppleM4A))
        exporter.audioMix = preview.audioMix; exporter.outputURL = live; exporter.outputFileType = .m4a
        await exporter.export(); XCTAssertEqual(exporter.status,.completed,"\(String(describing: exporter.error))")
        let output = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try VideoRenderer.render(project,to: output,job: MediaJob())
        return (try samples(live),try samples(output))
    }
    func testFadeMigrationValidationSplitContinuityAndSave() throws {
        var project = try fixture()
        let original = project.audioClips[0]
        let file = directory.appendingPathComponent("fades.localvideo")
        try ProjectFile.save(project,to: file); XCTAssertEqual(try ProjectFile.load(file),project)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        json["version"] = 6
        json["audioClips"] = (json["audioClips"] as! [[String: Any]]).map { entry -> [String: Any] in
            var entry = entry; entry.removeValue(forKey: "fadeInFrames"); entry.removeValue(forKey: "fadeOutFrames"); return entry
        }
        let old = try JSONDecoder().decode(VideoProject.self,from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.version,7); XCTAssertEqual(old.audioClips[0].fadeInFrames,0); XCTAssertEqual(old.audioClips[0].fadeOutFrames,0)
        for bad in [Int64(-1),91,Int64.max] {
            var invalid = project; invalid.audioClips[0].fadeInFrames = bad; XCTAssertThrowsError(try invalid.validate())
        }
        var invalid = project; invalid.audioClips[0].fadeOutFrames = 61; XCTAssertThrowsError(try invalid.validate())
        invalid = project; invalid.audioClips[0].fadeSourceInFrame = 7; XCTAssertThrowsError(try invalid.validate())
        try project.splitAudio(original.id,at: 9)
        try project.splitAudio(project.audioClips[1].id,at: 66)
        try project.validate()
        for child in project.audioClips {
            for frame in 0...child.frames {
                XCTAssertEqual(child.fadeGain(at: Double(frame)),original.fadeGain(at: Double(child.inFrame - original.inFrame + frame)),accuracy: 1e-12)
            }
        }
        XCTAssertEqual(project.audioClips.map(\.frames),[9,66,15])
        XCTAssertEqual(project.audioClips.map(\.volume),[0.8,0.8,0.8])
        try ProjectFile.save(project,to: file); XCTAssertEqual(try ProjectFile.load(file),project)
        var reset = project.audioClips[1]; try reset.setFades(fadeIn: 0,fadeOut: 0)
        XCTAssertNil(reset.fadeSourceInFrame); XCTAssertEqual(reset.fadeGain(at: 0),1)
    }
    func testFadePlaybackExportAndSplitHaveMatchingEnvelope() async throws {
        var project = try fixture()
        let (live,export) = try await render(project)
        // Nonzero placement and source trim: the fade follows timeline clip time, not source zero.
        for time in [0.1,0.5,0.65,0.95,1.45,1.8,2.6,3.2,3.45,3.7] {
            XCTAssertEqual(rms(live,at: time),rms(export,at: time),accuracy: 0.004,"Mismatch at \(time)")
        }
        let plateau = rms(export,at: 1.8)
        XCTAssertGreaterThan(plateau,0.04)
        XCTAssertEqual(rms(export,at: 0.65) / plateau,0.175,accuracy: 0.035)
        XCTAssertEqual(rms(export,at: 3.2) / plateau,0.275,accuracy: 0.035)
        XCTAssertLessThan(rms(export,at: 0.1),0.0001); XCTAssertLessThan(rms(export,at: 3.7),0.0001)
        try project.splitAudio(project.audioClips[0].id,at: 9)
        try project.splitAudio(project.audioClips[1].id,at: 66)
        let (splitLive,splitExport) = try await render(project)
        for time in [0.65,0.78,0.81,1.8,2.95,3.0,3.2,3.45] {
            XCTAssertEqual(rms(splitLive,at: time),rms(live,at: time),accuracy: 0.004)
            XCTAssertEqual(rms(splitExport,at: time),rms(export,at: time),accuracy: 0.004)
        }
        project.audioClips = project.audioClips.map { clip in var clip = clip; clip.muted = true; return clip }
        let (mutedLive,mutedExport) = try await render(project)
        XCTAssertLessThan(rms(mutedLive,at: 1.8),0.0001); XCTAssertLessThan(rms(mutedExport,at: 1.8),0.0001)
    }
    func testTouchingFadesDelayedSourceAndTwoLaneMix() async throws {
        var project = try fixture()
        let delayed = directory.appendingPathComponent("delayed.mov")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"),["-v","error","-f","lavfi","-i","color=black:s=160x90:r=30:d=4","-itsoffset","0.4","-f","lavfi","-i","sine=frequency=880:duration=3:sample_rate=48000","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac",delayed.path])
        project.assets.append(try MediaProbe.read(delayed))
        project.audioClips[0].fadeInFrames = 45; project.audioClips[0].fadeOutFrames = 45
        project.audioClips.append(AudioClip(assetID: project.assets[2].id,inFrame: 3,outFrame: 93,startFrame: 30,lane: 1,volume: 0.5,fadeInFrames: 30,fadeOutFrames: 15))
        let (live,export) = try await render(project)
        for time in [0.55,1.05,1.2,1.45,1.9,2.5,3.3,3.8] {
            XCTAssertEqual(rms(live,at: time),rms(export,at: time),accuracy: 0.005,"Delayed mixed audio at \(time)")
        }
    }
}
