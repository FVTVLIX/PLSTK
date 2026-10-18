// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Darwin
import Foundation

/// A separate working copy. Saving it never touches the user's project or backup.
public struct RecoverySnapshot: Codable, Equatable {
    public var formatVersion = 1
    public var project: VideoProject
    public var originalFileURL: URL?
    public var updatedAt: Date

    public init(project: VideoProject, originalFileURL: URL?, updatedAt: Date = Date()) {
        self.project = project; self.originalFileURL = originalFileURL; self.updatedAt = updatedAt
    }

    fileprivate func validate() throws {
        guard formatVersion == 1, updatedAt.timeIntervalSince1970.isFinite,
              originalFileURL.map(\.isFileURL) ?? true,
              project.assets.allSatisfy({ $0.path.hasPrefix("/") }) else {
            throw EditorError("This recovery copy cannot be opened.")
        }
        // Missing media must not prevent recovering the edit and relinking later.
        try project.validate()
    }
}

/// Holds a lease until the user has recovered, discarded, or deferred this copy.
public final class RecoveryCandidate: Identifiable {
    public let id: UUID
    public let snapshot: RecoverySnapshot
    fileprivate let url: URL
    private let lease: Int32

    fileprivate init(id: UUID, snapshot: RecoverySnapshot, url: URL, lease: Int32) {
        self.id = id; self.snapshot = snapshot; self.url = url; self.lease = lease
    }
    deinit { close(lease) }
}

public struct RecoveryScan {
    public var candidates: [RecoveryCandidate]
    public var unreadableCount: Int
}

/// Call on one serial queue. Process leases keep active editors out of recovery scans.
public final class ProjectRecovery {
    public let directory: URL
    private let id = UUID()
    private let lease: Int32
    private let snapshotURL: URL
    private let lockURL: URL

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw EditorError("Recovery needs a local folder.") }
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        snapshotURL = self.directory.appendingPathComponent(id.uuidString + ".recovery")
        lockURL = self.directory.appendingPathComponent(id.uuidString + ".lock")
        guard let descriptor = try Self.lock(lockURL) else { throw EditorError("Could not start project recovery.") }
        lease = descriptor
    }

    deinit {
        close(lease)
        if !FileManager.default.fileExists(atPath: snapshotURL.path) { try? FileManager.default.removeItem(at: lockURL) }
    }

    public func write(_ snapshot: RecoverySnapshot) throws {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: snapshotURL.path) { try FileManager.default.removeItem(at: snapshotURL) }
    }

    public func scan() throws -> RecoveryScan {
        var candidates: [RecoveryCandidate] = [], unreadable = 0
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in urls where url.pathExtension == "recovery" {
            guard let candidateID = UUID(uuidString: url.deletingPathExtension().lastPathComponent), candidateID != id else { continue }
            guard let descriptor = try Self.lock(directory.appendingPathComponent(candidateID.uuidString + ".lock")) else { continue }
            do {
                let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: Data(contentsOf: url))
                try snapshot.validate()
                candidates.append(RecoveryCandidate(id: candidateID, snapshot: snapshot, url: url, lease: descriptor))
            } catch {
                close(descriptor)
                // A concurrent scanner may already have consumed this copy.
                if FileManager.default.fileExists(atPath: url.path) { unreadable += 1 }
            }
        }
        return RecoveryScan(candidates: candidates.sorted { $0.snapshot.updatedAt > $1.snapshot.updatedAt }, unreadableCount: unreadable)
    }

    public func discard(_ candidate: RecoveryCandidate) throws {
        guard candidate.url.deletingLastPathComponent().standardizedFileURL == directory else {
            throw EditorError("This recovery copy belongs to another folder.")
        }
        try FileManager.default.removeItem(at: candidate.url)
        // The candidate retains its lease until the caller releases it.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(candidate.id.uuidString + ".lock"))
    }

    private static func lock(_ url: URL) throws -> Int32? {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw EditorError("Could not access the recovery folder.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw EditorError("Could not protect the recovery copy.")
        }
        return descriptor
    }
}
