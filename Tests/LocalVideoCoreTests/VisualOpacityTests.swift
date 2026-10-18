// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import ImageIO
import XCTest
@testable import LocalVideoCore

final class VisualOpacityTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-alpha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func video(_ name: String, color: String) throws -> MediaAsset {
        let url = directory.appendingPathComponent(name + ".mp4")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-f","lavfi","-i","color=\(color):s=160x90:r=30:d=2","-f","lavfi","-i","sine=frequency=440:duration=2","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac",url.path])
        return try MediaProbe.read(url)
    }
    private func image() throws -> MediaAsset {
        let context = CGContext(data: nil,width: 160,height: 90,bitsPerComponent: 8,bytesPerRow: 640,
                                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0,y: 0,width: 160,height: 90))
        context.setFillColor(CGColor(red: 1,green: 0,blue: 0,alpha: 1))
        context.fill(CGRect(x: 40,y: 10,width: 40,height: 70))
        context.setFillColor(CGColor(red: 0,green: 1,blue: 0,alpha: 0.5))
        context.fill(CGRect(x: 80,y: 10,width: 40,height: 70))
        let url = directory.appendingPathComponent("alpha.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try MediaProbe.read(url)
    }
    private func pixels(_ generator: AVAssetImageGenerator, frame: Int64) async throws -> [UInt8] {
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: frame,timescale: 30)).image
        var bytes = [UInt8](repeating: 0,count: 160 * 90 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress,width: 160,height: 90,bitsPerComponent: 8,bytesPerRow: 640,
                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in: CGRect(x: 0,y: 0,width: 160,height: 90))
        }
        return bytes
    }
    private func compare(_ project: VideoProject, frames: [Int64], draft: VisualTransform? = nil) async throws -> [UInt8] {
        let preview = try await TimelinePreview.build(project)
        let live = AVAssetImageGenerator(asset: preview.composition)
        live.videoComposition = draft.map { preview.transforming(project.clips[1].id,to: $0) } ?? preview.videoComposition
        var committed = project
        if let draft { committed.clips[1].transform = draft }
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try VideoRenderer.render(committed,to: url,job: MediaJob())
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        var result: [UInt8] = []
        for frame in frames {
            let a = try await pixels(live,frame: frame), b = try await pixels(exported,frame: frame)
            let error = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            XCTAssertLessThan(error,5,"Frame \(frame)")
            result = a
        }
        return result
    }
    private func color(_ bytes: [UInt8], x: Int) -> [UInt8] { Array(bytes[(45 * 160 + x) * 4..<(45 * 160 + x) * 4 + 3]) }
    func testOpacityValidationMigrationSplitAndSave() throws {
        var project = VideoProject(); project.assets = [MediaAsset(path: "/tmp/alpha.png",duration: 5,width: 160,height: 90,isImage: true)]
        project.clips = [Clip(assetID: project.assets[0].id,inFrame: 0,outFrame: 60,opacity: 0.37)]
        try project.split(project.clips[0].id,at: 30)
        XCTAssertEqual(project.clips.map(\.opacity),[0.37,0.37]); XCTAssertTrue(project.clips.allSatisfy(\.imageTransparency))
        let url = directory.appendingPathComponent("alpha.localvideo")
        try ProjectFile.save(project,to: url); XCTAssertEqual(try ProjectFile.load(url),project)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        json["version"] = 5
        json["clips"] = (json["clips"] as! [[String: Any]]).map { entry -> [String: Any] in
            var entry = entry; entry.removeValue(forKey: "opacity"); entry.removeValue(forKey: "imageTransparency"); return entry
        }
        let legacy = try JSONDecoder().decode(VideoProject.self,from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.version,7); XCTAssertTrue(legacy.clips.allSatisfy { $0.opacity == 1 && !$0.imageTransparency })
        for bad in [-0.01,1.01,Double.nan,Double.infinity] {
            project.clips[0].opacity = bad; XCTAssertThrowsError(try project.validate())
        }
    }
    func testVideoOpacityZeroHalfFullAndTransformDraft() async throws {
        var project = VideoProject(); project.width = 160; project.height = 90; project.visualTrackCount = 2
        let red = try video("red",color: "red"), blue = try video("blue",color: "blue")
        project.assets = [red,blue]
        project.clips = [Clip(assetID: red.id,inFrame: 0,outFrame: 60),Clip(assetID: blue.id,inFrame: 0,outFrame: 30,startFrame: 15,lane: 1,opacity: 0.5)]
        let half = try await compare(project,frames: [14,15,30,44])
        XCTAssertEqual(Double(color(half,x: 80)[0]),127,accuracy: 12); XCTAssertEqual(Double(color(half,x: 80)[2]),127,accuracy: 12)
        _ = try await compare(project,frames: [30],draft: VisualTransform(x: 15,y: 5,scale: 0.6,rotation: 18))
        project.clips[1].opacity = 0
        let hidden = try await compare(project,frames: [15,30,44,45,59]); XCTAssertGreaterThan(color(hidden,x: 80)[0],230)
        let preview = try await TimelinePreview.build(project)
        let audioTracks = try await preview.composition.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count,2,"Opacity must not mute audio")
        project.clips[1].opacity = 1
        let opaque = try await compare(project,frames: [30]); XCTAssertGreaterThan(color(opaque,x: 80)[2],230)
    }
    func testImageAlphaAndOpacityAcrossOverlapsAndLegacyFlattening() async throws {
        var project = VideoProject(); project.width = 160; project.height = 90; project.visualTrackCount = 2
        let blue = try video("base",color: "blue"), png = try image()
        project.assets = [blue,png]
        project.clips = [Clip(assetID: blue.id,inFrame: 0,outFrame: 60),Clip(assetID: png.id,inFrame: 0,outFrame: 30,startFrame: 15,lane: 1)]
        let alpha = try await compare(project,frames: [14,15,30,44])
        XCTAssertGreaterThan(color(alpha,x: 20)[2],230,"Transparent pixels reveal blue")
        XCTAssertGreaterThan(color(alpha,x: 60)[0],230,"Opaque red stays opaque")
        XCTAssertEqual(Double(color(alpha,x: 100)[1]),127,accuracy: 15)
        XCTAssertEqual(Double(color(alpha,x: 100)[2]),127,accuracy: 15)
        project.clips[1].opacity = 0.5
        let half = try await compare(project,frames: [30]); XCTAssertEqual(Double(color(half,x: 60)[0]),127,accuracy: 15)
        XCTAssertEqual(Double(color(half,x: 100)[1]),64,accuracy: 15); XCTAssertEqual(Double(color(half,x: 100)[2]),191,accuracy: 15)
        _ = try await compare(project,frames: [30],draft: VisualTransform(x: 20,y: -5,scale: 0.6,rotation: -21))
        project.clips[1].opacity = 0
        let hidden = try await compare(project,frames: [15,30,44])
        XCTAssertGreaterThan(color(hidden,x: 60)[2],230)
        project.clips[1].opacity = 0.5
        // Same asset, different alpha semantics in one project exercises normalized-image reuse keys.
        project.clips.append(Clip(assetID: png.id,inFrame: 0,outFrame: 15,startFrame: 45,lane: 1,imageTransparency: false))
        let flattened = try await compare(project,frames: [44,45,59]); XCTAssertLessThan(color(flattened,x: 20).max()!,15)
    }
}
