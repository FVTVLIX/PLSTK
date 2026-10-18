// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import XCTest
@testable import LocalVideoCore

final class TextTitleTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-Titles-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func project() -> VideoProject { var p = VideoProject(); p.width = 320; p.height = 180; return p }
    private func bytes(_ image: CGImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 320 * 180 * 4)
        result.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        return result
    }
    func testTitlesSaveInsideProjectAndRecoveryWithoutMediaFiles() throws {
        var p = project(), title = TextTitle(style: .statement)
        title.text = "Hello, world!\nA new story"
        let id = try p.addTitle(title, at: 30)
        XCTAssertEqual(p.clips.first?.id, id); XCTAssertEqual(p.totalFrames, 180)
        try p.validate(requireMedia: true)
        let url = directory.appendingPathComponent("title.localvideo")
        try ProjectFile.save(p, to: url)
        XCTAssertEqual(try ProjectFile.load(url), p)
        let recovery = try ProjectRecovery(directory: directory.appendingPathComponent("Recovery"))
        XCTAssertNoThrow(try recovery.write(RecoverySnapshot(project: p, originalFileURL: url)))
        XCTAssertEqual(p.assets.first?.path, "")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project())) as! [String: Any]
        json["version"] = 7
        let legacy = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.version, 9); XCTAssertTrue(legacy.assets.isEmpty)
    }
    func testTitleInsertionAlwaysSitsAboveOverlappingVisualsAndIsAtomicWhenFull() throws {
        var p = project()
        let lower = try p.addTitle(TextTitle(), at: 0)
        p.visualTrackCount = 4; p.clips[0].lane = 3
        let upper = try p.addTitle(TextTitle(style: .caption), at: 0)
        XCTAssertEqual(p.clips.first { $0.id == upper }?.lane, 4)
        XCTAssertEqual(p.clips.first { $0.id == lower }?.lane, 3)
        p.visualTrackCount = 32; p.clips[1].lane = 31
        let before = p
        XCTAssertThrowsError(try p.addTitle(TextTitle(), at: 0))
        XCTAssertEqual(p, before)
    }
    func testSplitDuplicateAndTrimKeepTitlesIndependentlyEditable() throws {
        var p = project()
        let id = try p.addTitle(TextTitle(), at: 0)
        try p.split(id, at: 60)
        let second = p.clips[1].id
        var changed = TextTitle(style: .caption); changed.text = "Only the second part"
        try p.updateTitle(second, to: changed)
        XCTAssertEqual(try p.asset(for: p.clips[0]).title?.text, "Your title")
        XCTAssertEqual(try p.asset(for: p.clips[1]).title, changed)
        var copy = p.clips[1]; copy.id = UUID(); copy.lane = 1; p.visualTrackCount = 2; p.clips.append(copy)
        changed.text = "Only the duplicate"; try p.updateTitle(copy.id, to: changed)
        XCTAssertEqual(try p.asset(for: p.clips[1]).title?.text, "Only the second part")
        XCTAssertEqual(try p.asset(for: p.clips[2]).title?.text, "Only the duplicate")
        let trimmed = try p.trimmedClip(copy.id, edge: .end, delta: 300)
        XCTAssertEqual(trimmed.frames, 390)
        try p.validate()
    }
    func testInvalidTitleEditsDoNotMutateTheProject() throws {
        var p = project(); let id = try p.addTitle(TextTitle(), at: 0); let before = p
        for text in ["", "   \n", String(repeating: "x", count: 1001), String(repeating: "line\n", count: 9), "bad\u{0}"] {
            var title = TextTitle(); title.text = text
            XCTAssertThrowsError(try p.updateTitle(id, to: title)); XCTAssertEqual(p, before)
        }
        for size in [0.0, 0.251, Double.infinity, Double.nan] {
            var title = TextTitle(); title.size = size
            XCTAssertThrowsError(try p.updateTitle(id, to: title)); XCTAssertEqual(p, before)
        }
    }
    func testRasterHasTransparentMarginsReadableTextAndAlignment() throws {
        var title = TextTitle(); title.text = "Story"; title.size = 0.2
        var centers: [Double] = []
        for alignment in [TitleAlignment.left, .center, .right] {
            title.alignment = alignment
            let bounds = try title.contentBounds(width: 320, height: 180)
            XCTAssertLessThan(bounds.width, 320); XCTAssertLessThan(bounds.height, 90)
            let image = bytes(try title.raster(width: 320, height: 180))
            var xs: [Int] = []
            for y in 0..<180 { for x in 0..<320 where image[(y * 320 + x) * 4 + 3] > 100 { xs.append(x) } }
            XCTAssertGreaterThan(xs.count, 200)
            XCTAssertEqual(image[3], 0)
            centers.append(Double(xs.reduce(0, +)) / Double(xs.count))
        }
        XCTAssertLessThan(centers[0], centers[1] - 40); XCTAssertLessThan(centers[1], centers[2] - 40)
        title.style = .caption; title.text = "Café 🎬\nQuotes: ' \" ; [x]"
        XCTAssertNoThrow(try title.raster(width: 320, height: 180))
    }
    func testTitleThumbnailsUseContentInCacheIdentity() async throws {
        var p = project(); let id = try p.addTitle(TextTitle(), at: 0)
        let first = try MediaVisualSource(p.assets[0])
        let cache = MediaVisualCache()
        let image = try await cache.thumbnail(first, frame: 100)
        XCTAssertEqual(image.width, 192)
        var title = TextTitle(); title.text = "Changed title"; try p.updateTitle(id, to: title)
        XCTAssertNotEqual(first, try MediaVisualSource(p.assets[0]))
    }
    private func compare(_ p: VideoProject, frames: [Int64]) async throws -> [[UInt8]] {
        let preview = try await TimelinePreview.build(p)
        let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
        let output = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try VideoRenderer.render(p, to: output, job: MediaJob())
        let export = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        live.requestedTimeToleranceBefore = .zero; live.requestedTimeToleranceAfter = .zero
        export.requestedTimeToleranceBefore = .zero; export.requestedTimeToleranceAfter = .zero
        var images: [[UInt8]] = []
        for frame in frames {
            let a = bytes(try await live.image(at: CMTime(value: frame, timescale: 30)).image)
            let b = bytes(try await export.image(at: CMTime(value: frame, timescale: 30)).image)
            let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            XCTAssertLessThan(error, 4, "Preview/export at frame \(frame)")
            images.append(a)
        }
        return images
    }
    func testTitleOnlyTimelineAndTransparentOverlayMatchPreviewAndExport() async throws {
        var p = project(), title = TextTitle(style: .statement)
        title.text = "Hello, PLSTK"
        _ = try p.addTitle(title, at: 0); p.clips[0].outFrame = 30
        // A title identifies its own source kind even without the legacy image flag.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        var assets = json["assets"] as! [[String: Any]]; assets[0].removeValue(forKey: "image"); json["assets"] = assets
        p = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: json))
        let solo = try await compare(p, frames: [0, 15, 29])
        XCTAssertGreaterThan(solo[0].filter { $0 > 200 }.count, 320 * 180, "Visible white text on black")
        let base = directory.appendingPathComponent("blue.mp4")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-f","lavfi","-i","color=blue:s=320x180:r=30:d=2","-c:v","libx264","-pix_fmt","yuv420p",base.path])
        let media = try MediaProbe.read(base)
        p.assets.append(media); p.clips[0].lane = 1; p.clips[0].startFrame = 15; p.visualTrackCount = 2
        p.clips.insert(Clip(assetID: media.id, inFrame: 0, outFrame: 60, startFrame: 0), at: 0)
        title.style = .caption; title.color = .yellow; title.alignment = .left
        try p.updateTitle(p.clips[1].id, to: title)
        p.clips[1].opacity = 0.6; p.clips[1].transform = VisualTransform(x: 12, y: 14, scale: 0.8, rotation: 8)
        let overlay = try await compare(p, frames: [14, 15, 30, 44, 45, 59])
        let before = overlay[0], during = overlay[2], after = overlay[4]
        let difference = zip(before,during).reduce(0) { $0 + abs(Int($1.0)-Int($1.1)) }
        XCTAssertGreaterThan(difference, 10_000, "The title must visibly appear during its range")
        XCTAssertLessThan(zip(before,after).reduce(0) { $0 + abs(Int($1.0)-Int($1.1)) }, 5000)
        XCTAssertGreaterThan(during[2], 230, "Transparent corner reveals the blue footage")
    }
}
