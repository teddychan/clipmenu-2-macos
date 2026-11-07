import Testing
import Foundation
@testable import ClipMenu

// Folder-based backup backend that replaces CloudKit: versioned `.clipbackup`
// files, a settings sidecar, and the security-scoped folder bookmark.
@Suite struct FolderBackupStoreTests {
    private func tempFolder() -> URL {
        URL.temporaryDirectory.appending(path: "FolderBackupTest-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func meta(_ kind: BackupKind, date: Date, hash: String, folders: Int = 1, snippets: Int = 2) -> BackupSaveMeta {
        BackupSaveMeta(kind: kind, clientDate: date, deviceName: "TestMac", appVersion: "9.9.9",
                       folderCount: folders, snippetCount: snippets, contentHash: hash, schemaVersion: 1)
    }

    @Test func saveListFetchRoundTrip() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FolderBackupStore(folder: folder)
        try await store.ensureZone()

        let payload = Data("snapshot-bytes".utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = try await store.save(payload: payload, meta: meta(.manual, date: date, hash: "abc", folders: 3, snippets: 5))

        #expect(saved.kind == .manual)
        #expect(saved.contentHash == "abc")
        #expect(saved.folderCount == 3)
        #expect(saved.snippetCount == 5)
        #expect(saved.serverDate == nil)
        #expect(saved.clientDate == date)

        let listed = try await store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.recordName == saved.recordName)
        #expect(listed.first?.contentHash == "abc")

        let fetched = try await store.fetchPayload(recordName: saved.recordName)
        #expect(fetched == payload)
    }

    @Test func deleteRemovesVersions() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FolderBackupStore(folder: folder)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try await store.save(payload: Data([1]), meta: meta(.manual, date: base, hash: "a"))
        let b = try await store.save(payload: Data([2]), meta: meta(.auto, date: base.addingTimeInterval(60), hash: "b"))
        #expect(try await store.list().count == 2)

        try await store.delete(recordNames: [a.recordName])
        let remaining = try await store.list()
        #expect(remaining.count == 1)
        #expect(remaining.first?.recordName == b.recordName)
    }

    @Test func deleteReportsFileRemovalFailures() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FolderBackupStore(folder: folder)
        try await store.ensureZone()
        await #expect(throws: CocoaError.self) {
            try await store.delete(recordNames: ["missing.clipbackup"])
        }
    }

    @Test func listIgnoresNonBackupFiles() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FolderBackupStore(folder: folder)
        try await store.ensureZone()
        try Data("not a backup".utf8).write(to: folder.appending(path: "README.txt"))
        _ = try await store.save(payload: Data([1]), meta: meta(.manual, date: Date(timeIntervalSince1970: 1_700_000_000), hash: "h"))

        #expect(try await store.list().count == 1)
    }

    @Test func fetchMissingThrows() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FolderBackupStore(folder: folder)
        try await store.ensureZone()
        await #expect(throws: FolderBackupStore.FolderBackupError.notFound) {
            _ = try await store.fetchPayload(recordName: "missing.clipbackup")
        }
    }

    // A folder that hasn't been created yet is genuinely empty, not an error.
    @Test func listReturnsEmptyWhenFolderDoesNotExist() async throws {
        let folder = tempFolder()   // never created
        let store = FolderBackupStore(folder: folder)
        #expect(try await store.list().isEmpty)
    }

    // A folder that exists but can't be enumerated as a directory must surface an
    // error instead of silently reporting "no backups" (the bug: a stale bookmark
    // or unreadable synced folder looked identical to an empty one).
    @Test func listThrowsWhenPathIsNotADirectory() async throws {
        let path = URL.temporaryDirectory.appending(path: "FolderBackupNotDir-\(UUID().uuidString)")
        try Data("x".utf8).write(to: path)   // a regular file, not a directory
        defer { try? FileManager.default.removeItem(at: path) }
        let store = FolderBackupStore(folder: path)
        await #expect(throws: (any Error).self) {
            _ = try await store.list()
        }
    }

    // Tells the restore UI a non-empty folder holds no ClipMenu backups (e.g. it
    // still has exports from an older app). Excludes ClipMenu's own files.
    @Test func otherItemCountCountsOnlyForeignVisibleFiles() async throws {
        let folder = tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FolderBackupStore(folder: folder)
        try await store.ensureZone()
        _ = try await store.save(payload: Data([1]),
                                 meta: meta(.manual, date: Date(timeIntervalSince1970: 1_700_000_000), hash: "h"))
        try Data("settings".utf8).write(to: folder.appending(path: SettingsSidecar.fileName)) // ClipMenu's own
        try Data("<xml/>".utf8).write(to: folder.appending(path: "2019-05-21_MacBookPro.xml")) // foreign
        try Data("note".utf8).write(to: folder.appending(path: "README.txt"))                  // foreign

        #expect(await store.otherItemCount() == 2)
    }

    // MARK: Settings sidecar

    @Test func settingsSidecarRoundTripsWhitelistedKeysOnly() throws {
        let suiteSrc = "sidecar-src-\(UUID().uuidString)"
        let src = UserDefaults(suiteName: suiteSrc)!
        src.removePersistentDomain(forName: suiteSrc)
        src.set(33, forKey: PreferenceKeys.maxHistorySize)             // whitelisted
        src.set(true, forKey: PreferenceKeys.reorderClipsAfterPasting) // whitelisted
        src.set("secret", forKey: PreferenceKeys.backupFolderPath)     // NOT whitelisted

        let url = URL.temporaryDirectory.appending(path: "settings-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SettingsSidecar.write(from: src, to: url))

        let suiteDst = "sidecar-dst-\(UUID().uuidString)"
        let dst = UserDefaults(suiteName: suiteDst)!
        dst.removePersistentDomain(forName: suiteDst)
        #expect(SettingsSidecar.read(from: url, into: dst))

        #expect(dst.integer(forKey: PreferenceKeys.maxHistorySize) == 33)
        #expect(dst.bool(forKey: PreferenceKeys.reorderClipsAfterPasting) == true)
        // The non-whitelisted key never travels.
        #expect(dst.object(forKey: PreferenceKeys.backupFolderPath) == nil)
    }

    // MARK: Folder bookmark

    @Test func backupFolderBookmarkRoundTrip() throws {
        let suite = "backupfolder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let folder = tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(!BackupFolder.isConfigured(defaults: defaults))
        #expect(BackupFolder.set(folder, defaults: defaults))
        #expect(BackupFolder.isConfigured(defaults: defaults))
        #expect(BackupFolder.displayPath(defaults: defaults) == folder.path(percentEncoded: false))

        let resolved = BackupFolder.resolvedURL(defaults: defaults)
        #expect(resolved?.standardizedFileURL == folder.standardizedFileURL)
    }
}
