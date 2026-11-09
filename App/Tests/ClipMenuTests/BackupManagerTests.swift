import Testing
import Foundation
import SwiftData
@testable import ClipMenu

/// In-memory BackupStore that records calls and can be told to fail.
actor MockBackupStore: BackupStore {
    struct Stored { var meta: BackupVersionMeta; var payload: Data }
    private(set) var versions: [Stored] = []
    private(set) var saveKinds: [BackupKind] = []
    private(set) var deleted: [String] = []
    private var failSaveForKind: BackupKind?
    private var counter = 0

    init(seed: [Stored] = []) { self.versions = seed }
    func setFailSave(_ kind: BackupKind?) { failSaveForKind = kind }

    func ensureZone() async throws {}

    func list() async throws -> [BackupVersionMeta] { versions.map(\.meta) }

    func save(payload: Data, meta: BackupSaveMeta) async throws -> BackupVersionMeta {
        saveKinds.append(meta.kind)
        if let f = failSaveForKind, f == meta.kind {
            struct Boom: Error {}; throw Boom()
        }
        counter += 1
        let v = BackupVersionMeta(
            recordName: "rec-\(counter)", kind: meta.kind,
            serverDate: meta.clientDate, clientDate: meta.clientDate,
            folderCount: meta.folderCount, snippetCount: meta.snippetCount,
            contentHash: meta.contentHash, schemaVersion: meta.schemaVersion,
            deviceName: meta.deviceName)
        versions.append(Stored(meta: v, payload: payload))
        return v
    }

    func fetchPayload(recordName: String) async throws -> Data {
        guard let s = versions.first(where: { $0.meta.recordName == recordName }) else {
            struct NotFound: Error {}; throw NotFound()
        }
        return s.payload
    }

    func delete(recordNames: [String]) async throws {
        deleted.append(contentsOf: recordNames)
        versions.removeAll { recordNames.contains($0.meta.recordName) }
    }
}

extension BackupSerialized {
@MainActor
@Suite struct BackupManagerTests {
    private let preferences = BackupTestDefaults()

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
        BackupManager(store: store, context: context, deviceName: "TestMac", appVersion: "9.9.9",
                      defaults: preferences.defaults, actionsURL: nil,
                      loginItemEnabled: { false }, setLoginItemEnabled: { _ in })
    }

