import SwiftUI
import SwiftData
import AppKit
import DragonKit

// App entry. Agent / menu-bar app: no Dock icon, no main window — only a
// status-bar item (AppKit) plus a SwiftUI Settings scene. LSUIElement is set
// in Resources/Info.plist for the bundled .app; at runtime we also force
// .accessory activation so `swift run` behaves as an agent.

@main
struct ClipMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Vestigial: an LSUIElement agent can't open the SwiftUI Settings scene
        // (no main-menu responder). The real Settings window is DragonKit's
        // `DragonSettingsWindowController` (see SettingsWindowController.swift).
        Settings {
            EmptyView()
        }
    }
}

/// Process-wide SwiftData container, shared by the SwiftUI scene and the AppKit
/// menu layer. Two configurations under one container, each in its own file:
/// Snippets (`Folder`/`Snippet`) and History (`ClipRecord`/`ClipImage`). Both are
/// fully local — snippets are protected by folder-based backups (FolderBackupStore
/// + the Sync/Backup pane), and history is a regenerable cache; no CloudKit.
@MainActor
enum AppStore {
    /// Application Support directory holding the SwiftData stores. A local debug
    /// build (bundle id `…clipmenu-2.debug`, from scripts/run-debug.sh) uses a
    /// SEPARATE "ClipMenu Debug" folder so it never reads, pollutes, or (on
    /// Uninstall) deletes the installed release's clipboard history + snippets.
    ///
    /// `nonisolated` because it is the app's single support-folder constant and
    /// `ActionStore` (which is not MainActor-isolated) has to build actions.plist's
    /// path from it — an immutable `Sendable` value, so there is nothing to race.
    nonisolated static let folder: URL = {
        let isDebug = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".debug")
        return URL.applicationSupportDirectory.appending(
            path: isDebug ? "ClipMenu Debug" : "ClipMenu", directoryHint: .isDirectory)
    }()

    static let container: ModelContainer = makeContainer()

    private static func makeContainer() -> ModelContainer {
        let folder = Self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snippetsURL = folder.appending(path: "ClipMenu-Snippets.store")
        let historyURL = folder.appending(path: "ClipMenu-History.store")

        let snippetSchema = Schema([Folder.self, Snippet.self])
        let historySchema = Schema([ClipRecord.self, ClipImage.self])

        // Both stores are local. Snippets are protected by folder-based backups
        // (FolderBackupStore + the Sync/Backup pane), not CloudKit mirroring;
        // history is a regenerable cache.
        func make() throws -> ModelContainer {
            let snippetsConfig = ModelConfiguration(
                "Snippets", schema: snippetSchema, url: snippetsURL, cloudKitDatabase: .none)
            let historyConfig = ModelConfiguration(
                "History", schema: historySchema, url: historyURL, cloudKitDatabase: .none)
            return try ModelContainer(
                for: Folder.self, Snippet.self, ClipRecord.self, ClipImage.self,
                configurations: snippetsConfig, historyConfig)
        }

        // Add ClipRecord's #Index indexes to a pre-existing history store — SwiftData
        // creates them on fresh stores but not on ones migrated up to the indexed
        // schema (v2.17.7). Best-effort, before the store opens; a no-op on fresh
        // installs and where the indexes already exist.
        HistoryIndexRepair.ensureIndexes(at: historyURL)

        do {
            return try make()
        } catch {
            // The split stores are regenerable (snippets restore from a backup,
            // history is a cache). If the on-disk schema is incompatible, reset ONLY
            // the new files — never the old combined ClipMenu.store (migration backup).
            NSLog("ClipMenu: resetting incompatible split stores (\(error))")
            for base in ["ClipMenu-Snippets.store", "ClipMenu-History.store"] {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: folder.appending(path: base + suffix))
                }
            }
            do { return try make() }
            catch { fatalError("Failed to create ModelContainer: \(error)") }
        }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItemController = StatusItemController()
    private let mainMenuController = MainMenuController.shared
    private let pasteboardMonitor = PasteboardMonitor()
    private var clipStore: ClipStore?
    private var servicesStarted = false
    /// First-run setup wizard window controller, retained while it's on screen.
    private var onboardingController: OnboardingWindowController?
    /// True once `applicationWillTerminate` fires (incl. a relaunch). The wizard
    /// reads this so a relaunch close doesn't mark onboarding complete.
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon (mirrors legacy LSUIElement, Info.plist:40-41).
        NSApp.setActivationPolicy(.accessory)

        // DragonKit localization: the app's Localizable.strings live in the SwiftPM
        // resource bundle, and the language choice is owned by LocalizationManager
        // (switches live — no relaunch). One-time migration: carry the legacy
        // "appLanguage" choice into DragonKit's key, defaulting to English (the
        // historical hard default) rather than .system so existing installs keep
        // their language. Mirror the choice to AppleLanguages so system-provided
        // UI (save/open panels) matches from the next launch.
        LocalizationManager.shared.appStringsBundle = AppResources.bundle
        if UserDefaults.standard.string(forKey: "DragonKit.language") == nil {
            let legacy = UserDefaults.standard.string(forKey: PreferenceKeys.appLanguage) ?? "en"
            LocalizationManager.shared.setLanguage(DragonLanguage(rawValue: legacy) ?? .en)
        }
        mirrorAppleLanguages(LocalizationManager.shared.language)
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged(_:)),
            name: .dragonLanguageChanged, object: nil)

        // Start Sparkle's auto-updater (direct / Developer ID build only). No-op in
        // the Mac App Store build, where Sparkle is not compiled in and the App Store
        // delivers updates.
        UpdaterUI.start()

        startAppServices()
    }

    /// Bring up the app's actual functionality (status item, hot-keys, clipboard
    /// capture, menus). Runs once, after the access gate is satisfied.
    private func startAppServices() {
        guard !servicesStarted else { return }
        servicesStarted = true

        // One-time: migrate the pre-2.3 combined store into the split snippet/history
        // stores. Accessing AppStore.container builds the (empty) new stores first.
        StoreMigration.migrateIfNeeded(
            oldStoreURL: AppStore.folder.appending(path: "ClipMenu.store"),
            into: AppStore.container.mainContext)

        // Folder-based settings sync: if a backup folder is configured, pull the
        // settings sidecar so changes made on the user's other Macs apply this launch
        // (the folder syncs via Dropbox / iCloud Drive / Google Drive).
        if let backupFolder = BackupFolder.resolvedURL() {
            let scoped = backupFolder.startAccessingSecurityScopedResource()
            SettingsSidecar.read(from: backupFolder.appending(path: SettingsSidecar.fileName), into: .standard)
            if scoped { backupFolder.stopAccessingSecurityScopedResource() }
        }

        // Status-bar item shows the Main menu (MenuController.m:1314). Honor
        // showStatusItem: 0 = none — still reachable via the Main-menu
        // hot-key. Applied at launch (live toggle deferred).
        if UserDefaults.standard.object(forKey: PreferenceKeys.showStatusItem) as? Int ?? 1 != 0 {
            statusItemController.install(menu: mainMenuController.buildMainMenu())
        }

        // Global hot-keys → pop up the matching menu at the cursor, from stored
        // or default combos (AppController.m:601-633): ⌘⇧V Main, ⌘⌃V History,
        // ⌘⇧B Snippets. Rebindable live via the Shortcuts preferences pane.
        mainMenuController.registerAllMenuHotKeys()

        // Clipboard capture: poll changeCount, read snapshots on the main actor,
        // persist ClipRecords off it via the ClipStore actor (ClipsController.m).
        // One-time best-effort import of a legacy Snippets.xml.
        LegacySnippetImport.runOnceIfNeeded()

        // Load the action tree (creates the default actions.plist on first run,
        // mirroring loadActions at launch — AppController.m:292-349).
        _ = ActionStore.load()

        let store = ClipStore(modelContainer: AppStore.container)
        clipStore = store
        Task { await pasteboardMonitor.start(clipStore: store) }
        // One-time: give pre-existing image clips their display thumbnail so the
        // menu shows a picture without faulting the full image
        // (design-invariants.md — Images and memory).
        Task { await store.backfillThumbnails() }
        Task { await store.removeEmptyClips() }

        // An Edit menu so window-level Undo/Redo (and standard text editing)
        // work in the editor/settings windows (§G undo, row 138). LSUIElement
        // apps get no menu by default; legacy had MainMenu.xib.
        installMainMenu()

        // First run: show the setup wizard (which now owns the "Launch at login"
        // choice, superseding the legacy login-item alert). Shown once per install
        // and resumes on the saved step after a relaunch. The main menu is already
        // installed above, so ⌘C/⌘V work in the wizard's fields. Existing users who
        // finished the wizard fall through to the legacy prompt, which is a no-op
        // for them (the wizard set `suppressAlertForLoginItem`).
        if OnboardingGate.shouldShowOnLaunch(
            completed: UserDefaults.standard.bool(forKey: PreferenceKeys.onboardingCompleted)) {
            showOnboarding()
        } else {
            maybePromptToAddLoginItem()
        }

        BackupScheduler.runIfEligible()
    }

    /// Mirror the in-app language choice to the OS-level override so
    /// system-provided UI (save/open panels, standard menu items) matches after
    /// the next launch. `.system` clears the override.
    private func mirrorAppleLanguages(_ language: DragonLanguage) {
        if let code = language.localeCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Language switched (DragonKit LanguagePicker): SwiftUI re-localizes itself
    /// via `.dragonLocalized()`, but AppKit menus hold copied titles — rebuild
    /// the status-item menu and the app main menu so they switch live too.
    @objc private func languageChanged(_ note: Notification) {
        if let language = note.object as? DragonLanguage {
            mirrorAppleLanguages(language)
        }
        statusItemController.update(menu: mainMenuController.buildMainMenu())
        installMainMenu()
    }

    /// Minimal main menu (App + Edit). The Edit ▸ Undo/Redo items route through
    /// the responder chain to the key window's undo manager
    /// (SnippetEditorWindowController.windowWillReturnUndoManager).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit ClipMenu 2"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Undo"),
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Redo"),
                                    action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"),
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"),
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"),
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"),
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        HotKeyCenter.shared.unregisterAll()
        // Write the settings sidecar to the backup folder on quit (best-effort) so the
        // latest settings always travel with the synced folder. Snippet versions are
        // captured by the launch-time daily check and the manual "Back Up Now" button
        // (a snippet snapshot is async and can't run during synchronous termination).
        if BackupFolder.automaticBackupEnabled(), let backupFolder = BackupFolder.resolvedURL() {
            let scoped = backupFolder.startAccessingSecurityScopedResource()
            SettingsSidecar.write(from: .standard, to: backupFolder.appending(path: SettingsSidecar.fileName))
            if scoped { backupFolder.stopAccessingSecurityScopedResource() }
        }
        Task { await pasteboardMonitor.stop() }

        // Save-on-quit (AppController.m:351-373): SwiftData persists clips
        // continuously, so "save on quit" is automatic. When saveHistoryOnQuit
        // is OFF, legacy instead deletes the saved history — replicate by
        // clearing the store synchronously on quit (default YES → no-op).
        let saveHistoryOnQuit = UserDefaults.standard.object(forKey: PreferenceKeys.saveHistoryOnQuit) as? Bool ?? true
        if !saveHistoryOnQuit {
            let context = AppStore.container.mainContext
            if let all = try? context.fetch(FetchDescriptor<ClipRecord>()) {
                for clip in all { context.delete(clip) }
                try? context.save()
            }
            // Don't leave the pre-2.3 backup store behind either — it holds the
            // full pre-migration history in plaintext.
            StoreMigration.deleteLegacyBackupIfMigrated(folder: AppStore.folder)
        }
    }

    /// Present the first-run setup wizard. `reset` restarts it at the welcome step
    /// (used by the "Show Setup Guide…" button in About); first-run launch omits it
    /// so the wizard resumes on the saved step after a relaunch.
    func showOnboarding(reset: Bool = false) {
        if reset { UserDefaults.standard.set(0, forKey: PreferenceKeys.onboardingStep) }
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(
                isTerminating: { [weak self] in self?.isTerminating ?? false },
                onClosed: { [weak self] in self?.onboardingController = nil })
        }
        onboardingController?.show()
    }

    /// First launch only: offer to add ClipMenu as a login item, with a
    /// suppression checkbox (AppController.m:556-579). Shown only when not
    /// already a login item and not previously suppressed (AppController.m:323-326).
    private func maybePromptToAddLoginItem() {
        let defaults = UserDefaults.standard
        let alreadyLoginItem = defaults.object(forKey: PreferenceKeys.loginItem) as? Bool ?? false
        let suppressed = defaults.object(forKey: PreferenceKeys.suppressAlertForLoginItem) as? Bool ?? false
        guard !alreadyLoginItem, !suppressed else { return }

        let alert = NSAlert()
        alert.messageText = L("Launch ClipMenu 2 on system startup?")
        alert.informativeText = L("You can change this setting in the Preferences if you want.")
        alert.addButton(withTitle: L("Launch on system startup"))
        alert.addButton(withTitle: L("Don't Launch"))
        alert.showsSuppressionButton = true

        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            defaults.set(true, forKey: PreferenceKeys.loginItem)
            LoginItem.setEnabled(true)
        }
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: PreferenceKeys.suppressAlertForLoginItem)
        }
    }
}

// The Settings UI lives in SettingsWindowController.swift (DragonKit
// SettingsShell + SettingsPane conformers in PreferencesPanes.swift).
