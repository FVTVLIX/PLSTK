// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import XCTest
@testable import LocalVideoCore

final class TimelinePreviewTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String, color: String, audio: Bool = false) throws -> MediaAsset {
        let url = directory.appendingPathComponent(name + ".mp4")
        var args = ["-v", "error", "-f", "lavfi", "-i", "color=c=\(color):s=160x90:r=30:d=2"]
        if audio { args += ["-itsoffset", "0.5", "-f", "lavfi", "-i", "sine=frequency=440:duration=1.5:sample_rate=48000"] }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
        if audio { args += ["-c:a", "aac"] }
        args += ["-y", url.path]
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), args)
        return try MediaProbe.read(url)
    }

    private func pixels(_ generator: AVAssetImageGenerator, seconds: Double) async throws -> [UInt8] {
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return bytes
    }

    func testLiveFramesMatchExportAcrossTrimmedCutAndSilentClip() async throws {
        var project = VideoProject(); project.width = 320; project.height = 180
        project.assets = [try fixture("red", color: "red", audio: true), try fixture("blue", color: "blue")]
        project.clips = [Clip(assetID: project.assets[1].id, inFrame: 6, outFrame: 36),
                         Clip(assetID: project.assets[0].id, inFrame: 0, outFrame: 60)]
        let red = project.clips[1].id
        try project.moveClip(red, to: 0)
        try project.rippleTrim(red, edge: .start, delta: 15)
        try project.rippleTrim(red, edge: .end, delta: -15)
        let preview = try await TimelinePreview.build(project)
        XCTAssertEqual(preview.composition.duration.seconds, 2, accuracy: 0.0001)
        let audioTracks = try await preview.composition.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "Silent second clip must not repeat first clip's audio")
        let output = directory.appendingPathComponent("export.mp4")
        try VideoRenderer.render(project, to: output, job: MediaJob())
        let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for seconds in [0.0, 0.5, 29.0 / 30, 1.0, 1.5, 59.0 / 30] {
            let a = try await pixels(live, seconds: seconds), b = try await pixels(exported, seconds: seconds)
            let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            XCTAssertLessThan(error, 4, "Preview/export mismatch at \(seconds) seconds")
            let middle = (16 * 32 + 16) * 4
            if seconds < 1 { XCTAssertGreaterThan(a[middle], 180); XCTAssertLessThan(a[middle + 2], 30) }
            else { XCTAssertGreaterThan(a[middle + 2], 180); XCTAssertLessThan(a[middle], 30) }
        }
    }

    func testDelayedAudioKeepsOffsetAfterTrim() async throws {
        var project = VideoProject()
        project.assets = [try fixture("delayed", color: "red", audio: true)]
        project.clips = [Clip(assetID: project.assets[0].id, inFrame: 6, outFrame: 45)]
        let preview = try await TimelinePreview.build(project)
        let audioOutput = directory.appendingPathComponent("preview-audio.m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: preview.composition, presetName: AVAssetExportPresetAppleM4A))
        exporter.outputURL = audioOutput; exporter.outputFileType = .m4a
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed, "\(String(describing: exporter.error))")
        let rendered = directory.appendingPathComponent("reference.mp4")
        try VideoRenderer.render(project, to: rendered, job: MediaJob())
        for url in [audioOutput, rendered] {
            let pcm = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-i", url.path, "-f", "f32le", "-ac", "1", "-ar", "48000", "pipe:1"])
            let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            func rms(_ start: Double, _ end: Double) -> Double {
                let values = samples[Int(start * 48000)..<min(samples.count, Int(end * 48000))]
                return sqrt(values.reduce(0.0) { $0 + Double($1 * $1) } / Double(values.count))
            }
            XCTAssertLessThan(rms(0.02, 0.2), 0.001, "Leading gap lost in \(url.lastPathComponent)")
            XCTAssertGreaterThan(rms(0.5, 0.8), 0.03, "Tone missing in \(url.lastPathComponent)")
        }
        XCTAssertEqual(preview.composition.duration.seconds, 1.3, accuracy: 0.0001)
    }

    func testRotatedPortraitFramesMatchLetterboxedExport() async throws {
        let original = try fixture("original", color: "green")
        let rotated = directory.appendingPathComponent("rotated.mp4")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-display_rotation", "90", "-i", original.path, "-c", "copy", "-y", rotated.path])
        var project = VideoProject(); project.width = 320; project.height = 180
        project.assets = [try MediaProbe.read(rotated)]; try project.append(project.assets[0].id)
        XCTAssertEqual(abs(project.assets[0].rotation), 90)
        let preview = try await TimelinePreview.build(project)
        let output = directory.appendingPathComponent("portrait-export.mp4")
        try VideoRenderer.render(project, to: output, job: MediaJob())
        let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let a = try await pixels(live, seconds: 0.5), b = try await pixels(exported, seconds: 0.5)
        let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        XCTAssertLessThan(error, 5)
        XCTAssertLessThan(a[(16 * 32 + 1) * 4 + 1], 10, "Portrait output must have black side bars")
        XCTAssertGreaterThan(a[(16 * 32 + 16) * 4 + 1], 80)
    }
}
