import Foundation
import SwiftData
import Testing
import DragonKit
@testable import ClipMenu

extension BackupSerialized {
@MainActor
@Suite
struct ClipMenuBackupPaneTests {
    @Test func savedLegacyPaneSelectionMigratesToSharedPane() {
        #expect(ClipMenuBackup.migratedPaneID("syncBackup") == "backup")
        #expect(ClipMenuBackup.migratedPaneID("menu") == "menu")
    }

    @Test func sharedPaneOperationsPreserveExistingBackupAndRestoreSafely() async throws {
        let folder = URL.temporaryDirectory.appending(path: "SharedBackup-\(UUID().uuidString)")
        let suite = "SharedBackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let container = try ModelContainer(
            for: Folder.self, Snippet.self, ClipRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = FolderBackupStore(folder: folder)
        let manager = BackupManager(
            store: store, context: context, deviceName: "Test", appVersion: "1.0.0",
            defaults: defaults, actionsURL: nil,
            loginItemEnabled: { false }, setLoginItemEnabled: { _ in })
        defaults.set("fr", forKey: "DragonKit.language")
        context.insert(Folder(title: "Original", index: 0))
        try context.save()
        guard case let .created(first) = try await manager.backUpNow(
            kind: .manual, now: Date(timeIntervalSince1970: 1_700_000_000)) else {
            Issue.record("Expected original backup")
            return
        }
        var completedBackups = 0
        let operations = ClipMenuBackup.operations(makeManager: { _ in manager }, didBackUp: { _ in
            completedBackups += 1
        })
        let originalEntries = try await operations.listBackups(folder)
        #expect(originalEntries.count == 1)
        #expect(originalEntries.first?.url.lastPathComponent == first.recordName)
        #expect(originalEntries.first?.detail?.contains("Test") == true)
        #expect(try await operations.backUp(folder) == false)
        defaults.set("ja", forKey: "DragonKit.language")
        #expect(try await operations.backUp(folder) == true)
        #expect(completedBackups == 2)
        let entries = try await operations.listBackups(folder)
        #expect(entries.count == 2)
        try await operations.restore(try #require(originalEntries.first).url, folder)
        #expect(defaults.string(forKey: "DragonKit.language") == "fr")
        #expect(try context.fetch(FetchDescriptor<Folder>()).map(\.title) == ["Original"])
        #expect(try await store.list().contains { $0.kind == .preRestore })
        let unrelated = folder.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try await operations.delete(try #require(entries.first).url, folder)
        #expect(!FileManager.default.fileExists(atPath: try #require(entries.first).url.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        await #expect(throws: SyncBackupError.validationFailed) {
            try await operations.delete(unrelated, folder)
        }
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func sameMinuteBackupsHaveDistinctFilenameTitles() async throws {
        let container = try ModelContainer(
            for: Folder.self, Snippet.self, ClipRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = MockBackupStore()
        let manager = BackupManager(store: store, context: ModelContext(container),
                                    deviceName: "Test", appVersion: "1.0.0")
        for second in 0...1 {
            _ = try await store.save(payload: Data(), meta: BackupSaveMeta(
                kind: .manual, clientDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(second)),
                deviceName: "Test", appVersion: "1.0.0", folderCount: 0, snippetCount: 0,
                contentHash: "hash", schemaVersion: 2))
        }
        let folder = URL(fileURLWithPath: "/tmp/title-test")
        let entries = try await ClipMenuBackup.operations(
            makeManager: { _ in manager }, didBackUp: { _ in }).listBackups(folder)
        #expect(Set(entries.map(\.title)).count == 2)
        #expect(entries.allSatisfy { $0.title == $0.url.lastPathComponent })
    }

    @Test func firstManualBackupRegistersDefaultFolderForAutomaticBackups() throws {
        let folder = URL.temporaryDirectory.appending(path: "RegisterBackup-\(UUID().uuidString)")
        let suite = "RegisterBackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ClipMenuBackup.registerFolderAndWriteSidecar(folder, defaults: defaults)
        #expect(BackupFolder.isConfigured(defaults: defaults))
        #expect(BackupFolder.resolvedURL(defaults: defaults)?.standardizedFileURL == folder.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: SettingsSidecar.fileName).path))
    }

    @Test func sharedPaneStoredPathWorksWithoutABookmark() throws {
        let suite = "BackupPathTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/tmp/shared-backup-folder", forKey: PreferenceKeys.backupFolderPath)
        defaults.set(Data(), forKey: PreferenceKeys.backupFolderBookmark)
        #expect(BackupFolder.resolvedURL(defaults: defaults)?.path == "/tmp/shared-backup-folder")
        #expect(BackupFolder.isConfigured(defaults: defaults))
    }
    @Test func openingPaneRegistersDefaultFolderWithoutReplacingAChosenFolder() throws {
        let suite = "DefaultBackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ClipMenuBackup.registerDefaultFolderIfNeeded(defaults: defaults)
        #expect(BackupFolder.isConfigured(defaults: defaults))
        #expect(BackupFolder.resolvedURL(defaults: defaults) == DragonBackup.defaultFolder(appName: AppInfo.displayName))
        defaults.set("/tmp/already-chosen-backups", forKey: PreferenceKeys.backupFolderPath)
        ClipMenuBackup.registerDefaultFolderIfNeeded(defaults: defaults)
        #expect(BackupFolder.resolvedURL(defaults: defaults)?.path == "/tmp/already-chosen-backups")
    }

    @Test(arguments: [false, true])
    func independentlyCreatedPanesRejectConcurrentMutationsAndReleaseGate(failing: Bool) async throws {
        let suite = "ConcurrentBackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(
            for: Folder.self, Snippet.self, ClipRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = PausingBackupStore()
        let manager = BackupManager(
            store: store, context: ModelContext(container), deviceName: "Test", appVersion: "1.0.0",
            defaults: defaults, actionsURL: nil, loginItemEnabled: { false }, setLoginItemEnabled: { _ in })
        let folder = URL(fileURLWithPath: "/tmp/controlled-backup")
        let first = ClipMenuBackup.operations(makeManager: { _ in manager }, didBackUp: { _ in })
        let operation = Task { try await first.backUp(folder) }
        await store.waitUntilPaused()
        let reopened = ClipMenuBackup.operations(makeManager: { _ in manager }, didBackUp: { _ in })
        for mutation in [
            { _ = try await reopened.backUp(folder) },
            { try await reopened.restore(folder.appending(path: "missing.clipbackup"), folder) },
            { try await reopened.delete(folder.appending(path: "missing.clipbackup"), folder) },
        ] {
            do {
                try await mutation()
                Issue.record("Concurrent mutation must be refused")
            } catch let error as NSError {
                #expect(error.domain == "ClipMenuBackup")
                #expect(error.code == 2)
            }
        }
        #expect(try await reopened.listBackups(folder).isEmpty)
        await store.resume(failing: failing)
        if failing {
            await #expect(throws: PausingBackupStore.Failure.self) { try await operation.value }
        } else {
            #expect(try await operation.value)
        }
        #expect(try await reopened.backUp(folder) == failing)
    }

}

}


private actor PausingBackupStore: BackupStore {
    enum Failure: Error { case requested }
    private let base = MockBackupStore()
    private var shouldPause = true
    private var suspension: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var shouldFail = false

    func ensureZone() async throws {
        guard shouldPause else { return }
        shouldPause = false
        await withCheckedContinuation { continuation in
            suspension = continuation
            waiter?.resume()
            waiter = nil
        }
        if shouldFail { throw Failure.requested }
    }

    func waitUntilPaused() async {
        guard suspension == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func resume(failing: Bool) {
        shouldFail = failing
        suspension?.resume()
        suspension = nil
    }

    func list() async throws -> [BackupVersionMeta] { try await base.list() }
    func save(payload: Data, meta: BackupSaveMeta) async throws -> BackupVersionMeta {
        try await base.save(payload: payload, meta: meta)
    }
    func fetchPayload(recordName: String) async throws -> Data { try await base.fetchPayload(recordName: recordName) }
    func delete(recordNames: [String]) async throws { try await base.delete(recordNames: recordNames) }
}
