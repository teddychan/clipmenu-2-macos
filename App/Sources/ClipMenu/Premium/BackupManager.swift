import Foundation
import SwiftData
import DragonKit

/// Coordinates snippet backups against a `BackupStore`. `@MainActor` because it
/// reads/writes the `ModelContext`; CloudKit work happens on the store's actor.
@MainActor
final class BackupManager {
    private let store: BackupStore
    private let context: ModelContext
    private let deviceName: String
    private let appVersion: String
    private let defaults: UserDefaults
    private let actionsURL: URL?
    private let loginItemEnabled: () -> Bool
    private let setLoginItemEnabled: (Bool) -> Void
    private let didRestoreSettings: () -> Void

    /// True while a restore is replacing data. Shared across every
    /// `BackupManager` instance (the scheduler and the restore sheet each build
    /// their own) so the scheduler's auto-backup can never run mid-restore.
    /// Main-actor-isolated, so all access is serialized.
    private static var isRestoring = false

    init(
        store: BackupStore, context: ModelContext, deviceName: String, appVersion: String,
        defaults: UserDefaults = .standard, actionsURL: URL? = ActionStore.saveURL,
        loginItemEnabled: @escaping () -> Bool = { LoginItem.isEnabled },
        setLoginItemEnabled: @escaping (Bool) -> Void = { LoginItem.setEnabled($0) },
        didRestoreSettings: @escaping () -> Void = {}
    ) {
        self.store = store
        self.context = context
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.defaults = defaults
        self.actionsURL = actionsURL
        self.loginItemEnabled = loginItemEnabled
        self.setLoginItemEnabled = setLoginItemEnabled
        self.didRestoreSettings = didRestoreSettings
    }

    private func captureSnapshot() throws -> SnippetSnapshot {
        var snapshot = try SnippetSnapshot.capture(from: context)
        var settings = try SettingsSidecar.capture(from: defaults)
        settings[PreferenceKeys.loginItem] = try PropertyListSerialization.data(
            fromPropertyList: ["value": loginItemEnabled()], format: .xml, options: 0)
        snapshot.settings = settings
        if let actionsURL, FileManager.default.fileExists(atPath: actionsURL.path) {
            snapshot.actions = try PropertyListDecoder().decode(
                [ActionNode].self, from: Data(contentsOf: actionsURL))
        } else {
            snapshot.actions = ActionStore.defaultNodes()
        }
        return snapshot
    }

    // MARK: Backup

    /// Create a version of the current snippets/folders. With `force` (used for
    /// pre-restore safety snapshots) it always saves; otherwise it skips when the
    /// content is unchanged since the newest backup.
    @discardableResult
    func backUpNow(kind: BackupKind, force: Bool = false, now: Date = Date()) async throws -> BackupResult {
        try await store.ensureZone()
        let snapshot = try captureSnapshot()
        // Encode + hash once, off the main actor (snapshot is Sendable). The bytes
        // and hash are reused for change detection, the saved metadata, and the
        // uploaded payload — so a large snippet set is serialized only once.
        let (payload, hash) = await Task.detached { snapshot.canonicalPayloadAndHash() }.value

        if !force {
            let newest = BackupRetention.newestNormal(try await store.list())
            guard BackupRetention.hasChanges(newest: newest, currentHash: hash) else {
                return .noChanges
            }
        }

        let meta = BackupSaveMeta(
            kind: kind, clientDate: now, deviceName: deviceName, appVersion: appVersion,
            folderCount: snapshot.folderCount, snippetCount: snapshot.snippetCount,
            contentHash: hash, schemaVersion: snapshot.schemaVersion)
        let created = try await store.save(payload: payload, meta: meta)

        let pruneTargets = BackupRetention.recordsToPrune(try await store.list())
        if !pruneTargets.isEmpty { try? await store.delete(recordNames: pruneTargets) }
        cacheBaseline(date: now, hash: hash)
        return .created(created)
    }

    /// On-launch daily check: back up only if changed AND >=24h since the newest.
    /// `didSyncThisLaunch` reports whether a CloudKit import/export actually
    /// completed this launch (vs. the scheduler's timeout fallback).
    func runDailyCheck(now: Date = Date(), didSyncThisLaunch: Bool) async throws {
        guard !Self.isRestoring else { return }
        try await store.ensureZone()
        let snapshot = try captureSnapshot()
        // Never snapshot an empty local store that hasn't synced yet this launch:
        // on a fresh or slow-syncing device the CloudKit import may still be
        // pending, and uploading that empty state would make it the newest
        // account-wide version. Backing up a genuinely-empty store is pointless
        // anyway, so the only case skipped is the dangerous "empty because import
        // is pending" one.
        if snapshot.folderCount == 0, snapshot.snippetCount == 0, !didSyncThisLaunch { return }
        let newest = BackupRetention.newestNormal(try await store.list())
        guard BackupRetention.shouldAutoBackUp(
            now: now, newest: newest, currentHash: snapshot.contentHash) else { return }
        try await backUpNow(kind: .auto, now: now)
    }

