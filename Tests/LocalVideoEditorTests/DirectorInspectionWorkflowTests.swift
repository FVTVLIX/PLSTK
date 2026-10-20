// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import XCTest
import LocalVideoCore
@testable import LocalVideoEditor

private struct InspectionRecord: Sendable {
    let text: String
    let imageCount: Int
    let labels: [String]
}
private final class InspectionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responses: [String] = []
    private static var records: [InspectionRecord] = []
    private static var delay = 0.0
    private var work: DispatchWorkItem?
    static func configure(_ values: [String], delay: Double = 0) {
        lock.lock(); defer { lock.unlock() }; responses = values; records = []; Self.delay = delay
    }
    static func calls() -> [InspectionRecord] { lock.lock(); defer { lock.unlock() }; return records }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bytes.append(contentsOf:buffer.prefix(n)) }
        }
        let root = (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any]
        let messages = root?["messages"] as? [[String:Any]] ?? []
        let content = messages.last?["content"] as? [[String:Any]] ?? []
        let record = InspectionRecord(text:content.first?["text"] as? String ?? "",imageCount:content.filter { $0["type"] as? String == "image_url" }.count,
            labels:content.dropFirst().compactMap { $0["text"] as? String })
        Self.lock.lock(); Self.records.append(record); let reply = Self.responses.isEmpty ? "{}" : Self.responses.removeFirst(); let delay = Self.delay; Self.lock.unlock()
        let operation = DispatchWorkItem { [weak self] in
            guard let self, self.work?.isCancelled != true else { return }
            let envelope = try! JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"stop","message":["content":reply]]]])
            let response = HTTPURLResponse(url:self.request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
            self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); self.client?.urlProtocol(self,didLoad:envelope); self.client?.urlProtocolDidFinishLoading(self)
        }
        work = operation; DispatchQueue.global().asyncAfter(deadline:.now()+delay,execute:operation)
    }
    override func stopLoading() { work?.cancel() }
}
private struct InspectionSecrets: DirectorSecretStore {
    func read(_ connection:DirectorConnection)throws ->String { "" }
    func write(_ key:String,for connection:DirectorConnection)throws {}
}

