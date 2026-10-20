// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation
import XCTest
@testable import LocalVideoCore

private final class DirectorStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    static var delay: TimeInterval = 0
    static var simulateRedirect = false
    private var pending: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let (status, data, headers) = try Self.handler!(self.request)
                let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                if Self.simulateRedirect {
                    self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://untrusted.example/steal")!), redirectResponse: response)
                }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch { self.client?.urlProtocol(self, didFailWithError: error) }
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: work)
    }
    override func stopLoading() { pending?.cancel(); pending = nil }
}

final class DirectorProviderTests: XCTestCase {
    private var provider: DirectorProvider!
    private var session: URLSession!
    private let connection = DirectorConnection(model: "chosen-model")
    private let reply = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"summary\":\"Ready\"}"}}]}"#.utf8)

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectorStubProtocol.self]
        session = URLSession(configuration: config)
        provider = DirectorProvider(session: session)
        DirectorStubProtocol.delay = 0
        DirectorStubProtocol.simulateRedirect = false
    }
    override func tearDown() {
        session.invalidateAndCancel()
        DirectorStubProtocol.handler = nil
        super.tearDown()
    }

    private func stub(_ data: Data, status: Int = 200, headers: [String: String] = [:]) {
        DirectorStubProtocol.handler = { _ in (status, data, headers) }
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testConnectionValidation() throws {
        XCTAssertEqual(try connection.validatedEndpoint().absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(try DirectorConnection(kind: .anthropic, model: "mine", baseURL: "https://example.com/v1///").validatedEndpoint().path, "/v1/messages")
        for base in ["http://localhost:11434/v1", "http://127.0.0.1/v1", "http://[::1]/v1", "https://example.com/proxy/v1"] {
            XCTAssertNoThrow(try DirectorConnection(model: "mine", baseURL: base).validatedEndpoint())
        }
        for base in ["http://example.com/v1", "http://localhost.example.com", "http://127.0.0.2", "ftp://localhost", "https://key@example.com", "https://user:secret@example.com", "https://example.com?q=secret", "https://example.com#secret", "https://example.com:0", "https://example.com:99999", " https://example.com", String(repeating: "a", count: 2049)] {
            XCTAssertThrowsError(try DirectorConnection(model: "mine", baseURL: base).validatedEndpoint(), base)
        }
        for model in ["", " ", "has space", "line\nbreak", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try DirectorConnection(model: model).validatedEndpoint())
        }
    }

    func testOpenAIRequestUsesSelectedModelAndBoundedMultimodalContent() async throws {
        DirectorStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try self.body(request)
            XCTAssertEqual(body["model"] as? String, "chosen-model")
            XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
            XCTAssertNil(body["max_tokens"])
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages[0]["content"] as? String, "Return JSON.")
            let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
            XCTAssertEqual(content[0]["text"] as? String, "Make a draft")
            XCTAssertEqual(content[1]["text"] as? String, "First frame")
            XCTAssertEqual((content[2]["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64,AQID")
            return (200, self.reply, [:])
        }
        let text = try await provider.generate(connection: connection, apiKey: "synthetic-key", instructions: "Return JSON.", prompt: "Make a draft", images: [.init(label: "First frame", jpeg: Data([1, 2, 3]))])
        XCTAssertEqual(text, #"{"summary":"Ready"}"#)
    }

    func testOllamaCompatibleRequestNeedsNoKey() async throws {
        DirectorStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try self.body(request)
            XCTAssertEqual(body["max_tokens"] as? Int, 4096)
            XCTAssertNil(body["max_completion_tokens"])
            return (200, self.reply, [:])
        }
        _ = try await provider.generate(connection: .init(kind: .ollama, model: "my-local-model", baseURL: DirectorProviderKind.ollama.defaultBaseURL), apiKey: "", instructions: "JSON", prompt: "Edit")
    }

    func testAnthropicRequestAndTextBlocks() async throws {
        DirectorStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "synthetic-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try self.body(request)
            XCTAssertEqual(body["system"] as? String, "JSON only")
            XCTAssertEqual(body["model"] as? String, "chosen-anthropic-model")
            XCTAssertEqual(body["max_tokens"] as? Int, 4096)
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
            let source = try XCTUnwrap(content[2]["source"] as? [String: String])
            XCTAssertEqual(source, ["type": "base64", "media_type": "image/jpeg", "data": "AQID"])
            return (200, Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}"#.utf8), [:])
        }
        let text = try await provider.generate(connection: .init(kind: .anthropic, model: "chosen-anthropic-model", baseURL: DirectorProviderKind.anthropic.defaultBaseURL), apiKey: "synthetic-key", instructions: "JSON only", prompt: "Edit", images: [.init(label: "Frame", jpeg: Data([1, 2, 3]))])
        XCTAssertEqual(text, "first\nsecond")
    }

    func testErrorsNeverExposeProviderResponseOrCredentials() async throws {
        for (status, expected) in [(401, DirectorProviderError.credentials), (403, .credentials), (429, .rateLimit), (500, .httpStatus(500)), (302, .httpStatus(302))] {
            stub(Data("private-provider-message synthetic-key".utf8), status: status)
            do {
                _ = try await provider.generate(connection: connection, apiKey: "synthetic-key", instructions: "JSON", prompt: "Edit")
                XCTFail("Expected error")
            } catch {
                XCTAssertEqual(error as? DirectorProviderError, expected)
                XCTAssertFalse(error.localizedDescription.contains("synthetic-key"))
                XCTAssertFalse(error.localizedDescription.contains("private-provider-message"))
            }
        }
    }

    func testRedirectsAreRejectedBeforeCredentialsCanReachAnotherHost() async throws {
        DirectorStubProtocol.simulateRedirect = true
        var requests = 0
        DirectorStubProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "api.openai.com")
            return (302, Data(), ["Location": "https://untrusted.example/steal"])
        }
        do {
            _ = try await provider.generate(connection: connection, apiKey: "synthetic-key", instructions: "JSON", prompt: "Edit")
            XCTFail("Expected redirect rejection")
        } catch { XCTAssertEqual(error as? DirectorProviderError, .httpStatus(302)) }
        XCTAssertEqual(requests, 1)
    }

    func testRejectsMalformedEmptyRefusedAndTruncatedResponses() async throws {
        let fixtures: [(String, DirectorProviderError)] = [
            ("not JSON", .invalidResponse),
            (#"{"error":{"message":"private"}}"#, .invalidResponse),
            (#"{"choices":[]}"#, .invalidResponse),
            (#"{"choices":[{"finish_reason":"stop","message":{"content":" "}}]}"#, .invalidResponse),
            (#"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#, .incompleteResponse),
            (#"{"choices":[{"finish_reason":"stop","message":{"refusal":"no","content":""}}]}"#, .refused)
        ]
        for (fixture, expected) in fixtures {
            stub(Data(fixture.utf8))
            do {
                _ = try await provider.generate(connection: connection, apiKey: "", instructions: "JSON", prompt: "Edit")
                XCTFail("Expected error")
            } catch { XCTAssertEqual(error as? DirectorProviderError, expected) }
        }
        for (fixture, expected) in [
            (#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#, DirectorProviderError.incompleteResponse),
            (#"{"stop_reason":"end_turn","content":[]}"#, .invalidResponse),
            (#"{"stop_reason":"end_turn","content":[{"type":"refusal"}]}"#, .refused)
        ] {
            stub(Data(fixture.utf8))
            do {
                _ = try await provider.generate(connection: .init(kind: .anthropic, model: "mine"), apiKey: "", instructions: "JSON", prompt: "Edit")
                XCTFail("Expected error")
            } catch { XCTAssertEqual(error as? DirectorProviderError, expected) }
        }
    }

    func testLimitsInputAndResponseBeforeParsing() async throws {
        stub(Data(repeating: 32, count: 1_048_577))
        do {
            _ = try await provider.generate(connection: connection, apiKey: "", instructions: "JSON", prompt: "Edit")
            XCTFail("Expected size error")
        } catch { XCTAssertEqual(error as? DirectorProviderError, .responseTooLarge) }
        stub(reply, headers: ["Content-Length": "1048577"])
        do {
            _ = try await provider.generate(connection: connection, apiKey: "", instructions: "JSON", prompt: "Edit")
            XCTFail("Expected size error")
        } catch { XCTAssertEqual(error as? DirectorProviderError, .responseTooLarge) }
        for images in [[DirectorImage(label: "big", jpeg: Data(repeating: 0, count: 262_145))], Array(repeating: DirectorImage(label: "frame", jpeg: Data([1])), count: 7)] {
            do {
                _ = try await provider.generate(connection: connection, apiKey: "", instructions: "JSON", prompt: "Edit", images: images)
                XCTFail("Expected input error")
            } catch { XCTAssertEqual(error as? DirectorProviderError, .invalidInput) }
        }
        do {
            _ = try await provider.generate(connection: connection, apiKey: "", instructions: "JSON", prompt: String(repeating: "x", count: 200_001))
            XCTFail("Expected input error")
        } catch { XCTAssertEqual(error as? DirectorProviderError, .invalidInput) }
    }

    func testCancellationAndNetworkErrorsAreSanitized() async throws {
        stub(reply)
        DirectorStubProtocol.delay = 1
        let task = Task { try await provider.generate(connection: connection, apiKey: "", instructions: "JSON", prompt: "Edit") }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        DirectorStubProtocol.delay = 0
        DirectorStubProtocol.handler = { _ in throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "private endpoint synthetic-key"]) }
        do {
            _ = try await provider.generate(connection: connection, apiKey: "", instructions: "JSON", prompt: "Edit")
            XCTFail("Expected connection error")
        } catch { XCTAssertEqual(error as? DirectorProviderError, .connectionFailed) }
    }
}
