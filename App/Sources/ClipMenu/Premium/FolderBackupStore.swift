import Foundation

/// `BackupStore` backed by a user-chosen folder on disk. Each version is a single
/// `.clipbackup` binary-property-list file holding the snippet-snapshot payload
/// plus its metadata. The folder can live in Dropbox / iCloud Drive / Google
/// Drive, which then syncs backups across the user's Macs — no iCloud entitlement
/// required (it replaces the CloudKit-backed store).
///
/// Sendable value type (just a folder URL); the synchronous file I/O runs inside
/// the async protocol methods. When the folder was resolved from a security-scoped
/// bookmark (the sandboxed Mac App Store build), each operation brackets its I/O
/// with start/stopAccessingSecurityScopedResource; on the unsandboxed Developer ID
/// build that bracket is a harmless no-op.
struct FolderBackupStore: BackupStore {
    let folder: URL

    /// On-disk container format version (independent of the snippet snapshot schema).
    static let containerFormat = 1
    static let fileExtension = "clipbackup"

    private enum Key {
        static let format = "format"
        static let kind = "kind"
        static let clientDate = "clientDate"
        static let deviceName = "deviceName"
        static let appVersion = "appVersion"
        static let folderCount = "folderCount"
        static let snippetCount = "snippetCount"
        static let contentHash = "contentHash"
        static let snapshotSchemaVersion = "snapshotSchemaVersion"
        static let payload = "payload"
    }

    enum FolderBackupError: Error, Equatable {
        case notFound
        case malformed
    }

    // MARK: BackupStore

    func ensureZone() async throws {
        try withAccess {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    func list() async throws -> [BackupVersionMeta] {
        try withAccess {
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return []   // folder not created yet → genuinely no backups, not a failure
            }
            // Any other error (unreadable folder, stale bookmark, security-scope
            // denied) propagates so the UI can say "couldn't read" instead of
            // silently showing "no backups".
            return urls
                .filter { $0.pathExtension == Self.fileExtension }
                .compactMap { Self.readMeta(at: $0) }
        }
    }

    /// Count of items in the folder that are not ClipMenu backups — i.e. not a
    /// `.clipbackup` version or the settings sidecar (hidden files excluded). Lets
    /// the restore UI tell the user a non-empty folder holds no ClipMenu backups
    /// (e.g. it still has clipboard-history exports from an older app). Best-effort:
    /// returns 0 if the folder can't be read.
    func otherItemCount() async -> Int {
        withAccess {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return urls.filter {
                $0.pathExtension != Self.fileExtension
                    && $0.lastPathComponent != SettingsSidecar.fileName
            }.count
        }
    }

    func save(payload: Data, meta: BackupSaveMeta) async throws -> BackupVersionMeta {
        try withAccess {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let recordName = Self.fileName(date: meta.clientDate, kind: meta.kind)
            let dict: [String: Any] = [
                Key.format: Self.containerFormat,
                Key.kind: meta.kind.rawValue,
                Key.clientDate: meta.clientDate,
                Key.deviceName: meta.deviceName,
                Key.appVersion: meta.appVersion,
                Key.folderCount: meta.folderCount,
                Key.snippetCount: meta.snippetCount,
                Key.contentHash: meta.contentHash,
                Key.snapshotSchemaVersion: meta.schemaVersion,
                Key.payload: payload,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
            try data.write(to: folder.appending(path: recordName), options: .atomic)
            return BackupVersionMeta(
                recordName: recordName, kind: meta.kind, serverDate: nil, clientDate: meta.clientDate,
                folderCount: meta.folderCount, snippetCount: meta.snippetCount,
                contentHash: meta.contentHash, schemaVersion: meta.schemaVersion, deviceName: meta.deviceName)
        }
    }

    func fetchPayload(recordName: String) async throws -> Data {
        try withAccess {
            let url = folder.appending(path: recordName)
            guard let data = try? Data(contentsOf: url) else { throw FolderBackupError.notFound }
            guard
                let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                let payload = dict[Key.payload] as? Data
            else { throw FolderBackupError.malformed }
            return payload
        }
    }

    func delete(recordNames: [String]) async throws {
        try withAccess {
            for name in recordNames {
                try FileManager.default.removeItem(at: folder.appending(path: name))
            }
        }
    }

    // MARK: Helpers

    /// Filename: `ClipMenu-Backup-<yyyyMMdd-HHmmss>-<kind>.clipbackup` (sorts chronologically).
    static func fileName(date: Date, kind: BackupKind) -> String {
        "ClipMenu-Backup-\(timestamp(date))-\(kind.rawValue).\(fileExtension)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func readMeta(at url: URL) -> BackupVersionMeta? {
        guard
            let data = try? Data(contentsOf: url),
            let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
            let kindRaw = dict[Key.kind] as? String, let kind = BackupKind(rawValue: kindRaw),
            let clientDate = dict[Key.clientDate] as? Date
        else { return nil }
        return BackupVersionMeta(
            recordName: url.lastPathComponent, kind: kind, serverDate: nil, clientDate: clientDate,
            folderCount: dict[Key.folderCount] as? Int ?? 0,
            snippetCount: dict[Key.snippetCount] as? Int ?? 0,
            contentHash: dict[Key.contentHash] as? String ?? "",
            schemaVersion: dict[Key.snapshotSchemaVersion] as? Int ?? 0,
            deviceName: dict[Key.deviceName] as? String ?? "")
    }

    /// Bracket file I/O with security-scoped access (needed only for the sandboxed
    /// MAS build; a no-op for the unsandboxed Developer ID build / tests).
    private func withAccess<T>(_ body: () throws -> T) rethrows -> T {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
