import Testing
import Foundation
import SwiftData
@testable import ClipMenu

// Characterization tests closing the remaining coverage gaps in the backup &
// restore stack (BackupModels / BackupFolder / BackupManager / BackupScheduler).
// Every test asserts CURRENT behavior. New suite/file names; nothing here
// duplicates BackupModelsCoverageTests, BackupSchedulerCoverageTests,
// BackupManagerTests, BackupRetentionTests, or FolderBackupStoreTests.

// MARK: - BackupModels: protocol default

@Suite struct BackupModelsGapsTests {

    // The `BackupStore.otherItemCount()` protocol-extension default returns 0.
    // FolderBackupStore overrides it, so the default is only reached by a
    // conformer that omits it — MockBackupStore does exactly that.
    @Test func backupStoreDefaultOtherItemCountIsZero() async {
        let store: any BackupStore = MockBackupStore()
        #expect(await store.otherItemCount() == 0)
    }
}

// MARK: - BackupFolder: bookmark / path / preference edge branches
//
// Uses per-test custom UserDefaults(suiteName:) so it never touches
// UserDefaults.standard — hence no `.serialized` requirement.
@Suite struct BackupFolderGapsTests {

    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "backupfolder-gaps-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return (d, suite)
    }

    private func tempDir() throws -> URL {
        let dir = URL.temporaryDirectory.appending(
            path: "BackupFolderGaps-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // set() returns false when the bookmark can't be created (URL doesn't exist),
    // and leaves the defaults untouched.
    @Test func setReturnsFalseWhenBookmarkCannotBeCreated() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let missing = URL.temporaryDirectory.appending(path: "does-not-exist-\(UUID().uuidString)")
        #expect(BackupFolder.set(missing, defaults: defaults) == false)
        #expect(BackupFolder.isConfigured(defaults: defaults) == false)
        #expect(defaults.data(forKey: PreferenceKeys.backupFolderBookmark) == nil)
    }

    // resolvedURL() is nil when no bookmark has ever been stored.
    @Test func resolvedURLIsNilWhenUnconfigured() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BackupFolder.resolvedURL(defaults: defaults) == nil)
    }

    // resolvedURL() is nil when the stored bookmark bytes can't be resolved.
    @Test func resolvedURLIsNilWhenBookmarkDataIsGarbage() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([0x00, 0x01, 0x02, 0x03]), forKey: PreferenceKeys.backupFolderBookmark)
        #expect(BackupFolder.resolvedURL(defaults: defaults) == nil)
    }

    // displayPath() defaults to "" when nothing has been stored.
    @Test func displayPathDefaultsToEmpty() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BackupFolder.displayPath(defaults: defaults) == "")
    }

    // isConfigured() flips false→true as a bookmark is stored.
    @Test func isConfiguredReflectsStoredBookmark() throws {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(BackupFolder.isConfigured(defaults: defaults) == false)
        #expect(BackupFolder.set(dir, defaults: defaults))
        #expect(BackupFolder.isConfigured(defaults: defaults))
    }

    // automaticBackupEnabled() defaults to true, and honors an explicit value.
    @Test func automaticBackupEnabledDefaultsTrueAndHonorsStoredValue() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(BackupFolder.automaticBackupEnabled(defaults: defaults) == true)  // unset ⇒ true
        defaults.set(false, forKey: PreferenceKeys.automaticBackupEnabled)
        #expect(BackupFolder.automaticBackupEnabled(defaults: defaults) == false)
        defaults.set(true, forKey: PreferenceKeys.automaticBackupEnabled)
        #expect(BackupFolder.automaticBackupEnabled(defaults: defaults) == true)
    }
}

// MARK: - BackupManager: restore/backup edge branches

