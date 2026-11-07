import AppKit
import SwiftUI
import DragonKit
#if SPARKLE
import DragonKitUpdates
#endif

// The Settings window, on DragonKit's shared shell.
//
// ClipMenu is an LSUIElement agent, so the SwiftUI `Settings` scene can't be
// opened programmatically; DragonKit's `DragonSettingsWindowController` owns a
// reliable self-managed window instead (flips the app to `.regular` while it's
// open so it can become key, back to `.accessory` on close). The pane list is
// data-driven (`SettingsPane` conformers → `SettingsShell`), selection is
// host-owned so menu items can open a specific pane ("About ClipMenu 2" →
// About; "Uninstall…" → Uninstall), and the root re-localizes live via
// `.dragonLocalized()` — mirroring dragon-kit's Example app wiring.

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    /// Host-owned pane selection. Persisted so reopening Settings returns to the
    /// last-used pane; set before `show()` to land on a specific pane.
    @Observable
    final class Selection {
        var paneID: String? {
            didSet {
                if let paneID {
                    UserDefaults.standard.set(paneID, forKey: PreferenceKeys.settingsSelectedTab)
                }
            }
        }

        init() {
            let saved = UserDefaults.standard.string(forKey: PreferenceKeys.settingsSelectedTab) ?? "general"
            paneID = ClipMenuBackup.migratedPaneID(saved)
        }
    }

    private let selection = Selection()

    private lazy var controller: DragonSettingsWindowController = {
        let controller = DragonSettingsWindowController(
            title: String(format: L("%@ Settings"), AppInfo.displayName),
            rootView: SettingsRoot(
                appName: AppInfo.displayName,
                panesBuilder: { [weak self] in self?.settingsPanes ?? [] },
                selection: selection
            )
            .modelContainer(AppStore.container)
        )
        // Selector-based observers (both notifications post on the main thread).
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: controller.window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageChanged(_:)),
            name: .dragonLanguageChanged, object: nil)
        return controller
    }()

    /// DragonKit's controller hands the activation policy back to `.accessory`
    /// when the window closes. If the Snippet editor (which also promotes the app
    /// to `.regular`) is still open, re-assert `.regular` so it keeps its Dock
    /// presence. Async so it runs after DragonKit's own willClose handler.
    @objc private func settingsWindowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if SnippetEditorWindowController.shared.isWindowVisible {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    /// The window title is AppKit-owned (not inside the SwiftUI tree), so
    /// re-title it when the language changes.
    @objc private func languageChanged(_ notification: Notification) {
        controller.window?.title = String(format: L("%@ Settings"), AppInfo.displayName)
    }

    /// The pane list, rebuilt whenever the language changes (so injected content
    /// like About / What's New re-localizes). Order = sidebar order.
    private var settingsPanes: [AnySettingsPane] {
        var panes: [AnySettingsPane] = [
            AnySettingsPane(GeneralPane()),
            AnySettingsPane(MenuPane()),
            AnySettingsPane(TypePane()),
            AnySettingsPane(ActionPane()),
            AnySettingsPane(ShortcutsPane()),
        ]
        // The sandboxed App Store build can't use Accessibility (no auto-paste),
        // so it gets no Permissions pane — matching its onboarding.
        if DistributionChannel.current == .direct {
            panes.append(AnySettingsPane(PermissionsSettingsPane(
                permissions: [.accessibility(isRequired: false)])))
        }
        panes.append(AnySettingsPane(BackupSettingsPane(config: ClipMenuBackup.config) {
            BackupAdditionalSettingsView()
        }))
        panes.append(AnySettingsPane(WhatsNewSettingsPane(content: WhatsNewConfig.content)))
        #if SPARKLE
        // Present in the Debug build too, so the sidebar matches the release build
        // pane for pane (CONFORMANCE §R9 order). It goes inert rather than missing:
        // scripts/run-debug.sh deletes SUFeedURL, so Sparkle refuses to start,
        // `DragonUpdater` leaves its SPUUpdater nil, and the toggles read false with
        // the Check button disabled — no route to the production appcast. Hiding the
        // pane instead would make the one build we test with differ from the one we
        // ship in the sidebar itself.
        panes.append(AnySettingsPane(UpdatesSettingsPane(updater: UpdaterUI.updater)))
        #endif
        panes.append(AnySettingsPane(AboutSettingsPane(content: AboutConfig.content)))
        panes.append(AnySettingsPane(UninstallSettingsPane(config: uninstallConfig, onCancel: { [weak self] in
            self?.selection.paneID = "general"
        })))
        return panes
    }

    /// The bundle id Homebrew installed: the fallback for the running bundle's id below, and the
    /// gate the cask token is issued against — deliberately not both at once, see
    /// ``homebrewCaskToken(channel:actual:)``.
    static let releaseBundleID = "com.dragonapp.clipmenu-2"

    /// The Homebrew cask token, or `nil` when this bundle is not the one brew installed.
    ///
    /// ClipMenu ships as the cask `clipmenu-2` (the token declared by `Casks/clipmenu-2.rb` in
    /// teddychan/homebrew-tap, not inferred from the repo name). Homebrew never watches the
    /// filesystem, so an app that deletes itself leaves brew's receipt still claiming the cask is
    /// installed and `Caskroom/clipmenu-2/<version>/ClipMenu 2.app` a dangling symlink;
    /// `brew install --cask clipmenu-2` then refuses outright — "already installed" — for an app
    /// that isn't there, pointing at nothing that would fix it. Naming the token lets the kit's
    /// post-exit shell run `brew uninstall --cask --force clipmenu-2` and clear that record.
    ///
    /// Two builds must be excluded, and they need two different mechanisms:
    ///
    /// - The **local Debug build**, which `scripts/run-debug.sh` re-ids `…clipmenu-2.debug`.
    ///   `brew uninstall --cask` is not bundle-scoped: it deletes whatever the receipt points at,
    ///   which is the *release* app in /Applications, and `Casks/clipmenu-2.rb` carries
    ///   `uninstall quit: "com.dragonapp.clipmenu-2"`, so it terminates that app first. The kit's
    ///   ``UninstallConfig/caskToken(_:ifBundleIs:actual:)`` makes that comparison, and it fails
    ///   closed — a debug id, another app's id and a *missing* id all return `nil`. The raw
    ///   `Bundle.main.bundleIdentifier` goes in, never `uninstallConfig`'s fallen-back `bundleID`:
    ///   that one answers the release id for a build which can't state its own, which is precisely
    ///   the build with no business authorising a delete. ice-2 shipped exactly that bug.
    /// - The **Mac App Store build**, which a bundle-id comparison cannot see: it is sandboxed but
    ///   carries the *same* id as the direct build, so `caskToken` would issue the token. Homebrew
    ///   never installed it. The kit's post-exit `brew` step is a detached `try?` and a sandboxed
    ///   process cannot spawn it, so today this is inert either way — but "the sandbox happens to
    ///   deny it" is not the same as saying so. `DistributionChannel` is the app's existing runtime
    ///   answer to which channel this is (sandbox presence, not a build flag), already used for the
    ///   Permissions pane above, and it keeps the decision testable.
    static func homebrewCaskToken(
        channel: DistributionChannel = .current,
        actual: String? = Bundle.main.bundleIdentifier
    ) -> String? {
        guard channel == .direct else { return nil }
        return UninstallConfig.caskToken("clipmenu-2", ifBundleIs: releaseBundleID, actual: actual)
    }

    /// What uninstalling removes. The optional toggle (default off) covers the
    /// user's clipboard history + snippets (the whole Application Support folder);
    /// without it only support files (actions.plist, user scripts) and caches go.
    private var uninstallConfig: UninstallConfig {
        let bundleID = Bundle.main.bundleIdentifier ?? Self.releaseBundleID
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return UninstallConfig(
            appName: MainMenuController.canonicalName,
            checklistItems: [
                L("The app and its login item"),
                L("All preferences and actions"),
                L("Caches and support files"),
            ],
            optionalDataToggle: (label: L("Also delete clipboard history and snippets"),
                                 paths: [AppStore.folder]),
            extraCleanupPaths: [
                AppStore.folder.appending(path: "actions.plist"),
                AppStore.folder.appending(path: "script"),
                library.appending(path: "Caches/\(bundleID)"),
                library.appending(path: "HTTPStorages/\(bundleID)"),
            ],
            homebrewCask: Self.homebrewCaskToken())
    }

    /// True while the Settings window is on screen.
    var isWindowVisible: Bool { controller.window?.isVisible ?? false }

    func show() {
        // A stale persisted selection (e.g. a pane this build doesn't have, like
        // Updates on the App Store channel) would render an empty detail pane.
        if !settingsPanes.contains(where: { $0.id == selection.paneID }) {
            selection.paneID = "general"
        }
        controller.show()
    }

    /// Open Settings directly on a specific pane (e.g. "about", "uninstall").
    func show(paneID: String) {
        selection.paneID = paneID
        show()
    }
}

/// Settings root wired to the host-owned selection. Observes `LocalizationManager`
/// and rebuilds the panes on a language change, then applies `.dragonLocalized()`
/// so the whole window switches language live — without a restart.
private struct SettingsRoot: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let appName: String
    let panesBuilder: () -> [AnySettingsPane]
    let selection: SettingsWindowController.Selection

    var body: some View {
        // This view observes only the language, so `panesBuilder()` re-runs on a
        // language change — not on every pane selection (SettingsPaneList's job).
        SettingsPaneList(appName: appName, panes: panesBuilder(), selection: selection)
            .dragonLocalized()
    }
}

/// Holds the (language-stable) pane list and binds selection, so switching panes
/// re-renders the sidebar/detail without rebuilding every pane.
private struct SettingsPaneList: View {
    let appName: String
    let panes: [AnySettingsPane]
    @Bindable var selection: SettingsWindowController.Selection

    var body: some View {
        SettingsShell(appName: appName, panes: panes, selection: $selection.paneID)
    }
}
