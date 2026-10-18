// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import XCTest
@testable import LocalVideoCore

final class MediaVisualsTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaVisualsTests-\(UUID().uuidString)")
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
    private func pixel(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    func testThumbnailRequestsCoalesceAndReplacementInvalidatesFileIdentity() async throws {
        let cache = MediaVisualCache()
        let red = try fixture("source", color: "red")
        let source = try MediaVisualSource(red)
        async let a = cache.thumbnail(source, frame: 15)
        async let b = cache.thumbnail(source, frame: 15)
        let (first, second) = try await (a, b)
        XCTAssertTrue(first === second)
        XCTAssertGreaterThan(pixel(first)[0], 180)
        XCTAssertLessThanOrEqual(first.width, 192)
        let blue = try fixture("replacement", color: "blue")
        try FileManager.default.removeItem(atPath: red.path)
        try FileManager.default.moveItem(atPath: blue.path, toPath: red.path)
        let replaced = try MediaVisualSource(red)
        XCTAssertNotEqual(source, replaced)
        let newImage = try await cache.thumbnail(replaced, frame: 15)
        XCTAssertGreaterThan(pixel(newImage)[2], 180)
        XCTAssertLessThan(pixel(newImage)[0], 30)
    }
    func testWaveformPreservesLeadingGapAndSourceRangePeaks() async throws {
        let media = try fixture("delayed", color: "red", audio: true)
        let source = try MediaVisualSource(media), cache = MediaVisualCache()
        let waveform = try await cache.waveform(source)
        XCTAssertLessThanOrEqual(waveform.peaks.count, 16_384)
        XCTAssertLessThan(waveform.peak(from: 0.05, to: 0.3), 0.001)
        XCTAssertGreaterThan(waveform.peak(from: 0.7, to: 1.2), 0.05)
        XCTAssertEqual(waveform.peak(from: 5, to: 6), 0)
        XCTAssertEqual(waveform.peak(from: .nan, to: 1), 0)
        let cached = try await cache.waveform(source)
        XCTAssertEqual(waveform.peaks, cached.peaks)
    }
    func testWorkerShutdownCancelsWaveformBeforeLaunch() async throws {
        let media = try fixture("shutdown", color: "red", audio: true)
        let cache = MediaVisualCache()
        cache.stopWorkers()
        do {
            _ = try await cache.waveform(MediaVisualSource(media))
            XCTFail("A closed cache must not launch a new media worker")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testSilentClipHasNoFabricatedWaveformAndMissingFileThrows() async throws {
        let media = try fixture("silent", color: "blue")
        let source = try MediaVisualSource(media)
        let waveform = try await MediaVisualCache().waveform(source)
        XCTAssertTrue(waveform.peaks.isEmpty)
        try FileManager.default.removeItem(atPath: media.path)
        XCTAssertThrowsError(try MediaVisualSource(media))
    }
}
