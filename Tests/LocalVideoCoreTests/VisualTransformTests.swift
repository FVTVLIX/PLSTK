// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AVFoundation
import ImageIO
import XCTest
@testable import LocalVideoCore

final class VisualTransformTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-transform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func video(_ name: String, color: String, corner: Bool = false) throws -> MediaAsset {
        let url = directory.appendingPathComponent(name + ".mp4")
        var args = ["-v", "error", "-f", "lavfi", "-i", "color=\(color):s=160x90:r=30:d=2"]
        if corner { args += ["-vf", "drawbox=x=0:y=0:w=30:h=20:color=white:t=fill"] }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", url.path]
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), args)
        return try MediaProbe.read(url)
    }
    func testTransformPersistenceSplitLegacyDefaultsAndValidation() throws {
        var project = VideoProject()
        project.assets = [MediaAsset(path: "/tmp/transform.mp4", duration: 2, width: 160, height: 90)]
        let transform = VisualTransform(x: 65.5, y: -20, scale: 0.42, rotation: 27)
        project.clips = [Clip(assetID: project.assets[0].id, inFrame: 0, outFrame: 60, transform: transform)]
        try project.split(project.clips[0].id, at: 30)
        XCTAssertEqual(project.clips.map(\.transform), [transform, transform])
        let file = directory.appendingPathComponent("transform.localvideo")
        try ProjectFile.save(project, to: file); XCTAssertEqual(try ProjectFile.load(file), project)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        json["version"] = 4
        json["clips"] = (json["clips"] as! [[String: Any]]).map { entry -> [String: Any] in var entry = entry; entry.removeValue(forKey: "transform"); return entry }
        let legacy = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.version, 8); XCTAssertEqual(legacy.clips[0].transform, VisualTransform())
        for bad in [VisualTransform(x: .nan), VisualTransform(scale: 0), VisualTransform(scale: 4.01), VisualTransform(rotation: .infinity), VisualTransform(y: 32769)] {
            project.clips[0].transform = bad; XCTAssertThrowsError(try project.validate())
        }
    }
    private func pixels(_ generator: AVAssetImageGenerator, at frame: Int64 = 15) async throws -> [UInt8] {
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: frame, timescale: 30)).image
        var bytes = [UInt8](repeating: 0, count: 320 * 180 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        return bytes
    }
    private func compare(_ project: VideoProject, name: String) async throws -> [UInt8] {
        let preview = try await TimelinePreview.build(project)
        let output = directory.appendingPathComponent(name + ".mp4")
        try VideoRenderer.render(project, to: output, job: MediaJob())
        let live = AVAssetImageGenerator(asset: preview.composition); live.videoComposition = preview.videoComposition
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for frame: Int64 in [0,15,59] {
            let a = try await pixels(live, at: frame), b = try await pixels(exported, at: frame)
            let error = zip(a,b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            XCTAssertLessThan(error, 5, "\(name) at frame \(frame)")
        }
        return try await pixels(live)
    }
    func testDraftCompositionMatchesCommittedTransformWithoutChangingOriginal() async throws {
        var project = VideoProject(); project.width = 320; project.height = 180; project.visualTrackCount = 2
        let red = try video("draft-red", color: "red")
        let blue = try video("draft-blue", color: "blue", corner: true)
        project.assets = [red, blue]
        project.clips = [Clip(assetID: red.id, inFrame: 0, outFrame: 60, startFrame: 0),
                         Clip(assetID: blue.id, inFrame: 0, outFrame: 30, startFrame: 15, lane: 1)]
        let preview = try await TimelinePreview.build(project)
        let generator = AVAssetImageGenerator(asset: preview.composition)
        generator.videoComposition = preview.videoComposition
        let original = try await pixels(generator, at: 30)
        let value = VisualTransform(x: 55, y: 20, scale: 0.4, rotation: 31)
        generator.videoComposition = preview.transforming(project.clips[1].id, to: value)
        let draft = try await pixels(generator, at: 30)
        project.clips[1].transform = value
        let output = directory.appendingPathComponent("draft.mp4")
        try VideoRenderer.render(project, to: output, job: MediaJob())
        let rendered = try await pixels(AVAssetImageGenerator(asset: AVURLAsset(url: output)), at: 30)
        let error = zip(draft, rendered).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(draft.count)
        XCTAssertLessThan(error, 5)
        XCTAssertNotEqual(original, draft)
        generator.videoComposition = preview.videoComposition
        let restored = try await pixels(generator, at: 30)
        XCTAssertEqual(original, restored, "Draft instructions must not mutate the original composition")
    }
    private func rgb(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * 320 + x) * 4..<(y * 320 + x) * 4 + 3]) }
    func testPictureInPicturePositionScaleClockwiseRotationAndClipping() async throws {
        var project = VideoProject(); project.width = 320; project.height = 180; project.visualTrackCount = 2
        project.assets = [try video("red", color: "red"), try video("blue", color: "blue", corner: true)]
        project.clips = [Clip(assetID: project.assets[0].id, inFrame: 0, outFrame: 60),
                         Clip(assetID: project.assets[1].id, inFrame: 0, outFrame: 60, startFrame: 0, lane: 1,
                              transform: VisualTransform(x: 60, y: 25, scale: 0.5))]
        let pip = try await compare(project, name: "pip")
        XCTAssertGreaterThan(rgb(pip,220,115)[2],180); XCTAssertGreaterThan(rgb(pip,40,40)[0],180)
        project.clips[1].transform = VisualTransform(x: 60, y: 0, scale: 0.5, rotation: 90)
        let rotated = try await compare(project, name: "clockwise")
        XCTAssertGreaterThan(rgb(rotated,255,20).min()!,180, "White source corner must rotate clockwise to upper right")
        XCTAssertGreaterThan(rgb(rotated,185,160)[2],180)
        project.clips[1].transform = VisualTransform(x: 150, y: -50, scale: 0.75, rotation: -23)
        _ = try await compare(project, name: "clipped-arbitrary-angle")
    }
    func testTransformedStillAndSourceOrientationMatchExport() async throws {
        var project = VideoProject(); project.width = 320; project.height = 180; project.visualTrackCount = 2
        let red = try video("base", color: "red"), blue = try video("portrait", color: "blue", corner: true)
        let rotatedURL = directory.appendingPathComponent("oriented.mp4")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-display_rotation","90","-i",blue.path,"-c","copy",rotatedURL.path])
        project.assets = [red, try MediaProbe.read(rotatedURL)]
        project.clips = [Clip(assetID: red.id,inFrame: 0,outFrame: 60),Clip(assetID: project.assets[1].id,inFrame: 0,outFrame: 60,startFrame: 0,lane: 1,transform: VisualTransform(x: -70,y: 20,scale: 0.6,rotation: -20))]
        _ = try await compare(project,name: "oriented-source")
        let imageURL = directory.appendingPathComponent("green.png")
        let context = CGContext(data: nil,width: 160,height: 90,bitsPerComponent: 8,bytesPerRow: 640,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0,green: 1,blue: 0,alpha: 1));context.fill(CGRect(x: 0,y: 0,width: 160,height: 90))
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil);XCTAssertTrue(CGImageDestinationFinalize(destination))
        project.assets.append(try MediaProbe.read(imageURL));project.clips[1].assetID = project.assets[2].id
        project.clips[1].transform = VisualTransform(x: 40,y: -20,scale: 0.4,rotation: 15)
        let image = try await compare(project,name: "still-pip")
        XCTAssertGreaterThan(rgb(image,200,70)[1],180);XCTAssertGreaterThan(rgb(image,20,20)[0],180)
    }
}