@MainActor final class DirectorInspectionWorkflowTests: XCTestCase {
    private struct Harness {
        let director: DirectorController
        let project: VideoProject
        let folder: URL
        let defaults: UserDefaults
        let session: URLSession
        let name: String
        @MainActor func close() { director.cancel(); session.invalidateAndCancel(); defaults.removePersistentDomain(forName:name); try? FileManager.default.removeItem(at:folder) }
    }
    private func harness() throws -> Harness {
        let name = "PLSTK-inspection-workflow-\(UUID())", folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let image = try TextTitle().raster(width:160,height:90), url = folder.appendingPathComponent("source.png")
        try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])).write(to:url)
        var p = VideoProject(); p.width = 160; p.height = 90
        for _ in 0..<4 { p.assets.append(MediaAsset(path:url.path,duration:5,width:160,height:90,isImage:true)) }
        try p.append(p.assets[3].id)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [InspectionProtocol.self]
        let session = URLSession(configuration:configuration), defaults = UserDefaults(suiteName:name)!
        let director = DirectorController(provider:DirectorProvider(session:session),secrets:InspectionSecrets(),defaults:defaults)
        try director.saveConnection(DirectorConnection(model:"vision-fixture",baseURL:"https://model.example/v1"),key:nil)
        director.shareFrames = true
        return Harness(director:director,project:p,folder:folder,defaults:defaults,session:session,name:name)
    }
    private func json(_ object:[String:Any])throws ->String { String(decoding:try JSONSerialization.data(withJSONObject:object),as:UTF8.self) }
    private func plan(_ name:String, title:Bool = false)throws ->DirectorPlan {
        var operations: [DirectorOperation] = [.init(action:.renameProject,name:name)]
        if title { var value = TextTitle(style:.caption); value.text = name; operations.append(.init(action:.addTitle,outFrame:45,startFrame:0,title:value)) }
        return DirectorPlan(summary:name,operations:operations)
    }
    private func planJSON(_ value:DirectorPlan, observation:DirectorObservation? = nil)throws ->String {
        var root = try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
        if let observation { root["observations"] = [try JSONSerialization.jsonObject(with:JSONEncoder().encode(observation))] }
        return try json(root)
    }
    private func inspection(_ p:VideoProject)throws ->String {
        try json(["version":1,"summary":"Inspect the relevant source","inspect":[["assetID":p.assets[3].id.uuidString,"startFrame":0,"endFrame":1,"samples":1]]])
    }
    private func accepted()throws ->String { try json(["version":1,"decision":"accept","summary":"The supplied stills show a readable title and consistent layout."]) }
    private func send(_ h:Harness,_ prompt:String = "Make a clean edit") async throws {
        h.director.send(prompt,project:h.project,selectedClip:h.project.clips[0].id,selectedAudio:nil,playhead:0)
        for _ in 0..<300 { if !h.director.working { return }; try await Task.sleep(nanoseconds:20_000_000) }
        XCTFail("Director did not finish its bounded loop"); h.director.cancel()
    }
    func testInspectLaterAssetReviewAndRefineBeforeOneUndoableApply() async throws {
        let h = try harness(); defer { h.close() }
        let observation = DirectorObservation(assetID:h.project.assets[3].id,frames:[0],description:"A title appears in the supplied source still.")
        let first = try plan("Initial draft",title:true), replacement = try plan("Refined layout",title:true)
        let review = try json(["version":1,"decision":"revise","summary":"Use a clearer title plate.","plan":try JSONSerialization.jsonObject(with:JSONEncoder().encode(replacement))])
        InspectionProtocol.configure([try inspection(h.project),try planJSON(first,observation:observation),review,try accepted()])
        try await send(h)
        XCTAssertNil(h.director.error)
        let draft = try XCTUnwrap(h.director.pending)
        XCTAssertEqual(draft.base,h.project); XCTAssertEqual(draft.project.name,"Refined layout"); XCTAssertEqual(draft.project.clips.count,2)
        XCTAssertTrue(draft.reviewRevised); XCTAssertNotNil(draft.visualReview); XCTAssertEqual(draft.frames.count,3)
        XCTAssertEqual(h.director.cachedObservations,1)
        XCTAssertTrue(h.director.activity.contains("Inspecting footage")); XCTAssertTrue(h.director.activity.contains("Refining draft")); XCTAssertTrue(h.director.activity.contains("Checking layout"))
        let calls = InspectionProtocol.calls(); XCTAssertEqual(calls.count,4); XCTAssertEqual(calls.map(\.imageCount),[0,1,3,3])
        XCTAssertTrue(calls[1].labels[0].contains(h.project.assets[3].id.uuidString)); XCTAssertTrue(calls[2].labels.allSatisfy { $0.hasPrefix("DRAFT") })
        XCTAssertFalse(calls.contains { $0.text.contains(h.folder.path) })
        let store = EditorStore(recoveryDirectory:h.folder.appendingPathComponent("recovery")); store.project = h.project
        h.director.apply(to:store); XCTAssertEqual(store.past.count,1); XCTAssertEqual(store.project.name,"Refined layout")
        store.undo(); XCTAssertEqual(store.project,h.project); store.cleanup()
    }
    func testFollowUpReusesNotesAndNewChatForgetsThem() async throws {
        let h = try harness(); defer { h.close() }
        let note = DirectorObservation(assetID:h.project.assets[3].id,frames:[0],description:"Distinct visual note from a sampled still.")
        InspectionProtocol.configure([try inspection(h.project),try planJSON(plan("First"),observation:note),try accepted()])
        try await send(h); XCTAssertEqual(h.director.cachedObservations,1)
        InspectionProtocol.configure([try planJSON(plan("Follow up")),try accepted()])
        try await send(h,"Use the footage we inspected")
        XCTAssertNil(h.director.error); XCTAssertEqual(InspectionProtocol.calls().count,2)
        XCTAssertTrue(InspectionProtocol.calls()[0].text.contains(note.description)); XCTAssertEqual(InspectionProtocol.calls()[0].imageCount,0)
        h.director.clearChat(); XCTAssertEqual(h.director.cachedObservations,0); XCTAssertTrue(h.director.messages.isEmpty)
    }
    func testSharingOffDeniesInspectionAndSkipsModelReview() async throws {
        let h = try harness(); defer { h.close() }; h.director.shareFrames = false
        InspectionProtocol.configure([try inspection(h.project),try planJSON(plan("Metadata draft"))])
        try await send(h)
        XCTAssertNil(h.director.error); XCTAssertEqual(InspectionProtocol.calls().count,2)
        XCTAssertTrue(InspectionProtocol.calls().allSatisfy { $0.imageCount == 0 })
        XCTAssertTrue(InspectionProtocol.calls()[1].text.contains("has not enabled visual sharing"))
        XCTAssertNil(h.director.pending?.visualReview); XCTAssertEqual(h.director.cachedObservations,0)
        XCTAssertTrue(h.director.pending?.warnings.contains { $0.contains("sharing is off") } ?? false)
    }
    func testInspectionLimitStopsRepeatedToolRequestsWithoutChangingProject() async throws {
        let h = try harness(); defer { h.close() }
        InspectionProtocol.configure(Array(repeating:try inspection(h.project),count:10))
        try await send(h)
        XCTAssertNotNil(h.director.error); XCTAssertNil(h.director.pending)
        XCTAssertLessThanOrEqual(InspectionProtocol.calls().count,6); XCTAssertEqual(InspectionProtocol.calls().count,4)
        XCTAssertEqual(h.project.name,"Untitled edit")
    }
    func testInvalidVisualRevisionPreservesCheckedDraftWithWarning() async throws {
        let h = try harness(); defer { h.close() }
        let bad = DirectorPlan(summary:"Bad reference",operations:[.init(action:.removeVisual,clipID:UUID())])
        let review = try json(["version":1,"decision":"revise","summary":"Invalid suggestion","plan":try JSONSerialization.jsonObject(with:JSONEncoder().encode(bad))])
        InspectionProtocol.configure([try planJSON(plan("Original checked draft",title:true)),review])
        try await send(h)
        XCTAssertNil(h.director.error); XCTAssertEqual(h.director.pending?.project.name,"Original checked draft")
        XCTAssertNil(h.director.pending?.visualReview); XCTAssertTrue(h.director.pending?.warnings.contains { $0.contains("review was unavailable") } ?? false)
        XCTAssertEqual(InspectionProtocol.calls().count,2)
    }
    func testSecondVisualRevisionIsNotAppliedAndReviewRemainsIncomplete() async throws {
        let h = try harness(); defer { h.close() }
        func revision(_ name:String)throws ->String { try json(["version":1,"decision":"revise","summary":"Refine","plan":try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan(name)))]) }
        InspectionProtocol.configure([try planJSON(plan("Initial")),try revision("Allowed refinement"),try revision("Not applied")])
        try await send(h)
        XCTAssertEqual(h.director.pending?.project.name,"Allowed refinement"); XCTAssertTrue(h.director.pending?.reviewRevised ?? false)
        XCTAssertNil(h.director.pending?.visualReview); XCTAssertTrue(h.director.pending?.warnings.contains { $0.contains("refinement limit") } ?? false)
        XCTAssertEqual(InspectionProtocol.calls().count,3)
    }
    func testStopPreventsLateRequestsAndDraftPublication() async throws {
        let h = try harness(); defer { h.close() }
        InspectionProtocol.configure([try inspection(h.project),try planJSON(plan("Too late"))],delay:0.5)
        h.director.send("Inspect footage",project:h.project,selectedClip:nil,selectedAudio:nil,playhead:0)
        for _ in 0..<40 { if !InspectionProtocol.calls().isEmpty { break }; try await Task.sleep(nanoseconds:5_000_000) }
        h.director.cancel(); try await Task.sleep(nanoseconds:650_000_000)
        XCTAssertFalse(h.director.working); XCTAssertNil(h.director.pending); XCTAssertEqual(h.director.cachedObservations,0)
        XCTAssertEqual(InspectionProtocol.calls().count,1)
    }
}
