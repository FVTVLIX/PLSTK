// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import XCTest
@testable import LocalVideoCore

final class VisualTransitionsTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-transitions-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func fixture() throws -> VideoProject {
        var p = VideoProject(); p.width = 160; p.height = 90
        for color in ["red", "blue"] {
            let url = folder.appendingPathComponent(color + ".mp4")
            _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-f","lavfi","-i","color=\(color):s=160x90:r=30:d=2","-f","lavfi","-i","sine=frequency=440:duration=2","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac",url.path])
            p.assets.append(try MediaProbe.read(url)); try p.append(p.assets.last!.id)
        }
        return p
    }
    private func pixels(_ generator: AVAssetImageGenerator, _ frame: Int64) async throws -> [UInt8] {
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: frame, timescale: 30)).image
        var bytes = [UInt8](repeating: 0, count: 160*90*4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 640,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0,y: 0,width: 160,height: 90))
        }
        return bytes
    }
    private func compare(_ p: VideoProject, frames: [Int64], draft: VisualTransform? = nil) async throws -> [[UInt8]] {
        let preview = try await TimelinePreview.build(p)
        let live = AVAssetImageGenerator(asset: preview.composition)
        live.videoComposition = draft.map { preview.transforming(p.clips.last!.id, to: $0) } ?? preview.videoComposition
        var committed = p
        if let draft { committed.clips[committed.clips.count - 1].transform = draft }
        let url = folder.appendingPathComponent(UUID().uuidString + ".mp4")
        try VideoRenderer.render(committed, to: url, job: MediaJob())
        let export = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        var images: [[UInt8]] = []
        for f in frames {
            let a = try await pixels(live,f), b = try await pixels(export,f)
            let error = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0)-Double($1.1)) } / Double(a.count)
            XCTAssertLessThan(error, 6, "Frame \(f), colors \(Array(a[0..<3])) vs \(Array(b[0..<3]))")
            images.append(b)
        }
        return images
    }
    private func center(_ bytes: [UInt8]) -> [UInt8] { Array(bytes[(45*160+80)*4..<(45*160+80)*4+3]) }
    func testVideoFadesAndSplitContinuityMatchExport() async throws {
        var p = try fixture(); p.clips.removeLast()
        try p.clips[0].setVisualFades(fadeIn: 30, fadeOut: 30)
        let original = p.clips[0]
        let images = try await compare(p,frames: [0,15,30,45,59])
        XCTAssertLessThan(center(images[0])[0], 10)
        XCTAssertEqual(Double(center(images[1])[0]), 127, accuracy: 12)
        XCTAssertGreaterThan(center(images[2])[0], 240)
        try p.split(original.id,at: 15)
        for clip in p.clips { for f in 0..<clip.frames { XCTAssertEqual(clip.fadeGain(at: Double(f)),original.fadeGain(at: Double(clip.inFrame-original.inFrame+f)),accuracy: 1e-10) } }
        _ = try await compare(p,frames: [0,14,15,30,45,59])
    }
    func testDissolveHasCorrectMidpointAndKeepsLaterTrackTimingPredictable() async throws {
        var p = try fixture(); let original = p
        try p.setDissolve(p.clips[1].id,frames: 30)
        XCTAssertEqual(p.clips.map { p.position(of: $0) },[0,30]); XCTAssertEqual(p.totalFrames,90)
        let images = try await compare(p,frames: [29,30,45,59,60,89])
        XCTAssertGreaterThan(center(images[0])[0],240)
        XCTAssertEqual(Double(center(images[2])[0]),127,accuracy:12)
        XCTAssertEqual(Double(center(images[2])[2]),127,accuracy:12)
        XCTAssertGreaterThan(center(images[4])[2],240)
        try p.setDissolve(p.clips[1].id,frames: 0)
        XCTAssertEqual(p.clips.map { p.position(of: $0) }, original.clips.map { original.position(of: $0) })
        XCTAssertEqual(p.totalFrames,original.totalFrames)
    }
    func testTransparentTitleFadesAndDissolvesWithTransforms() async throws {
        var p = try fixture(); p.clips.removeLast()
        var title = TextTitle(style: .caption); title.text = "A new scene"
        let id = try p.addTitle(title,at: 60)
        // addTitle creates an upper layer; place adjacent on the main layer for a dissolve.
        try p.placeVisual(id,at:60,lane:0)
        p.clips[1].outFrame = 60; p.clips[1].opacity = 0.7
        try p.setDissolve(id,frames:30)
        _ = try await compare(p,frames:[30,40,45,59,60,89])
        _ = try await compare(p,frames:[40,45,60],draft:VisualTransform(x:10,y:5,scale:0.7,rotation:12))
        try p.setDissolve(id,frames:0)
        try p.clips[1].setVisualFades(fadeIn:15,fadeOut:15)
        _ = try await compare(p,frames:[60,67,75,105,112,119])
    }
    func testChainedDissolvesRippleOnlyTheirTrackAndRejectTripleBlend() throws {
        var p = try fixture()
        try p.append(p.assets[0].id)
        p.visualTrackCount = 2
        var upper = p.clips[0]; upper.id = UUID(); upper.lane = 1; upper.startFrame = 120
        p.clips.append(upper)
        p.audioClips = [AudioClip(assetID: p.assets[0].id, inFrame: 0, outFrame: 30, startFrame: 120)]
        let upperBefore = p.clips[3], audioBefore = p.audioClips
        let second = p.clips[1].id, third = p.clips[2].id
        try p.setDissolve(second, frames: 15); try p.setDissolve(third, frames: 30)
        XCTAssertEqual(p.clips.prefix(3).map { p.position(of: $0) }, [0,45,75])
        XCTAssertEqual(p.clips[3], upperBefore); XCTAssertEqual(p.audioClips, audioBefore)
        let before = p
        XCTAssertThrowsError(try p.setDissolve(third, frames: 60)); XCTAssertEqual(p,before)
        try p.setDissolve(second, frames: 0)
        XCTAssertEqual(p.clips.prefix(3).map { p.position(of: $0) }, [0,60,90])
        try p.validate()
        var recovery: ProjectRecovery? = try ProjectRecovery(directory: folder.appendingPathComponent("recovery"))
        try recovery?.write(RecoverySnapshot(project: p, originalFileURL: nil))
        recovery = nil
        let reader = try ProjectRecovery(directory: folder.appendingPathComponent("recovery"))
        XCTAssertEqual(try reader.scan().candidates.first?.snapshot.project,p)
    }
    func testLayeredImageFadeWithSourceTrimAndVideoTransform() async throws {
        var p = try fixture()
        p.clips[0].transform = VisualTransform(x: 10, y: -5, scale: 0.8, rotation: 10)
        try p.setDissolve(p.clips[1].id, frames: 15)
        let image = folder.appendingPathComponent("green.png")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-f","lavfi","-i","color=green:s=80x80","-frames:v","1",image.path])
        p.assets.append(try MediaProbe.read(image))
        var clip = Clip(assetID: p.assets.last!.id, inFrame: 15, outFrame: 75)
        clip.startFrame = 15; clip.lane = 1; clip.opacity = 0.6
        clip.transform = VisualTransform(x: -15, y: 5, scale: 0.5, rotation: -15)
        try clip.setVisualFades(fadeIn: 15, fadeOut: 15)
        p.visualTrackCount = 2; p.clips.append(clip)
        _ = try await compare(p, frames: [0,15,22,30,45,52,60,67,74,75,104])
    }
    func testEmbeddedAudioDissolveMatchesPreviewAndVisualFadesKeepSound() async throws {
        var p = try fixture(); p.videoVolume = 0.7
        try p.setDissolve(p.clips[1].id, frames: 30)
        try p.clips[0].setVisualFades(fadeIn: 15, fadeOut: 0)
        let preview = try await TimelinePreview.build(p)
        let live = folder.appendingPathComponent("live.m4a")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: preview.composition, presetName: AVAssetExportPresetAppleM4A))
        exporter.audioMix = preview.audioMix; exporter.outputURL = live; exporter.outputFileType = .m4a
        await exporter.export(); XCTAssertEqual(exporter.status,.completed)
        let output = folder.appendingPathComponent("sound.mp4")
        try VideoRenderer.render(p,to:output,job:MediaJob())
        func samples(_ url: URL) throws -> [Float] {
            let data = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-i",url.path,"-f","f32le","-ac","1","-ar","48000","pipe:1"])
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        func rms(_ values: [Float], _ time: Double) -> Double {
            let a = Int(time * 48000), b = min(values.count,a + 2400)
            return sqrt(values[a..<b].reduce(0.0) { $0 + Double($1 * $1) } / Double(b-a))
        }
        let a = try samples(live), b = try samples(output)
        for time in [0.1,0.5,1.05,1.25,1.5,1.75,1.95,2.1,2.8] {
            XCTAssertEqual(rms(a,time),rms(b,time),accuracy:0.004,"Sound at \(time)")
        }
        XCTAssertGreaterThan(rms(b,0.1),0.04,"A visual fade must not fade the sound")
    }
    func testSaveMigrationValidationAndLinkedEdits() throws {
        var p = try fixture(); let second = p.clips[1].id
        try p.setDissolve(second,frames:15)
        let before = p
        XCTAssertThrowsError(try p.setDissolve(second,frames:Int64.max)); XCTAssertEqual(p,before)
        XCTAssertThrowsError(try p.placeVisual(second,at:120,lane:0)); XCTAssertEqual(p,before)
        XCTAssertThrowsError(try p.split(second,at:5)); XCTAssertEqual(p,before)
        try p.split(p.clips[0].id,at:30)
        try p.validate(); XCTAssertEqual(p.clips.last?.dissolveFrom,p.clips[1].id)
        let url=folder.appendingPathComponent("edit.localvideo");try ProjectFile.save(p,to:url);XCTAssertEqual(try ProjectFile.load(url),p)
        var legacy = try fixture(); var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as! [String:Any]
        json["version"]=8
        json["clips"]=(json["clips"] as! [[String:Any]]).map { entry -> [String:Any] in
            var v=entry; for key in ["fadeInFrames","fadeOutFrames","dissolveFrom","dissolveFrames"] { v.removeValue(forKey:key) }; return v
        }
        legacy=try JSONDecoder().decode(VideoProject.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(legacy.version,9); XCTAssertFalse(legacy.hasVisualTransitions)
        var invalid=before; invalid.clips[1].dissolveFrames = -1; XCTAssertThrowsError(try invalid.validate())
        invalid=before; invalid.clips[0].fadeInFrames=Int64.max;XCTAssertThrowsError(try invalid.validate())
        p.removeVisual(p.clips[1].id); XCTAssertNoThrow(try p.validate());XCTAssertFalse(p.hasDissolves)
    }
}
