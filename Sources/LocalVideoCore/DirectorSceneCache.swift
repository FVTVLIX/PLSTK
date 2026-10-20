// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import Foundation

/// Private, bounded session memory. File identity and exact provider/model prevent stale reuse.
public struct DirectorSceneCache {
    private struct Key: Hashable {
        let source: MediaVisualSource
        let assetID: UUID
        let provider: String
        let model: String
        let frames: [Int64]
    }
    private struct Entry { let key: Key; let observation: DirectorObservation }
    private var entries: [Entry] = []
    public init() {}
    public var count: Int { entries.count }
    public mutating func clear() { entries.removeAll() }
    public mutating func remember(_ notes: [DirectorObservation], project: VideoProject, connection: DirectorConnection, supplied: [UUID: Set<Int64>], sources: [UUID: MediaVisualSource]) throws {
        try project.validate()
        guard notes.count <= 6 else { throw EditorError("Return at most six visual observations.") }
        let provider = connection.kind.rawValue + ":" + (try connection.validatedEndpoint().absoluteString)
        // Even a plan without new notes must not rely on samples from a changed source.
        for (id, source) in sources {
            guard let asset = project.assets.first(where: { $0.id == id }), try MediaVisualSource(asset) == source else {
                throw EditorError("Source media changed since these samples were prepared. Request fresh inspection.")
            }
        }
        var additions: [Entry] = []
        for note in notes {
            try note.validate()
            guard let allowed = supplied[note.assetID], Set(note.frames).isSubset(of: allowed),
                  let asset = project.assets.first(where: { $0.id == note.assetID }), !asset.isAudioOnly else {
                throw EditorError("A visual observation referenced source frames that were not supplied.")
            }
            guard note.frames.allSatisfy({ asset.isImage ? $0 == 0 : $0 < Int64(floor(asset.duration * 30)) }) else { throw EditorError("An observation is outside its source media.") }
            let source = try MediaVisualSource(asset)
            guard sources[asset.id] == source else { throw EditorError("Source media changed since these samples were prepared.") }
            let key = Key(source: source, assetID: asset.id, provider: provider, model: connection.model, frames: note.frames.sorted())
            additions.append(Entry(key: key, observation: note))
        }
        // An invalid note cannot partially change the cache.
        for entry in additions { entries.removeAll { $0.key == entry.key }; entries.append(entry) }
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
    }
    public mutating func observations(project: VideoProject, connection: DirectorConnection) throws -> [DirectorObservation] {
        try project.validate()
        let provider = connection.kind.rawValue + ":" + (try connection.validatedEndpoint().absoluteString)
        let identities = Dictionary(uniqueKeysWithValues: project.assets.compactMap { asset -> (UUID, MediaVisualSource)? in
            guard let source = try? MediaVisualSource(asset) else { return nil }; return (asset.id, source)
        })
        entries.removeAll { identities[$0.key.assetID] != $0.key.source }
        return entries.filter { $0.key.provider == provider && $0.key.model == connection.model }.map(\.observation)
    }
    public mutating func context(project: VideoProject, connection: DirectorConnection) throws -> String {
        let notes = try observations(project: project, connection: connection)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var included: [DirectorObservation] = []
        for note in notes.reversed() {
            let next = included + [note]
            if try encoder.encode(next).count <= 8000 { included = next }
        }
        return String(decoding: try encoder.encode(included), as: UTF8.self)
    }
}
