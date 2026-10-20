// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import AppKit
import XCTest
import LocalVideoCore
@testable import LocalVideoEditor

private final class MemoryDirectorSecrets: DirectorSecretStore {
    var values: [String: String] = [:]
    func read(_ connection: DirectorConnection) throws -> String { values[connection.baseURL] ?? "" }
    func write(_ key: String, for connection: DirectorConnection) throws { values[connection.baseURL] = key }
}

final class DirectorWorkflowTests: XCTestCase {
    @MainActor private func controller() -> (DirectorController, UserDefaults, String) {
        let name = "PLSTK-director-test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        return (DirectorController(secrets: MemoryDirectorSecrets(), defaults: defaults), defaults, name)
    }
    func testCheckedDraftAppliesAsOneUndoStepAndRejectsManualEditConflict() async throws {
        let (director, store, original, defaults, name) = try await MainActor.run {
            let (director, defaults, name) = controller()
            let store = EditorStore(recoveryDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(name)); var p = VideoProject(); p.width = 160; p.height = 90
            try p.addTitle(TextTitle(),at:0); store.project = p
            return (director, store, p, defaults, name)
        }
        let bytes = try JSONEncoder().encode(DirectorPlan(summary:"A clearer opening",operations:[.init(action:.renameProject,name:"New edit"),.init(action:.setVisualFades,clipID:original.clips[0].id,fadeInFrames:15,fadeOutFrames:15)]))
        await director.importDraft(bytes,project:original)
        await MainActor.run {
            XCTAssertNotNil(director.pending); XCTAssertEqual(director.pending?.frames.count,3)
            XCTAssertEqual(store.project,original); XCTAssertTrue(store.past.isEmpty)
            director.apply(to:store)
            XCTAssertEqual(store.project.name,"New edit"); XCTAssertEqual(store.past.count,1)
            store.undo(); XCTAssertEqual(store.project,original)
            store.redo(); XCTAssertEqual(store.project.name,"New edit")
            director.pending = DirectorDraft(base:original,project:store.project,plan:DirectorPlan(),warnings:[],frames:[])
            var manual = original; manual.name = "Manual choice"; store.project = manual
            director.apply(to:store); XCTAssertEqual(store.project,manual); XCTAssertNil(director.pending); XCTAssertNotNil(director.error)
            store.cleanup(); try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name)); defaults.removePersistentDomain(forName:name)
        }
    }
    func testConnectionPersistsOnlyConfigurationAndEmptyPlanDoesNotCreateDraft() async throws {
        let (director, defaults, name) = await MainActor.run { controller() }
        try await MainActor.run {
            let connection = DirectorConnection(kind:.ollama,model:"local-model",baseURL:"http://localhost:11434/v1")
            try director.saveConnection(connection,key:"test-value-that-stays-in-memory")
            let saved = try XCTUnwrap(defaults.data(forKey:"director.connection"))
            XCTAssertFalse(String(decoding:saved,as:UTF8.self).contains("test-value"))
            XCTAssertEqual(try JSONDecoder().decode(DirectorConnection.self,from:saved),connection)
        }
        await director.importDraft(try JSONEncoder().encode(DirectorPlan(summary:"Which footage should I use?")),project:VideoProject())
        await MainActor.run {
            XCTAssertNil(director.pending); XCTAssertFalse(director.working); XCTAssertEqual(director.messages.last?.text,"Which footage should I use?")
            defaults.removePersistentDomain(forName:name)
        }
    }
}

private final class DirectorWorkflowProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var replies: [Data] = []
    static var calls = 0
    static func reset(_ values: [Data]) { lock.lock(); defer { lock.unlock() }; calls = 0; replies = values }
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.calls += 1
        let bytes = Self.replies.isEmpty ? Data() : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension DirectorWorkflowTests {
    func testProviderPlanGetsOneRepairThenLocalPreviewBeforeApply() async throws {
        let malformed = "{\"version\":1,\"summary\":\"Bad operation\",\"operations\":[{\"action\":\"run_shell\"}]}"
        let valid = try JSONEncoder().encode(DirectorPlan(summary:"A shorter opening",operations:[.init(action:.renameProject,name:"Prepared draft")]))
        func envelope(_ value: String) throws -> Data {
            try JSONSerialization.data(withJSONObject:["choices":[["finish_reason":"stop","message":["content":value]]]])
        }
        DirectorWorkflowProtocol.reset([try envelope(malformed), try envelope(String(decoding:valid,as:UTF8.self))])
        let (director, original, defaults, name, session) = try await MainActor.run {
            let name = "PLSTK-director-network-test-\(UUID())", defaults = UserDefaults(suiteName:name)!
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DirectorWorkflowProtocol.self]
            let session = URLSession(configuration:configuration)
            let director = DirectorController(provider:DirectorProvider(session:session),secrets:MemoryDirectorSecrets(),defaults:defaults)
            try director.saveConnection(DirectorConnection(model:"fixture-model",baseURL:"https://model.example/v1"),key:nil)
            var p = VideoProject(); p.width = 160; p.height = 90; try p.addTitle(TextTitle(),at:0)
            director.send("Make the opening concise",project:p,selectedClip:p.clips.first?.id,selectedAudio:nil,playhead:0)
            return (director,p,defaults,name,session)
        }
        for _ in 0..<200 {
            if await MainActor.run(body:{ !director.working }) { break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        await MainActor.run {
            XCTAssertFalse(director.working); XCTAssertNil(director.error)
            XCTAssertEqual(director.pending?.base,original); XCTAssertEqual(director.pending?.project.name,"Prepared draft")
            XCTAssertEqual(director.pending?.frames.count,3)
            director.projectChanged(VideoProject()); XCTAssertNil(director.pending)
            defaults.removePersistentDomain(forName:name); session.invalidateAndCancel()
        }
        XCTAssertEqual(DirectorWorkflowProtocol.count(),2)
    }
}


extension DirectorWorkflowTests {
    func testRequestBudgetPreservesProjectAndAllowsOneUnicodeRepair() async throws {
        try await MainActor.run {
            let snapshot = String(repeating:"a",count:128_000), prompt = String(repeating:"映",count:8000)
            let instructions = DirectorLook.minimal.instructions
            let input = try DirectorController.requestText(snapshot:snapshot,history:String(repeating:"話",count:16000),prompt:prompt,instructions:instructions)
            XCTAssertTrue(input.contains(snapshot)); XCTAssertTrue(input.contains(prompt))
            let repair = input + String(repeating:"訂",count:3000) + String(repeating:"正",count:256) + "Return a corrected plan."
            XCTAssertLessThan(instructions.utf8.count + repair.utf8.count,200_000)
            XCTAssertThrowsError(try DirectorController.requestText(snapshot:String(repeating:"a",count:190000),history:"",prompt:prompt,instructions:instructions))
        }
    }
    func testCancellingAnImportedDraftDoesNotPublishItsPreview() async throws {
        let (director, defaults, name) = await MainActor.run { controller() }
        var project = VideoProject(); project.width = 160; project.height = 90; try project.addTitle(TextTitle(),at:0)
        let data = try JSONEncoder().encode(DirectorPlan(summary:"Cancelled",operations:[.init(action:.renameProject,name:"Discarded draft")]))
        let operation = Task { await director.importDraft(data,project:project) }
        operation.cancel(); await operation.value
        await MainActor.run {
            XCTAssertFalse(director.working); XCTAssertNil(director.pending); XCTAssertTrue(director.messages.isEmpty)
            defaults.removePersistentDomain(forName:name)
        }
    }
}
