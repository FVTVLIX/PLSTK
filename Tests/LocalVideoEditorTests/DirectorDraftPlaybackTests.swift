// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import XCTest
import LocalVideoCore
@testable import LocalVideoEditor

@MainActor final class DirectorDraftPlaybackTests: XCTestCase {
    private func fixture() throws -> (VideoProject, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DraftPlayback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("source.mp4")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-f", "lavfi", "-i", "color=red:s=320x180:r=30:d=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-y", url.path])
        var project = VideoProject(); project.width = 320; project.height = 180
        project.assets = [try MediaProbe.read(url)]; try project.append(project.assets[0].id)
        return (project, folder)
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Draft player did not reach the expected state")
    }
    private func pixels(_ item: AVPlayerItem, at frame: Int64) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: item.asset); generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: frame, timescale: 30)).image
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        bytes.withUnsafeMutableBytes {
            let context = CGContext(data: $0.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        return bytes
    }

    func testDraftHasItsOwnPictureSoundAndPlayheadBeforeOneUndoableApply() async throws {
        let (base, folder) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var title = TextTitle(style: .statement); title.text = "DRAFT ONLY"
        let plan = DirectorPlan(summary: "Add an opening title and a quiet soundtrack", operations: [
            .init(action: .setVisual, clipID: base.clips[0].id, muted: true),
            .init(action: .addAudio, assetID: base.assets[0].id, inFrame: 0, outFrame: 60, startFrame: 0, lane: 0, volume: 0.4),
            .init(action: .addTitle, outFrame: 30, startFrame: 0, title: title)])
        let candidate = try plan.applying(to: base)
        let preferences = "PLSTK-DraftPlayback-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: preferences))
        defer { defaults.removePersistentDomain(forName: preferences) }
        let director = DirectorController(defaults: defaults), store = EditorStore(recoveryDirectory: folder.appendingPathComponent("recovery"))
        store.project = base; store.playheadFrame = 17
        director.pending = DirectorDraft(base: base, project: candidate, plan: plan, warnings: [], frames: [])
        let playback = DirectorDraftPlayer(); defer { playback.stop(); store.cleanup() }
        playback.prepare(candidate)
        try await waitFor { !playback.loading }
        XCTAssertNil(playback.problem)
        let player = try XCTUnwrap(playback.player), item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(item.status, .readyToPlay); XCTAssertNotNil(item.videoComposition)
        XCTAssertFalse(try XCTUnwrap(item.audioMix).inputParameters.isEmpty)
        let duration = try await item.asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.01)
        let output = folder.appendingPathComponent("draft.mp4")
        try VideoRenderer.render(candidate, to: output, job: MediaJob())
        let audioURL = folder.appendingPathComponent("preview-audio.m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: item.asset, presetName: AVAssetExportPresetAppleM4A))
        exporter.outputURL = audioURL; exporter.outputFileType = .m4a; exporter.audioMix = item.audioMix
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed)
        func rms(_ url: URL) throws -> Double {
            let data = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v", "error", "-ss", "0.3", "-i", url.path, "-t", "0.4", "-f", "f32le", "-ac", "1", "-ar", "48000", "pipe:1"])
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
        }
        let previewRMS = try rms(audioURL), exportRMS = try rms(output)
        XCTAssertGreaterThan(previewRMS, 0.02); XCTAssertLessThan(previewRMS, 0.05)
        XCTAssertEqual(previewRMS, exportRMS, accuracy: 0.003)
        for frame: Int64 in [15, 45] {
            let actual = try await pixels(item, at: frame), exported = try await pixels(AVPlayerItem(url: output), at: frame)
            let difference = zip(actual, exported).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(actual.count)
            XCTAssertLessThan(difference, 5)
            let white = stride(from: 0, to: actual.count, by: 4).filter { actual[$0] > 190 && actual[$0 + 1] > 190 && actual[$0 + 2] > 190 }.count
            if frame == 15 { XCTAssertGreaterThan(white, 100) } else { XCTAssertLessThan(white, 10) }
        }
        await player.seek(to: CMTime(value: 40, timescale: 30), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertEqual(store.project, base); XCTAssertEqual(store.playheadFrame, 17)
        XCTAssertTrue(store.past.isEmpty); XCTAssertFalse(store.dirty)
        playback.stop(); XCTAssertNil(player.currentItem); XCTAssertEqual(player.rate, 0)
        XCTAssertNotNil(director.pending)
        director.apply(to: store)
        XCTAssertEqual(store.project, candidate); XCTAssertEqual(store.past.count, 1)
        store.undo(); XCTAssertEqual(store.project, base)
    }

    func testClosingDuringPreparationRejectsLateResult() async throws {
        let (project, folder) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let preview = try await TimelinePreview.build(project)
        var continuation: CheckedContinuation<TimelinePreview, Error>?
        let playback = DirectorDraftPlayer { _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        playback.prepare(project)
        try await waitFor { continuation != nil }
        playback.stop(); continuation?.resume(returning: preview)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(playback.player); XCTAssertFalse(playback.loading); XCTAssertNil(playback.problem)
    }

    func testNewPreparationWinsWhenOlderBuildCompletesLast() async throws {
        let (project, folder) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await TimelinePreview.build(project)
        var shorter = project; shorter.clips[0].outFrame = 30
        let second = try await TimelinePreview.build(shorter)
        var continuations: [CheckedContinuation<TimelinePreview, Error>] = []
        let playback = DirectorDraftPlayer { _ in try await withCheckedThrowingContinuation { continuations.append($0) } }
        defer { playback.stop() }
        playback.prepare(project); try await waitFor { continuations.count == 1 }
        playback.prepare(shorter); try await waitFor { continuations.count == 2 }
        continuations[1].resume(returning: second)
        try await waitFor { !playback.loading }
        let player = try XCTUnwrap(playback.player)
        continuations[0].resume(returning: first)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(playback.player === player)
        let duration = try await XCTUnwrap(player.currentItem).asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.01)
    }

    func testUnavailableMediaCanBeRetriedWithoutLosingDraft() async throws {
        let (project, folder) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var missing = project; missing.assets[0].path = folder.appendingPathComponent("missing.mp4").path
        let playback = DirectorDraftPlayer(); defer { playback.stop() }
        playback.prepare(missing); try await waitFor { !playback.loading }
        XCTAssertNotNil(playback.problem); XCTAssertNil(playback.player)
        playback.prepare(project); try await waitFor { !playback.loading }
        XCTAssertNil(playback.problem); XCTAssertNotNil(playback.player)
        let player = try XCTUnwrap(playback.player); player.play()
        playback.stop(); XCTAssertEqual(player.rate, 0); XCTAssertNil(player.currentItem)
    }
}
