import Foundation
import Darwin
import AppKit
import os
import DragonKit

/// Runs the once-per-launch automatic snippet backup into the user-chosen backup
/// folder. A no-op until the user has picked a folder in the Sync/Backup pane.
@MainActor
enum BackupScheduler {
    private static let log = Logger(subsystem: "com.dragonapp.clipmenu-2", category: "backup")

    /// Whether automatic backup may run: the user has chosen a backup folder.
    static var isEligible: Bool {
        BackupFolder.isConfigured()
    }

    /// Build a manager bound to the live container + the user's backup folder, or
    /// nil when no folder is configured.
    static func makeManager() -> BackupManager? {
        guard let folder = BackupFolder.resolvedURL() else { return nil }
        return BackupManager(
            store: FolderBackupStore(folder: folder),
            context: AppStore.container.mainContext,
            deviceName: deviceName(),
            appVersion: AppInfo.version,
            didRestoreSettings: {
                refreshLanguage()
                MainMenuController.shared.registerAllMenuHotKeys()
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                SettingsSidecar.write(from: .standard, to: folder.appending(path: SettingsSidecar.fileName))
            })
    }

    static func deviceName() -> String {
        var name = [CChar](repeating: 0, count: 256)
        guard gethostname(&name, name.count) == 0 else { return "Mac" }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func refreshLanguage() {
        let raw = UserDefaults.standard.string(forKey: "DragonKit.language")
        LocalizationManager.shared.setLanguage(raw.flatMap(DragonLanguage.init(rawValue:)) ?? .system)
    }

    /// Fire-and-forget daily check; safe to call once at startup.
    static func runIfEligible() {
        guard let manager = makeManager() else { return }
        Task {
            // The local store is authoritative (no CloudKit import to wait for), so the
            // snapshot always reflects real data.
            do { try await manager.runDailyCheck(didSyncThisLaunch: true) }
            catch { log.error("daily backup check failed: \(String(describing: error))") }
        }
    }
}