@MainActor
@Suite struct BackupManagerGapsTests {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Folder.self, Snippet.self, ClipRecord.self, configurations: config)
        return ModelContext(container)
    }

    private func seed(_ context: ModelContext, folderTitle: String, snippet: String) throws {
        let f = Folder(title: folderTitle, index: 0)
        context.insert(f)
        context.insert(Snippet(title: snippet, content: snippet, index: 0, folder: f))
        try context.save()
    }

    private func manager(_ store: BackupStore, _ context: ModelContext) -> BackupManager {
        BackupManager(store: store, context: context, deviceName: "TestMac", appVersion: "9.9.9")
    }

    private func meta(recordName: String, kind: BackupKind = .manual, schemaVersion: Int = 1,
                      date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                      hash: String) -> BackupVersionMeta {
        BackupVersionMeta(
            recordName: recordName, kind: kind, serverDate: date, clientDate: date,
            folderCount: 1, snippetCount: 1, contentHash: hash, schemaVersion: schemaVersion,
            deviceName: "Mac")
    }

    // Restore Phase A: a stored version whose payload can't be decoded surfaces
    // as .validationFailed (meta schema passes, the bytes don't).
    @Test func restoreThrowsValidationFailedOnUndecodablePayload() async throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "A", snippet: "x")
        let bad = meta(recordName: "bad.clipbackup", hash: "h")
        let store = MockBackupStore(seed: [.init(meta: bad, payload: Data("not-json".utf8))])

        await #expect(throws: SyncBackupError.validationFailed) {
            try await manager(store, ctx).restore(bad)
        }
        // Untouched: the local data is left exactly as it was.
        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        #expect(folders.count == 1 && folders.first?.title == "A")
    }

    // Restore Phase A: a payload that decodes but declares a schema newer than we
    // support is rejected even though the *meta* schema passed the first guard.
    @Test func restoreThrowsUnsupportedSchemaWhenDecodedSnapshotIsNewer() async throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "A", snippet: "x")
        let futureSnapshot = SnippetSnapshot(schemaVersion: 999, folders: [], orphanSnippets: [])
        let payload = try JSONEncoder().encode(futureSnapshot)
        // meta.schemaVersion == 1 clears the first guard; the decoded 999 trips the second.
        let m = meta(recordName: "future.clipbackup", schemaVersion: 1, hash: "h")
        let store = MockBackupStore(seed: [.init(meta: m, payload: payload)])

        await #expect(throws: SyncBackupError.unsupportedSchemaVersion(found: 999, supported: SnippetSnapshot.currentSchemaVersion)) {
            try await manager(store, ctx).restore(m)
        }
        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        #expect(folders.count == 1 && folders.first?.title == "A")
    }

    // NOTE: a backUpNow prune-after-save test was removed here — backUpNow calls
    // cacheBaseline(), which writes the SHARED UserDefaults.standard
    // lastSnippetBackupDate/Hash keys (not injectable). That raced the sibling
    // BackupManagerTests.dailyCheck* tests (Swift Testing runs suites in parallel)
    // and made them intermittently see a skip → count 0. backUpNow's save+prune is
    // already covered within BackupManagerTests' own (single) suite.

    // otherFolderItemCount forwards to the store; MockBackupStore uses the
    // protocol default (0).
    @Test func otherFolderItemCountForwardsStoreDefault() async throws {
        let ctx = try makeContext()
        let count = await manager(MockBackupStore(), ctx).otherFolderItemCount()
        #expect(count == 0)
    }
}

// NOTE: an earlier draft also exercised BackupScheduler.runIfEligible()'s eligible
// branch, but that spawns a fire-and-forget Task running runDailyCheck against the
// live AppStore.container and mutates the shared lastSnippetBackup* UserDefaults
// keys — which raced BackupManagerTests (sibling suites run in parallel) and made
// dailyCheckBacksUpEmptyStoreOnceSynced flaky. Its async result was never asserted,
// so it was removed. runIfEligible()'s synchronous guard/eligibility is covered by
// BackupSchedulerCoverageTests; runDailyCheck itself by BackupManagerTests.