    /// Versions newest-first for the restore UI. Also reconciles the folder down to
    /// the retention quota: a synced folder can already exceed it (another Mac wrote
    /// into it, or backups piled up while auto-backup was off), and pruning otherwise
    /// only happens after a new write. Best-effort — a failed prune still lists.
    func listForUI(pruning: Bool = true) async throws -> [BackupVersionMeta] {
        let all = try await store.list()
        let toPrune = pruning ? Set(BackupRetention.recordsToPrune(all)) : []
        if !toPrune.isEmpty { try? await store.delete(recordNames: Array(toPrune)) }
        return all
            .filter { !toPrune.contains($0.recordName) }
            .sorted { $0.effectiveDate > $1.effectiveDate }
    }

    /// Count of files in the backup folder that aren't ClipMenu backups — used by
    /// the restore UI to explain an empty list when the folder isn't actually empty.
    func otherFolderItemCount() async -> Int { await store.otherItemCount() }

    // MARK: Restore (two-phase, rollback-safe)

    func restore(_ version: BackupVersionMeta) async throws {
        guard version.schemaVersion <= SnippetSnapshot.currentSchemaVersion else {
            throw SyncBackupError.unsupportedSchemaVersion(
                found: version.schemaVersion, supported: SnippetSnapshot.currentSchemaVersion)
        }
        Self.isRestoring = true
        defer { Self.isRestoring = false }

        // Phase A — validate target (no mutation yet).
        let payload = try await store.fetchPayload(recordName: version.recordName)
        let snapshot: SnippetSnapshot
        do { snapshot = try SnippetSnapshot.decode(payload) }
        catch { throw SyncBackupError.validationFailed }
        guard snapshot.schemaVersion <= SnippetSnapshot.currentSchemaVersion else {
            throw SyncBackupError.unsupportedSchemaVersion(
                found: snapshot.schemaVersion, supported: SnippetSnapshot.currentSchemaVersion)
        }

        let settings: [String: Any]?
        do { settings = try snapshot.settings.map(SettingsSidecar.decoded) }
        catch { throw SyncBackupError.validationFailed }
        let actionData = try snapshot.actions.map { try PropertyListEncoder().encode($0) }
        let previousActions = try actionsURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        }

        // Phase B — snapshot current state and confirm it persisted.
        do { try await backUpNow(kind: .preRestore, force: true) }
        catch { throw SyncBackupError.preRestoreFailed }

        // Phase C — replace, rolling back if the save fails.
        if let actionData, let actionsURL {
            try FileManager.default.createDirectory(
                at: actionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actionData.write(to: actionsURL, options: .atomic)
        }
        do {
            try BackupManager.applyWithRollback(snapshot, to: context) { try self.context.save() }
        } catch {
            if actionData != nil, let actionsURL {
                if let previousActions { try previousActions.write(to: actionsURL, options: .atomic) }
                else { try FileManager.default.removeItem(at: actionsURL) }
            }
            throw error
        }
        if let settings {
            SettingsSidecar.apply(settings, to: defaults)
            if let enabled = settings[PreferenceKeys.loginItem] as? Bool { setLoginItemEnabled(enabled) }
            didRestoreSettings()
        }
    }

    /// Apply a snapshot then run `save`; on failure, roll the context back so the
    /// app is left exactly as it was. Static + injectable `save` for testability.
    static func applyWithRollback(
        _ snapshot: SnippetSnapshot, to context: ModelContext, save: () throws -> Void
    ) throws {
        try SnippetSnapshot.apply(snapshot, to: context)
        do { try save() }
        catch { context.rollback(); throw error }
    }

    // MARK: Local cache (offline fallback only — CloudKit is the source of truth)

    private func cacheBaseline(date: Date, hash: String) {
        defaults.set(date, forKey: PreferenceKeys.lastSnippetBackupDate)
        defaults.set(hash, forKey: PreferenceKeys.lastSnippetBackupHash)
    }
}
