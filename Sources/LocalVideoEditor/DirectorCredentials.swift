// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import CryptoKit
import Foundation
import LocalVideoCore
import Security

protocol DirectorSecretStore {
    func read(_ connection: DirectorConnection) throws -> String
    func write(_ key: String, for connection: DirectorConnection) throws
}

/// Credentials belong to this app and exact endpoint, never a project or provider response.
struct DirectorKeychain: DirectorSecretStore {
    private let service = (Bundle.main.bundleIdentifier ?? "studio.localvideo.editor") + ".director"
    private func query(_ connection: DirectorConnection) throws -> [String: Any] {
        let endpoint = try connection.validatedEndpoint().absoluteString
        let digest = SHA256.hash(data: Data((connection.kind.rawValue + ":" + endpoint).utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: digest, kSecAttrSynchronizable as String: false]
    }
    func read(_ connection: DirectorConnection) throws -> String {
        var request = try query(connection)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let bytes = result as? Data, let key = String(data: bytes, encoding: .utf8) else {
            throw EditorError("The model credential could not be read from Keychain.")
        }
        return key
    }
    func write(_ key: String, for connection: DirectorConnection) throws {
        let request = try query(connection)
        if key.isEmpty {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw EditorError("The model credential could not be removed from Keychain.") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw EditorError("The model credential could not be saved in Keychain.") }
    }
}
