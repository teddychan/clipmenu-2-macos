import Foundation
import DragonKit

@MainActor
enum ClipMenuBackup {
    private static var mutationInProgress = false

    nonisolated static func migratedPaneID(_ saved: String) -> String {
        saved == "syncBackup" ? "backup" : saved
    }

    static var config: BackupConfig {
        BackupConfig(
            appName: AppInfo.displayName,
            suiteName: Bundle.main.bundleIdentifier ?? SettingsWindowController.releaseBundleID,
            appVersion: AppInfo.version,
            contents: [
                L("All settings, including language and shortcuts"),
                L("Snippets and folders"),
                L("Custom action choices"),
            ],
            operations: operations(),
            folderPathKey: PreferenceKeys.backupFolderPath,
            folderBookmarkKey: PreferenceKeys.backupFolderBookmark,
            restoreConfirmationMessage: L("This replaces all your current snippets and folders. Your current snippets are backed up first."),
            relaunch: {})
    }

    static func operations(
        makeManager: @escaping (URL) -> BackupManager = { BackupScheduler.makeManager(in: $0) },
        didBackUp: @escaping (URL) -> Void = { registerFolderAndWriteSidecar($0) }
    ) -> BackupOperations {
        BackupOperations(
            listBackups: { folder in
                try await makeManager(folder).listForUI(pruning: false).map { version in
                    BackupEntry(
                        url: folder.appending(path: version.recordName),
                        title: version.recordName,
                        detail: detail(version))
                }
            },
            backUp: { folder in
                try await mutate {
                    let result = try await makeManager(folder).backUpNow(kind: .manual)
                    didBackUp(folder)
                    if case .created = result { return true }
                    return false
                }
            },
            restore: { url, folder in
                try await mutate {
                    let manager = makeManager(folder)
                    let version = try await matchingVersion(url, in: folder, manager: manager)
                    do { try await manager.restore(version) }
                    catch let error as SyncBackupError {
                        let message: String
                        switch error {
                        case .preRestoreFailed:
                            message = L("Couldn't save a safety backup, so the restore was cancelled.")
                        case .unsupportedSchemaVersion:
                            message = L("This version was made on a newer app version and can't be restored.")
                        case .validationFailed:
                            message = L("Restore failed. Your current data was not changed.")
                        }
                        throw NSError(domain: "ClipMenuBackup", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message])
                    }
                }
            },
            delete: { url, folder in
                try await mutate {
                    let manager = makeManager(folder)
                    let version = try await matchingVersion(url, in: folder, manager: manager)
                    try await FolderBackupStore(folder: folder).delete(recordNames: [version.recordName])
                }
            })
    }

    private static func mutate<T>(_ operation: () async throws -> T) async throws -> T {
        guard !mutationInProgress else {
            throw NSError(domain: "ClipMenuBackup", code: 2, userInfo: [
                NSLocalizedDescriptionKey: L("A backup operation is already running. Please wait for it to finish."),
            ])
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        return try await operation()
    }

    static func registerDefaultFolderIfNeeded(defaults: UserDefaults = .standard) {
        guard BackupFolder.resolvedURL(defaults: defaults) == nil else { return }
        let folder = DragonBackup.defaultFolder(appName: AppInfo.displayName)
        defaults.set(folder.path(percentEncoded: false), forKey: PreferenceKeys.backupFolderPath)
    }

    private static func matchingVersion(
        _ url: URL, in folder: URL, manager: BackupManager
    ) async throws -> BackupVersionMeta {
        guard let version = try await manager.listForUI(pruning: false).first(where: {
            folder.appending(path: $0.recordName).standardizedFileURL == url.standardizedFileURL
        }) else { throw SyncBackupError.validationFailed }
        return version
    }

    static func registerFolderAndWriteSidecar(_ folder: URL, defaults: UserDefaults = .standard) {
        if BackupFolder.resolvedURL(defaults: defaults)?.standardizedFileURL != folder.standardizedFileURL {
            _ = BackupFolder.set(folder, defaults: defaults)
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        SettingsSidecar.write(from: defaults, to: folder.appending(path: SettingsSidecar.fileName))
    }

    private static func detail(_ version: BackupVersionMeta) -> String {
        let kind: String
        switch version.kind {
        case .auto: kind = L("Automatic")
        case .manual: kind = L("Manual")
        case .preRestore: kind = L("Before restore")
        }
        return [version.effectiveDate.formatted(date: .abbreviated, time: .shortened), kind,
                String(format: L("Folders: %d"), version.folderCount),
                String(format: L("Snippets: %d"), version.snippetCount),
                version.deviceName].joined(separator: " · ")
    }
}