    @Test func manualBackupCreatesVersion() async throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "A", snippet: "x")
        let store = MockBackupStore()
        let result = try await manager(store, ctx).backUpNow(kind: .manual)
        if case .created = result {} else { Issue.record("expected .created"); return }
        #expect(try await store.list().count == 1)
    }

    @Test func manualBackupSkipsWhenUnchanged() async throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "A", snippet: "x")
        let store = MockBackupStore()
        let m = manager(store, ctx)
        _ = try await m.backUpNow(kind: .manual)
        let second = try await m.backUpNow(kind: .manual)
        #expect(second == .noChanges)
        #expect(try await store.list().count == 1)
    }

    @Test func restoreSavesPreRestoreBeforeReplacing() async throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "A", snippet: "x")
        let store = MockBackupStore()
        let m = manager(store, ctx)
        guard case let .created(vA) = try await m.backUpNow(kind: .manual) else {
            Issue.record("setup backup failed"); return
        }
        for s in try ctx.fetch(FetchDescriptor<Snippet>()) { ctx.delete(s) }
        for f in try ctx.fetch(FetchDescriptor<Folder>()) { ctx.delete(f) }
        try seed(ctx, folderTitle: "B", snippet: "y")

        try await m.restore(vA)

        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        #expect(folders.count == 1 && folders.first?.title == "A")
        let kinds = await store.saveKinds
        #expect(kinds.contains(.preRestore))
    }

    @Test func restoreAbortsWhenPreRestoreUploadFails() async throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "A", snippet: "x")
        let store = MockBackupStore()
        let m = manager(store, ctx)
        guard case let .created(vA) = try await m.backUpNow(kind: .manual) else {
            Issue.record("setup backup failed"); return
        }
        for s in try ctx.fetch(FetchDescriptor<Snippet>()) { ctx.delete(s) }
        for f in try ctx.fetch(FetchDescriptor<Folder>()) { ctx.delete(f) }
        try seed(ctx, folderTitle: "B", snippet: "y")
        await store.setFailSave(.preRestore)

        await #expect(throws: SyncBackupError.preRestoreFailed) {
            try await m.restore(vA)
        }
        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        #expect(folders.first?.title == "B")
    }

    @Test func restoreRejectsNewerSchema() async throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "A", snippet: "x")
        let store = MockBackupStore()
        let m = manager(store, ctx)
        guard case let .created(v) = try await m.backUpNow(kind: .manual) else {
            Issue.record("setup backup failed"); return
        }
        let newer = BackupVersionMeta(
            recordName: v.recordName, kind: v.kind, serverDate: v.serverDate,
            clientDate: v.clientDate, folderCount: v.folderCount, snippetCount: v.snippetCount,
            contentHash: v.contentHash, schemaVersion: 999, deviceName: v.deviceName)
        await #expect(throws: SyncBackupError.self) { try await m.restore(newer) }
    }

    // P2c: a fresh/slow-syncing device must not push an empty backup as the newest
    // account-wide version when the CloudKit import is still pending this launch.
    @Test func dailyCheckSkipsEmptyStoreWhenNotSynced() async throws {
        let ctx = try makeContext()   // empty: no folders, no snippets
        let store = MockBackupStore()
        try await manager(store, ctx).runDailyCheck(didSyncThisLaunch: false)
        #expect(try await store.list().isEmpty)
    }

    @Test func dailyCheckBacksUpEmptyStoreOnceSynced() async throws {
        let ctx = try makeContext()   // genuinely empty AND synced this launch
        let store = MockBackupStore()
        try await manager(store, ctx).runDailyCheck(didSyncThisLaunch: true)
        #expect(try await store.list().count == 1)
    }

    @Test func dailyCheckBacksUpNonEmptyStoreEvenWithoutSync() async throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "A", snippet: "x")
        let store = MockBackupStore()
        try await manager(store, ctx).runDailyCheck(didSyncThisLaunch: false)
        #expect(try await store.list().count == 1)
    }

    @Test(arguments: [false, true])
    func dailyCheckIsSuppressedUntilAnotherManagerFinishesRestore(failing: Bool) async throws {
        let restoreStore = PausedRestoreStore()
        let restoreManager = manager(restoreStore, try makeContext())
        guard case let .created(version) = try await restoreManager.backUpNow(kind: .manual) else {
            Issue.record("Expected restore fixture backup")
            return
        }
        let scheduledStore = MockBackupStore()
        let scheduledManager = manager(scheduledStore, try makeContext())
        let restoring = Task { try await restoreManager.restore(version) }
        await restoreStore.waitUntilPaused()

        await #expect(throws: Never.self) {
            try await scheduledManager.runDailyCheck(didSyncThisLaunch: true)
        }
        #expect(await scheduledStore.versions.isEmpty)
        await restoreStore.resume(failing: failing)
        if failing {
            await #expect(throws: PausedRestoreStore.Failure.self) { try await restoring.value }
        } else {
            try await restoring.value
        }

        try await scheduledManager.runDailyCheck(didSyncThisLaunch: true)
        #expect(await scheduledStore.versions.count == 1)
    }

    @Test func applyWithRollbackRevertsOnSaveFailure() throws {
        let ctx = try makeContext(); try seed(ctx, folderTitle: "Original", snippet: "x")
        let replacement = SnippetSnapshot(
            schemaVersion: 1,
            folders: [.init(title: "Replacement", index: 0, snippetSortRaw: 0, isExpanded: true, snippets: [])],
            orphanSnippets: [])
        struct SaveBoom: Error {}
        #expect(throws: SaveBoom.self) {
            try BackupManager.applyWithRollback(replacement, to: ctx) { throw SaveBoom() }
        }
        let folders = try ctx.fetch(FetchDescriptor<Folder>())
        #expect(folders.count == 1 && folders.first?.title == "Original")
    }

    // A synced folder can already hold more than the retention limit (another Mac
    // wrote into it, or backups piled up while auto-backup was off). Listing for
    // the restore UI must reconcile it down to the quota — not only on the next
    // write — mirroring the Ice 2.8.3 prune-on-view fix.
    @Test func listForUIPrunesFolderOverRetentionLimit() async throws {
        let ctx = try makeContext()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var seeds: [MockBackupStore.Stored] = []
        for i in 0..<25 {                          // 25 > keepNormal (20)
            let date = base.addingTimeInterval(Double(i) * 60)
            let v = BackupVersionMeta(
                recordName: "rec-\(i)", kind: .auto, serverDate: date, clientDate: date,
                folderCount: 1, snippetCount: 1, contentHash: "h\(i)", schemaVersion: 1,
                deviceName: "Mac")
            seeds.append(MockBackupStore.Stored(meta: v, payload: Data([UInt8(i)])))
        }
        let store = MockBackupStore(seed: seeds)

        let listed = try await manager(store, ctx).listForUI()

        #expect(listed.count == BackupRetention.keepNormal)     // trimmed to 20
        #expect(listed.first?.recordName == "rec-24")           // newest first
        #expect(try await store.list().count == BackupRetention.keepNormal)
        #expect(await store.deleted.count == 5)                 // oldest 5 removed
    }
}
}

private actor PausedRestoreStore: BackupStore {
    enum Failure: Error { case requested }
    private let base = MockBackupStore()
    private var suspension: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var shouldFail = false

    func ensureZone() async throws {}
    func list() async throws -> [BackupVersionMeta] { try await base.list() }
    func save(payload: Data, meta: BackupSaveMeta) async throws -> BackupVersionMeta {
        try await base.save(payload: payload, meta: meta)
    }
    func delete(recordNames: [String]) async throws { try await base.delete(recordNames: recordNames) }

    func fetchPayload(recordName: String) async throws -> Data {
        await withCheckedContinuation { continuation in
            suspension = continuation
            waiter?.resume()
            waiter = nil
        }
        if shouldFail { throw Failure.requested }
        return try await base.fetchPayload(recordName: recordName)
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
}
