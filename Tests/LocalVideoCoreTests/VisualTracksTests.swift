// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import ImageIO
import XCTest
@testable import LocalVideoCore

final class VisualTracksTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-tracks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testPlacementCollisionSplitAndRoundTrip() throws {
        var project = VideoProject(); project.visualTrackCount = 2
        let asset = MediaAsset(path: "/tmp/track.mov", duration: 4, width: 160, height: 90)
        project.assets = [asset]
        project.clips = [Clip(assetID: asset.id, inFrame: 0, outFrame: 60, startFrame: 30),
                         Clip(assetID: asset.id, inFrame: 0, outFrame: 30, startFrame: 60, lane: 1)]
        try project.validate(); XCTAssertEqual(project.totalFrames, 90)
        let old = project
        XCTAssertThrowsError(try project.placeVisual(project.clips[1].id, at: 60, lane: 0))
        XCTAssertEqual(project, old, "Rejected placement must be atomic")
        try project.placeVisual(project.clips[1].id, at: 120, lane: 0)
        XCTAssertEqual(project.totalFrames, 150)
        try project.split(project.clips[0].id, at: 30)
        XCTAssertEqual(project.clips[1].startFrame, 60); XCTAssertEqual(project.clips[1].lane, 0)
        project.clips.removeFirst()
        XCTAssertEqual(project.clips[0].startFrame, 60, "Deleting does not ripple other clips")
        let file = directory.appendingPathComponent("layers.localvideo")
        try ProjectFile.save(project, to: file); XCTAssertEqual(try ProjectFile.load(file), project)
        var invalid = project; invalid.clips[0].lane = 2
        XCTAssertThrowsError(try invalid.validate())
    }
    func testLegacySequenceAndAutomaticTrackChoice() throws {
        var legacy = VideoProject()
        let asset = MediaAsset(path: "/tmp/legacy.mov", duration: 2, width: 160, height: 90)
        legacy.assets = [asset]; try legacy.append(asset.id); try legacy.append(asset.id)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json["version"] = 3; json.removeValue(forKey: "visualTrackCount")
        var project = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: json))
        project.materializePositions()
        XCTAssertEqual(project.clips.map(\.startFrame), [0,60]); XCTAssertEqual(project.duration, 4)
        try project.insertVisual(asset.id, at: 30)
        XCTAssertEqual(project.visualTrackCount, 2); XCTAssertEqual(project.clips.last?.lane, 1)
        try project.insertVisual(asset.id, at: 120)
        XCTAssertEqual(project.clips.last?.lane, 0); XCTAssertEqual(project.visualTrackCount, 2)
        try project.validate()
        XCTAssertEqual(try project.availableVisualLane(at: 60, frames: 30), 2)
        XCTAssertEqual(project.visualTrackCount, 3)
    }
    private func video(_ name: String, color: String, frequency: Int) throws -> MediaAsset {
        let url = directory.appendingPathComponent(name + ".mp4")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-f", "lavfi", "-i", "color=\(color):s=160x90:r=30:d=4", "-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=4:sample_rate=48000", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path])
        return try MediaProbe.read(url)
    }
    private func pixel(_ generator: AVAssetImageGenerator, frame: Int64) async throws -> [UInt8] {
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: frame, timescale: 30)).image
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    func testLayersGapsBoundariesAndAudioMixMatchExport() async throws {
        var project = VideoProject(); project.width = 160; project.height = 90; project.visualTrackCount = 3
        project.assets = [try video("red", color: "red", frequency: 440), try video("blue", color: "blue", frequency: 660)]
        let imageURL = directory.appendingPathComponent("green.png")
        let context = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        project.assets.append(try MediaProbe.read(imageURL))
        project.clips = [Clip(assetID: project.assets[0].id, inFrame: 6, outFrame: 96, startFrame: 30),
                         Clip(assetID: project.assets[1].id, inFrame: 0, outFrame: 30, startFrame: 60, lane: 1),
                         Clip(assetID: project.assets[1].id, inFrame: 30, outFrame: 60, startFrame: 180),
                         Clip(assetID: project.assets[2].id, inFrame: 0, outFrame: 30, startFrame: 75, lane: 2)]
        project.audioClips = [AudioClip(assetID: project.assets[0].id, inFrame: 0, outFrame: 30, startFrame: 210, volume: 0.5)]
        let preview = try await TimelinePreview.build(project)
        XCTAssertEqual(preview.composition.duration.seconds, 8, accuracy: 0.001)
        let output = directory.appendingPathComponent("layers.mp4")
        try VideoRenderer.render(project, to: output, job: MediaJob())
        let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for (frame, channel) in [(Int64(0), -1),(29,-1),(30,0),(59,0),(60,2),(74,2),(75,1),(89,1),(90,1),(104,1),(105,0),(119,0),(120,-1),(179,-1),(180,2),(209,2),(210,-1),(239,-1)] {
            let a = try await pixel(live, frame: frame), b = try await pixel(exported, frame: frame)
            XCTAssertLessThan(zip(a,b).map { abs(Int($0)-Int($1)) }.max()!, 8, "Mismatch at \(frame): live \(a), export \(b)")
            if channel < 0 { XCTAssertLessThan(a.prefix(3).max()!, 8, "Gap must be black at \(frame)") }
            else { XCTAssertGreaterThan(a[channel], 180, "Wrong layer at \(frame)") }
        }
        let audio = directory.appendingPathComponent("live.m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: preview.composition, presetName: AVAssetExportPresetAppleM4A))
        exporter.audioMix = preview.audioMix; exporter.outputURL = audio; exporter.outputFileType = .m4a
        await exporter.export(); XCTAssertEqual(exporter.status, .completed)
        func decode(_ url: URL) throws -> [Float] {
            let bytes = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-i", url.path, "-f", "f32le", "-ac", "1", "-ar", "48000", "pipe:1"])
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let a = try decode(audio), b = try decode(output)
        func rms(_ samples: [Float], _ seconds: Double) -> Double {
            let values = samples[Int(seconds * 48000)..<Int((seconds + 0.15) * 48000)]
            return sqrt(values.reduce(0.0) { $0 + Double($1 * $1) } / Double(values.count))
        }
        for time in [0.2,1.2,2.2,3.2,4.5,6.2,7.2] {
            XCTAssertEqual(rms(a,time), rms(b,time), accuracy: 0.008, "Audio placement/mix at \(time)")
        }
        XCTAssertLessThan(rms(a,0.2),0.001); XCTAssertLessThan(rms(a,4.5),0.001)
        XCTAssertGreaterThan(rms(a,2.2), rms(a,1.2) * 1.2, "Covered lower-track audio still mixes")
        XCTAssertGreaterThan(rms(a,7.2),0.02)
    }
}
