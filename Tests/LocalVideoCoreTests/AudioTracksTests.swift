// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import XCTest
@testable import LocalVideoCore

final class AudioTracksTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioTracks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func make(_ name: String, frequency: Int, video: Bool = false) throws -> MediaAsset {
        let url = directory.appendingPathComponent(name + (video ? ".mp4" : ".m4a"))
        var args = ["-v", "error"]
        if video { args += ["-f", "lavfi", "-i", "color=c=red:s=160x90:r=30:d=2"] }
        args += ["-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=2:sample_rate=48000"]
        if video { args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"] }
        args += ["-c:a", "aac", "-y", url.path]
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), args)
        return try MediaProbe.read(url)
    }
    func testVersionOneMigrationPreservesEditAndBackup() throws {
        var original = VideoProject()
        original.assets = [MediaAsset(path: "/tmp/legacy.mov", duration: 2, width: 160, height: 90)]
        try original.append(original.assets[0].id)
        var dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        dictionary["version"] = 1; dictionary.removeValue(forKey: "audioClips"); dictionary.removeValue(forKey: "videoVolume")
        let bytes = try JSONSerialization.data(withJSONObject: dictionary)
        let url = directory.appendingPathComponent("legacy.localvideo")
        try bytes.write(to: url)
        let migrated = try ProjectFile.load(url)
        XCTAssertEqual(migrated.version, 8); XCTAssertEqual(migrated.clips, original.clips)
        XCTAssertTrue(migrated.audioClips.isEmpty); XCTAssertEqual(migrated.videoVolume, 1)
        try ProjectFile.save(migrated, to: url)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("backup")), bytes)
        XCTAssertEqual(try ProjectFile.load(url), migrated)
    }
    func testAudioValidationPlacementAndRoundTrip() throws {
        var project = VideoProject(); project.assets = [try make("sound", frequency: 660)]
        XCTAssertTrue(project.assets[0].isAudioOnly)
        try project.appendAudio(project.assets[0].id, at: 30)
        try project.appendAudio(project.assets[0].id, at: 30)
        XCTAssertEqual(project.audioClips.map(\.lane), [0, 1])
        XCTAssertEqual(project.totalFrames, 90)
        project.audioClips[0].volume = 0.5; project.audioClips[0].muted = true
        let url = directory.appendingPathComponent("audio.localvideo")
        try ProjectFile.save(project, to: url)
        XCTAssertEqual(try ProjectFile.load(url), project)
        var invalid = project; invalid.audioClips[1].lane = 0
        XCTAssertThrowsError(try invalid.validate())
        invalid = project; invalid.audioClips[0].volume = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = project; invalid.audioClips[0].outFrame = 0
        XCTAssertThrowsError(try invalid.validate())
        invalid = project; invalid.audioClips[0].startFrame = -1
        XCTAssertThrowsError(try invalid.validate())
    }
    func testMuteIsSilentInPreviewAndExport() async throws {
        var project = VideoProject(); project.width = 160; project.height = 90
        project.assets = [try make("muted-video", frequency: 440, video: true), try make("muted-audio", frequency: 660)]
        try project.append(project.assets[0].id); try project.appendAudio(project.assets[1].id)
        project.videoVolume = 0; project.audioClips[0].volume = 0.5; project.audioClips[0].muted = true
        let preview = try await TimelinePreview.build(project)
        let output = directory.appendingPathComponent("muted-live.m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: preview.composition, presetName: AVAssetExportPresetAppleM4A))
        exporter.audioMix = preview.audioMix; exporter.outputURL = output; exporter.outputFileType = .m4a
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed)
        let reference = directory.appendingPathComponent("muted-export.mp4")
        try VideoRenderer.render(project, to: reference, job: MediaJob())
        XCTAssertLessThan(rms(try samples(output), at: 0.5), 0.0001)
        XCTAssertLessThan(rms(try samples(reference), at: 0.5), 0.0001)
    }
    func testSelectedVideoMuteDoesNotSilenceNeighbor() async throws {
        var project = VideoProject(); project.width = 160; project.height = 90
        project.assets = [try make("selected", frequency: 440, video: true)]
        let id = project.assets[0].id
        project.clips = [Clip(assetID: id, inFrame: 0, outFrame: 30, muted: true), Clip(assetID: id, inFrame: 30, outFrame: 60)]
        let preview = try await TimelinePreview.build(project)
        let live = directory.appendingPathComponent("selected.m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: preview.composition, presetName: AVAssetExportPresetAppleM4A))
        exporter.audioMix = preview.audioMix; exporter.outputURL = live; exporter.outputFileType = .m4a
        await exporter.export(); XCTAssertEqual(exporter.status, .completed)
        let output = directory.appendingPathComponent("selected-export.mp4")
        try VideoRenderer.render(project, to: output, job: MediaJob())
        for url in [live, output] {
            let decoded = try samples(url)
            XCTAssertLessThan(rms(decoded, at: 0.3), 0.0001)
            XCTAssertGreaterThan(rms(decoded, at: 1.3), 0.03)
        }
        let roundTrip = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(roundTrip.clips.map(\.muted), [true, false])
    }
    private func samples(_ url: URL) throws -> [Float] {
        let data = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-i", url.path, "-f", "f32le", "-ac", "1", "-ar", "48000", "pipe:1"])
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    private func rms(_ samples: [Float], at start: Double) -> Double {
        let range = Int(start * 48000)..<min(samples.count, Int((start + 0.1) * 48000))
        guard !range.isEmpty else { return -1 }
        return sqrt(samples[range].reduce(0.0) { $0 + Double($1 * $1) } / Double(range.count))
    }
    func testMixedPreviewExportVolumePlacementAndBlackTail() async throws {
        var project = VideoProject(); project.width = 160; project.height = 90
        project.assets = [try make("video", frequency: 440, video: true), try make("music", frequency: 880), try make("voice", frequency: 660)]
        try project.append(project.assets[0].id)
        project.videoVolume = 0.5
        project.audioClips = [AudioClip(assetID: project.assets[1].id, inFrame: 6, outFrame: 36, startFrame: 15, lane: 0, volume: 0.5),
                              AudioClip(assetID: project.assets[2].id, inFrame: 0, outFrame: 60, startFrame: 30, lane: 1, volume: 0.25)]
        let preview = try await TimelinePreview.build(project)
        XCTAssertEqual(preview.composition.duration.seconds, 3, accuracy: 0.001)
        let liveAudio = directory.appendingPathComponent("live.m4a")
        let session = try XCTUnwrap(AVAssetExportSession(asset: preview.composition, presetName: AVAssetExportPresetAppleM4A))
        session.audioMix = preview.audioMix; session.outputURL = liveAudio; session.outputFileType = .m4a
        await session.export()
        XCTAssertEqual(session.status, .completed, "\(String(describing: session.error))")
        let export = directory.appendingPathComponent("export.mp4")
        try VideoRenderer.render(project, to: export, job: MediaJob())
        let a = try samples(liveAudio), b = try samples(export)
        for time in [0.1, 0.7, 1.2, 1.7, 2.5] {
            XCTAssertGreaterThan(rms(a, at: time), 0.005)
            XCTAssertEqual(rms(a, at: time), rms(b, at: time), accuracy: 0.009, "Mix mismatch at \(time)")
        }
        XCTAssertGreaterThan(rms(b, at: 1.2), rms(b, at: 0.1) * 1.3)
        for generator in [AVAssetImageGenerator(asset: preview.composition), AVAssetImageGenerator(asset: AVURLAsset(url: export))] {
            if generator.asset === preview.composition { generator.videoComposition = preview.videoComposition }
            let image = try await generator.image(at: CMTime(seconds: 2.5, preferredTimescale: 30)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertLessThan(pixel[0], 5); XCTAssertLessThan(pixel[1], 5); XCTAssertLessThan(pixel[2], 5)
        }
    }
}
