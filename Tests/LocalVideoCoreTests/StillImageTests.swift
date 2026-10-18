// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import ImageIO
import XCTest
@testable import LocalVideoCore

final class StillImageTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func image(_ ext: String = "png", orientation: Int = 1) throws -> MediaAsset {
        let context = CGContext(data: nil, width: 80, height: 120, bitsPerComponent: 8, bytesPerRow: 320,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: 80, height: 120))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 40, height: 80))
        let url = directory.appendingPathComponent("source.\(ext)")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, (ext == "png" ? "public.png" : "public.jpeg") as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try MediaProbe.read(url)
    }
    func testImportDefaultDurationEditingAndLegacyRoundTrip() throws {
        let media = try image(); XCTAssertTrue(media.isImage); XCTAssertEqual(media.duration, 5)
        var project = VideoProject(); project.assets = [media]; try project.append(media.id)
        XCTAssertEqual(project.totalFrames, 150)
        try project.rippleTrim(project.clips[0].id, edge: .end, delta: 90)
        XCTAssertEqual(project.totalFrames, 240)
        try project.split(project.clips[0].id, at: 45)
        try project.validate()
        let url = directory.appendingPathComponent("images.localvideo")
        try ProjectFile.save(project, to: url); XCTAssertEqual(try ProjectFile.load(url), project)
        var legacy = VideoProject(); legacy.assets = [MediaAsset(path: "/tmp/old.mp4", duration: 2, width: 80, height: 120)]
        try legacy.append(legacy.assets[0].id)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json["version"] = 2
        let decoded = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.version, 8); XCTAssertFalse(decoded.assets[0].isImage)
    }
    func testStillThumbnailAndInvalidImage() async throws {
        let media = try image()
        let cache = MediaVisualCache()
        let thumbnail = try await cache.thumbnail(MediaVisualSource(media), frame: 90)
        XCTAssertEqual(thumbnail.width, 80); XCTAssertEqual(thumbnail.height, 120)
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        XCTAssertThrowsError(try MediaProbe.read(invalid))
    }
    private func pixels(_ generator: AVAssetImageGenerator, at frame: Int64) async throws -> [UInt8] {
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: frame, timescale: 30)).image
        var bytes = [UInt8](repeating: 0, count: 160 * 90 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 640,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        return bytes
    }
    func testTransparentStillPreviewMatchesExportAcrossVideoCut() async throws {
        var project = VideoProject(); project.width = 160; project.height = 90
        let media = try image(); let video = directory.appendingPathComponent("blue.mp4")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-f", "lavfi", "-i", "color=blue:s=160x90:r=30:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path])
        project.assets = [media, try MediaProbe.read(video)]
        project.clips = [Clip(assetID: media.id, inFrame: 30, outFrame: 210), Clip(assetID: project.assets[1].id, inFrame: 0, outFrame: 30)]
        let preview = try await TimelinePreview.build(project)
        XCTAssertEqual(preview.composition.duration.seconds, 7, accuracy: 0.001)
        let audioTracks = try await preview.composition.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
        let output = directory.appendingPathComponent("export.mp4")
        try VideoRenderer.render(project, to: output, job: MediaJob())
        let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
        let rendered = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for frame: Int64 in [0, 90, 179, 180, 209] {
            let a = try await pixels(live, at: frame), b = try await pixels(rendered, at: frame)
            let error = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            XCTAssertLessThan(error, 5, "Frame \(frame), live \(Array(a[(45*160+80)*4..<(45*160+80)*4+4])), export \(Array(b[(45*160+80)*4..<(45*160+80)*4+4]))")
            let center = (45 * 160 + 80) * 4
            XCTAssertGreaterThan(a[center + (frame < 180 ? 0 : 2)], 180)
            if frame < 180 { XCTAssertLessThan(a[(45 * 160 + 45) * 4], 15, "Transparent margin must be black") }
        }
        let pcm = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-i", output.path, "-f", "f32le", "-ac", "1", "pipe:1"])
        XCTAssertTrue(pcm.withUnsafeBytes { $0.bindMemory(to: Float.self).allSatisfy { abs($0) < 0.001 } })
    }
    func testOrientedJPEGPreviewMatchesExportAndSingleFrameImage() async throws {
        let media = try image("jpg", orientation: 6)
        XCTAssertEqual(media.width, 120); XCTAssertEqual(media.height, 80)
        var project = VideoProject(); project.width = 160; project.height = 90; project.assets = [media]
        project.clips = [Clip(assetID: media.id, inFrame: 0, outFrame: 1)]
        let preview = try await TimelinePreview.build(project)
        let output = directory.appendingPathComponent("single.mp4")
        try VideoRenderer.render(project, to: output, job: MediaJob())
        let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
        let a = try await pixels(live, at: 0), b = try await pixels(AVAssetImageGenerator(asset: AVURLAsset(url: output)), at: 0)
        let error = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        XCTAssertLessThan(error, 5, "center live \(Array(a[(45*160+80)*4..<(45*160+80)*4+4])), export \(Array(b[(45*160+80)*4..<(45*160+80)*4+4]))")
    }
}
