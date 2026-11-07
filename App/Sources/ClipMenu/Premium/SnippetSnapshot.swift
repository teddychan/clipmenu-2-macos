import Foundation
import SwiftData
import CryptoKit

/// A point-in-time, value-type snapshot of all snippets & folders, used for the
/// iCloud versioned backup feature. Pure and `Sendable`: captured from a
/// `ModelContext`, encoded canonically for a stable content hash, stored as a
/// CloudKit asset, and applied back to a `ModelContext` on restore.
struct SnippetSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var folders: [FolderDTO]
    /// Snippets with no folder (defensive: keeps "no data lost" true even for
    /// folder-less snippets that import paths can create).
    var orphanSnippets: [SnippetDTO]
    var settings: [String: Data]? = nil
    var actions: [ActionNode]? = nil

    struct FolderDTO: Codable, Sendable, Equatable {
        var title: String
        var index: Int
        var snippetSortRaw: Int
        var isExpanded: Bool
        var snippets: [SnippetDTO]
    }

    struct SnippetDTO: Codable, Sendable, Equatable {
        var title: String
        var content: String
        var index: Int
    }

    // MARK: Canonical encoding & hashing

    /// A deterministic byte representation: arrays are sorted by `index` then
    /// `title` so fetch order never affects the bytes, while `index`/`title`
    /// values are encoded (so reordering — which changes indices — changes the
    /// hash). JSON keys are sorted.
    func canonicalPayload() -> Data {
        var copy = self
        copy.folders = copy.folders
            .map { folder in
                var f = folder
                f.snippets = Self.sorted(f.snippets)
                return f
            }
            .sorted(by: Self.folderOrder)
        copy.orphanSnippets = Self.sorted(copy.orphanSnippets)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // All-primitive Codable DTOs: encoding cannot throw in practice. Using
        // try! makes a contract violation loud rather than silently returning an
        // empty payload (which would hash identically for different snapshots and
        // could skip a real backup). Backup is not a hot path, so this is safe.
        return try! encoder.encode(copy)
    }

    /// SHA-256 hex of the canonical payload — the change-detection fingerprint.
    var contentHash: String {
        Self.hexDigest(of: canonicalPayload())
    }

    /// Encode once and return both the canonical bytes and their SHA-256 — so a
    /// backup needn't encode twice (once to hash for change-detection, once for
    /// the upload). Callers run this off the main actor for large snippet sets.
    func canonicalPayloadAndHash() -> (payload: Data, hash: String) {
        let payload = canonicalPayload()
        return (payload, Self.hexDigest(of: payload))
    }

    private static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var folderCount: Int { folders.count }
    var snippetCount: Int { folders.reduce(orphanSnippets.count) { $0 + $1.snippets.count } }

    static func decode(_ data: Data) throws -> SnippetSnapshot {
        try JSONDecoder().decode(SnippetSnapshot.self, from: data)
    }

    private static func sorted(_ items: [SnippetDTO]) -> [SnippetDTO] {
        items.sorted { ($0.index, $0.title, $0.content) < ($1.index, $1.title, $1.content) }
    }
    private static func folderOrder(_ a: FolderDTO, _ b: FolderDTO) -> Bool {
        (a.index, a.title) < (b.index, b.title)
    }
}

extension SnippetSnapshot {

    /// Build a snapshot from the current snippet/folder graph.
    @MainActor
    static func capture(from context: ModelContext) throws -> SnippetSnapshot {
        let folders = try context.fetch(FetchDescriptor<Folder>())
        let folderDTOs = folders.map { folder in
            FolderDTO(
                title: folder.title,
                index: folder.index,
                snippetSortRaw: folder.snippetSortRaw,
                isExpanded: folder.isExpanded,
                snippets: (folder.snippets ?? []).map {
                    SnippetDTO(title: $0.title, content: $0.content, index: $0.index)
                })
        }
        let allSnippets = try context.fetch(FetchDescriptor<Snippet>())
        let orphanDTOs = allSnippets
            .filter { $0.folder == nil }
            .map { SnippetDTO(title: $0.title, content: $0.content, index: $0.index) }
        return SnippetSnapshot(
            schemaVersion: currentSchemaVersion, folders: folderDTOs, orphanSnippets: orphanDTOs)
    }

    /// Replace ALL folders & snippets with this snapshot's contents. Does NOT
    /// save — the caller controls the transaction so it can roll back on failure.
    @MainActor
    static func apply(_ snapshot: SnippetSnapshot, to context: ModelContext) throws {
        for snippet in try context.fetch(FetchDescriptor<Snippet>()) { context.delete(snippet) }
        for folder in try context.fetch(FetchDescriptor<Folder>()) { context.delete(folder) }

        for f in snapshot.folders {
            let folder = Folder(title: f.title, index: f.index)
            folder.snippetSortRaw = f.snippetSortRaw
            folder.isExpanded = f.isExpanded
            context.insert(folder)
            for s in f.snippets {
                context.insert(Snippet(title: s.title, content: s.content, index: s.index, folder: folder))
            }
        }
        for s in snapshot.orphanSnippets {
            context.insert(Snippet(title: s.title, content: s.content, index: s.index, folder: nil))
        }
    }
}
