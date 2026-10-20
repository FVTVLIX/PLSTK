// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

public enum DirectorProviderKind: String, Codable, CaseIterable, Sendable {
    case openAICompatible, anthropic, ollama

    public var name: String {
        switch self {
        case .openAICompatible: return "OpenAI compatible"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .ollama: return "http://localhost:11434/v1"
        }
    }
}

public struct DirectorConnection: Codable, Equatable, Sendable {
    public var kind: DirectorProviderKind
    public var model: String
    public var baseURL: String

    public init(kind: DirectorProviderKind = .openAICompatible, model: String = "", baseURL: String = "https://api.openai.com/v1") {
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
    }

    public func validatedEndpoint() throws -> URL {
        guard !model.isEmpty, model.utf8.count <= 256,
              !model.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              baseURL.utf8.count <= 2048,
              let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              (components.port == nil || (1...65535).contains(components.port!)),
              !baseURL.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !baseURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DirectorProviderError.invalidConnection
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            throw DirectorProviderError.invalidConnection
        }
        var endpoint = components
        var path = endpoint.path
        while path.hasSuffix("/") { path.removeLast() }
        endpoint.path = path + (kind == .anthropic ? "/messages" : "/chat/completions")
        guard let url = endpoint.url else { throw DirectorProviderError.invalidConnection }
        return url
    }
}

public struct DirectorImage: Sendable {
    public let label: String
    public let jpeg: Data

    public init(label: String, jpeg: Data) {
        self.label = label
        self.jpeg = jpeg
    }
}

public enum DirectorProviderError: Error, LocalizedError, Equatable {
    case invalidConnection, invalidInput, credentials, rateLimit, httpStatus(Int)
    case invalidResponse, responseTooLarge, incompleteResponse, refused, connectionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConnection: return "Choose a model and a valid provider URL. Remote providers require HTTPS."
        case .invalidInput: return "The request is too large or contains unsupported input."
        case .credentials: return "The provider rejected the credentials. Check your API key and access."
        case .rateLimit: return "The provider reached a usage limit. Try again later or check your account."
        case .httpStatus(let status): return "The provider could not complete the request (HTTP \(status))."
        case .invalidResponse: return "The provider returned an unreadable response."
        case .responseTooLarge: return "The provider response exceeded the size limit."
        case .incompleteResponse: return "The provider stopped before completing the edit. Try a smaller request."
        case .refused: return "The provider declined this request."
        case .connectionFailed: return "Could not connect to the provider. Check the address and connection."
        }
    }
}

private final class DirectorRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class DirectorProvider {
    private let session: URLSession
    private let redirectBlocker = DirectorRedirectBlocker()
    private static let maximumResponseBytes = 1_048_576

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: configuration)
        }
    }

    public func generate(connection: DirectorConnection, apiKey: String, instructions: String, prompt: String,
                         images: [DirectorImage] = []) async throws -> String {
        let endpoint = try connection.validatedEndpoint()
        guard instructions.utf8.count + prompt.utf8.count <= 200_000,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiKey.utf8.count <= 8192,
              !apiKey.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              images.count <= 6,
              images.allSatisfy({ !$0.jpeg.isEmpty && $0.jpeg.count <= 262_144 && $0.label.utf8.count <= 1024 }) else {
            throw DirectorProviderError.invalidInput
        }
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any]
        if connection.kind == .anthropic {
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            for image in images {
                content.append(["type": "text", "text": image.label])
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.jpeg.base64EncodedString()]])
            }
            body = ["model": connection.model, "system": instructions, "max_tokens": 4096,
                    "messages": [["role": "user", "content": content]]]
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            for image in images {
                content.append(["type": "text", "text": image.label])
                content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.jpeg.base64EncodedString() ]])
            }
            body = ["model": connection.model, "response_format": ["type": "json_object"],
                    "messages": [["role": "system", "content": instructions], ["role": "user", "content": content]]]
            body[endpoint.host?.lowercased() == "api.openai.com" ? "max_completion_tokens" : "max_tokens"] = 4096
            if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectBlocker)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw DirectorProviderError.invalidResponse }
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw DirectorProviderError.credentials
            case 429: throw DirectorProviderError.rateLimit
            default: throw DirectorProviderError.httpStatus(http.statusCode)
            }
            guard response.expectedContentLength <= Self.maximumResponseBytes else { throw DirectorProviderError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else { throw DirectorProviderError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try Self.parse(data, kind: connection.kind)
        } catch is CancellationError { throw CancellationError() }
        catch let error as DirectorProviderError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw DirectorProviderError.connectionFailed }
    }

    private static func parse(_ data: Data, kind: DirectorProviderKind) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["error"] == nil else {
            throw DirectorProviderError.invalidResponse
        }
        let text: String
        if kind == .anthropic {
            guard let blocks = object["content"] as? [[String: Any]] else { throw DirectorProviderError.invalidResponse }
            if blocks.contains(where: { $0["type"] as? String == "refusal" }) { throw DirectorProviderError.refused }
            guard object["stop_reason"] as? String == "end_turn" else { throw DirectorProviderError.incompleteResponse }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first,
                  let message = choice["message"] as? [String: Any] else { throw DirectorProviderError.invalidResponse }
            if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw DirectorProviderError.refused }
            guard choice["finish_reason"] as? String == "stop" else { throw DirectorProviderError.incompleteResponse }
            guard let content = message["content"] as? String else { throw DirectorProviderError.invalidResponse }
            text = content
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DirectorProviderError.invalidResponse }
        return text
    }
}
