// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import XCTest
@testable import LocalVideoCore

final class DirectorInspectionTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PLSTK-inspection-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func fixture() throws -> VideoProject {
        var project = VideoProject(); project.width = 160; project.height = 90
        let url = folder.appendingPathComponent("colors.mp4")
        _ = try MediaJob().run(MediaTools.find("ffmpeg"), ["-v","error","-f","lavfi","-i","color=red:s=160x90:r=30:d=1","-f","lavfi","-i","color=blue:s=160x90:r=30:d=1","-filter_complex","[0:v][1:v]concat=n=2:v=1:a=0","-c:v","libx264","-pix_fmt","yuv420p",url.path])
        project.assets = [try MediaProbe.read(url)]
        return project
    }
    func testSourceRangeSamplingIsTimestampedBoundedAndNotFirstAssetOnly() async throws {
        var p = try fixture()
        for _ in 0..<3 { var copy = p.assets[0]; copy.id = UUID(); p.assets.insert(copy,at:0) }
        let asset = p.assets[3]
        let request = DirectorInspectionRequest(assetID:asset.id,startFrame:30,endFrame:60,samples:3)
        XCTAssertEqual(try request.frames(in:p),[30,44,59])
        let batch = try await DirectorMediaInspection.sample([request],project:p)
        XCTAssertEqual(batch.frames[asset.id],Set([30,44,59])); XCTAssertEqual(batch.images.count,3)
        XCTAssertTrue(batch.images[0].label.contains("SOURCE")); XCTAssertTrue(batch.images[0].label.contains("1.000 seconds"))
        XCTAssertFalse(batch.images[0].label.contains(folder.path))
        let image = try XCTUnwrap(NSBitmapImageRep(data:batch.images[0].jpeg))
        let color = try XCTUnwrap(image.colorAt(x:40,y:40)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent,0.8); XCTAssertLessThan(color.redComponent,0.1)
        XCTAssertEqual(batch.sources[asset.id],try MediaVisualSource(asset))
    }
    func testSingleFrameAndStillSampling() throws {
        var p = VideoProject()
        p.assets = [MediaAsset(path:"/synthetic/image.png",duration:5,width:80,height:80,isImage:true),MediaAsset(path:"/synthetic/video.mp4",duration:2,width:160,height:90)]
        XCTAssertEqual(try DirectorInspectionRequest(assetID:p.assets[0].id,startFrame:30,endFrame:60,samples:6).frames(in:p),[0])
        XCTAssertEqual(try DirectorInspectionRequest(assetID:p.assets[1].id,startFrame:30,endFrame:60,samples:1).frames(in:p),[44])
        XCTAssertEqual(try DirectorInspectionRequest(assetID:p.assets[1].id,startFrame:30,endFrame:31,samples:6).frames(in:p),[30])
    }
    func testInvalidRangesAndUnknownAssetsAreRejectedBeforeDecoding() async throws {
        let p = try fixture(), id = p.assets[0].id
        for request in [DirectorInspectionRequest(assetID:UUID(),startFrame:0,endFrame:30,samples:1),
                        .init(assetID:id,startFrame:-1,endFrame:30,samples:1), .init(assetID:id,startFrame:0,endFrame:61,samples:1),
                        .init(assetID:id,startFrame:30,endFrame:30,samples:1), .init(assetID:id,startFrame:0,endFrame:Int64.max,samples:1),
                        .init(assetID:id,startFrame:0,endFrame:30,samples:7)] {
            XCTAssertThrowsError(try request.frames(in:p))
        }
        do { _ = try await DirectorMediaInspection.sample(Array(repeating:.init(assetID:id,startFrame:0,endFrame:30,samples:2),count:4),project:p); XCTFail("Expected sample budget rejection") }
        catch { XCTAssertTrue(error is EditorError) }
    }
    func testStrictStepProtocolAcceptsPlansAndInspectionsOnly() throws {
        let id = UUID().uuidString
        let inspect = "{\"version\":1,\"summary\":\"Look at the later shot\",\"inspect\":[{\"assetID\":\"\(id)\",\"startFrame\":30,\"endFrame\":60,\"samples\":3}]}"
        if case .inspect(let requests,let notes) = try DirectorStep.decode(Data(inspect.utf8)) { XCTAssertEqual(requests.count,1); XCTAssertTrue(notes.isEmpty) } else { XCTFail("Expected inspection") }
        let plan = DirectorPlan(summary:"Keep the edit")
        if case .plan(let decoded,_) = try DirectorStep.decode(JSONEncoder().encode(plan)) { XCTAssertEqual(decoded,plan) } else { XCTFail("Expected plan") }
        for value in [inspect.replacingOccurrences(of:"\"samples\":3",with:"\"samples\":7"),inspect.replacingOccurrences(of:"\"inspect\":",with:"\"operations\":[],\"inspect\":"),inspect.replacingOccurrences(of:"\"samples\":3",with:"\"samples\":3,\"path\":\"/private/file\""),"{\"version\":1,\"summary\":\"\",\"inspect\":[]}"] {
            XCTAssertThrowsError(try DirectorStep.decode(Data(value.utf8)))
        }
    }
    func testCacheReusesOnlyObservedFramesAndMatchingSourceAndProvider() throws {
        let p = try fixture(), asset = p.assets[0]
        let connection = DirectorConnection(model:"vision-model",baseURL:"https://model.example/v1")
        let note = DirectorObservation(assetID:asset.id,frames:[30,59],description:"Blue frames at the sampled times.")
        let supplied: [UUID:Set<Int64>] = [asset.id:Set([30,59])], sources = [asset.id:try MediaVisualSource(asset)]
        var cache = DirectorSceneCache()
        try cache.remember([note],project:p,connection:connection,supplied:supplied,sources:sources)
        XCTAssertEqual(try cache.observations(project:p,connection:connection),[note]); XCTAssertTrue(try cache.context(project:p,connection:connection).contains("Blue frames"))
        XCTAssertFalse(try cache.context(project:p,connection:connection).contains(folder.path))
        var other = connection; other.model = "other-model"; XCTAssertTrue(try cache.observations(project:p,connection:other).isEmpty)
        other = connection; other.baseURL = "https://other.example/v1"; XCTAssertTrue(try cache.observations(project:p,connection:other).isEmpty)
        let invented = DirectorObservation(assetID:asset.id,frames:[29],description:"Not supplied")
        XCTAssertThrowsError(try cache.remember([note,invented],project:p,connection:connection,supplied:supplied,sources:sources)); XCTAssertEqual(cache.count,1)
        let file = URL(fileURLWithPath:asset.path), data = try Data(contentsOf:file)
        try (data + Data([0])).write(to:file)
        XCTAssertThrowsError(try cache.remember([note],project:p,connection:connection,supplied:supplied,sources:sources))
        XCTAssertThrowsError(try cache.remember([],project:p,connection:connection,supplied:supplied,sources:sources))
        XCTAssertTrue(try cache.observations(project:p,connection:connection).isEmpty)
        cache.clear(); XCTAssertEqual(cache.count,0)
    }
    func testCacheIsBoundedAndRejectsBadObservationDescriptions() throws {
        let p = try fixture(), asset = p.assets[0], source = try MediaVisualSource(asset), connection = DirectorConnection(model:"vision")
        var cache = DirectorSceneCache()
        for frame in 0..<70 {
            let note = DirectorObservation(assetID:asset.id,frames:[Int64(frame % 30),Int64(30 + frame / 30)],description:String(repeating:"v",count:600))
            try cache.remember([note],project:p,connection:connection,supplied:[asset.id:Set([Int64(frame % 30),Int64(30 + frame / 30)])],sources:[asset.id:source])
        }
        XCTAssertEqual(cache.count,64); XCTAssertLessThanOrEqual(try cache.context(project:p,connection:connection).utf8.count,8000)
        for note in [DirectorObservation(assetID:asset.id,frames:[],description:"Empty"),.init(assetID:asset.id,frames:[0],description:String(repeating:"v",count:601)),.init(assetID:asset.id,frames:[0,0],description:"Duplicate")] {
            XCTAssertThrowsError(try cache.remember([note],project:p,connection:connection,supplied:[asset.id:Set([0])],sources:[asset.id:source]))
        }
    }
    func testVisualReviewRequiresCompleteReplacementOrAcceptance() throws {
        let accepted = Data(#"{"version":1,"decision":"accept","summary":"The sampled title is readable."}"#.utf8)
        XCTAssertNil(try DirectorVisualReview.decode(accepted).replacement)
        let plan = DirectorPlan(summary:"Smaller title",operations:[.init(action:.renameProject,name:"Refined")])
        let object: [String:Any] = ["version":1,"decision":"revise","summary":"Fix layout","plan":try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan))]
        XCTAssertEqual(try DirectorVisualReview.decode(JSONSerialization.data(withJSONObject:object)).replacement,plan)
        for text in [#"{"version":1,"decision":"revise","summary":"No plan"}"#,#"{"version":2,"decision":"accept","summary":"Unsupported"}"#,#"{"version":1,"decision":"accept","summary":"","shell":"no"}"#] {
            XCTAssertThrowsError(try DirectorVisualReview.decode(Data(text.utf8)))
        }
    }
    func testCancelledSourceSamplingProducesNoImages() async throws {
        let p = try fixture(), id = p.assets[0].id
        let work = Task { try Task.checkCancellation(); return try await DirectorMediaInspection.sample([.init(assetID:id,startFrame:0,endFrame:60,samples:6)],project:p) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
}
