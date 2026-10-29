import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import DragonKit

/// Clamps what a free-form numeric field can store into its accepted range
/// (`PreferenceRanges`). A `Stepper(value:in:)` only bounds its own +/- buttons —
/// typing into the paired `TextField` writes straight through — so the bound has to
/// live in the binding for the field to actually be limited.
// `Swift.min`/`Swift.max` are qualified because Binding is @dynamicMemberLookup:
// a bare `min` inside this extension resolves to a projected Binding member.
private extension Binding where Value == Int {
    func clamped(to range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { wrappedValue },
                set: { wrappedValue = Swift.min(range.upperBound, Swift.max(range.lowerBound, $0)) })
    }

    /// Pull an already-stored out-of-range value back in, so a field can't keep
    /// displaying a number the rest of the app clamps away. Writes only when it
    /// must, to avoid materializing a default that was never set.
    func heal(into range: ClosedRange<Int>) {
        let bounded = Swift.min(range.upperBound, Swift.max(range.lowerBound, wrappedValue))
        if bounded != wrappedValue { wrappedValue = bounded }
    }
}

// MARK: - General pane

struct GeneralPreferencesView: View {
    @AppStorage(PreferenceKeys.loginItem) private var loginItem = false
    @AppStorage(PreferenceKeys.inputPasteCommand) private var inputPasteCommand = true
    @AppStorage(PreferenceKeys.reorderClipsAfterPasting) private var reorderAfterPasting = true
    @AppStorage(PreferenceKeys.maxHistorySize) private var maxHistorySize = 20
    @AppStorage(PreferenceKeys.timeInterval) private var timeInterval = 0.75
    @AppStorage(PreferenceKeys.saveHistoryOnQuit) private var saveHistoryOnQuit = true
    @AppStorage(PreferenceKeys.showStatusItem) private var showStatusItem = 1
    @State private var showExcludeSheet = false
    @State private var showAutoPasteInfo = false
    /// Pending "lowering the cap will delete N clips" confirmation: the count to
    /// delete and the cap to restore if the user backs out.
    @State private var pendingTrimCount = 0
    @State private var capBeforeEdit = 0
    @State private var showTrimConfirm = false

    /// The history cap, bounded on the way in, so the change handler below only ever
    /// sees a cap it can act on.
    private var historySize: Binding<Int> {
        $maxHistorySize.clamped(to: PreferenceRanges.maxHistorySize)
    }

    var body: some View {
        DragonForm {
            DragonSection {
                // DragonKit's shared language switcher — switches live, no restart.
                // Lists only the languages this app ships an .lproj for (DragonKit
                // CONFORMANCE §R13); the kit also has ru, which ClipMenu doesn't translate.
                LanguagePicker(languages: [.en, .es, .fr, .ja, .ko, .zhHans, .zhHant])
            }
            DragonSection {
                Toggle(L("Launch on Login"), isOn: $loginItem)
                // No update rows here: the Sparkle build has a dedicated Updates
                // pane (DragonKitUpdates); the Mac App Store build has neither.
                if DistributionChannel.current == .appStore {
                    // Sandboxed App Store build can't auto-paste: show the toggle
                    // disabled and off, with an ⓘ popover explaining why and where
                    // to get the auto-paste (direct/Homebrew) build.
                    HStack(spacing: 6) {
                        Toggle(L("Input \"⌘ + V\" after menu item selection"), isOn: .constant(false))
                            .disabled(true)
                        Button {
                            showAutoPasteInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("About automatic paste"))
                        .help(L("About automatic paste"))
                        .popover(isPresented: $showAutoPasteInfo, arrowEdge: .trailing) {
                            AutoPasteInfoPopover()
                        }
                    }
                } else {
                    Toggle(L("Input \"⌘ + V\" after menu item selection"), isOn: $inputPasteCommand)
                }
            }
            DragonSection {
                Picker(L("Sort history order by:"), selection: $reorderAfterPasting) {
                    Text(L("Date created")).tag(false)
                    Text(L("Date last used")).tag(true)
                }
                LabeledContent(L("Max clipboard history size:")) {
                    HStack {
                        TextField("", value: historySize, format: .number).frame(width: 60)
                        Stepper("", value: historySize, in: PreferenceRanges.maxHistorySize).labelsHidden()
                        Text(L("items"))
                    }
                }
                VStack(alignment: .leading) {
                    Text(L("Time interval to observe the clipboard:"))
                    Slider(value: $timeInterval, in: 0...1, step: 0.25) {
                        Text(L("Time interval"))
                    } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("1") }
                }
                Toggle(L("Save clipboard history on quit"), isOn: $saveHistoryOnQuit)
            }
            DragonSection {
                Picker(L("Status Bar icon style:"), selection: $showStatusItem) {
                    Text(L("None")).tag(0)
                    Text(L("Show")).tag(1)
                }
            }
            DragonSection(LocalizedStringKey(L("Exclude Applications"))) {
                Button(L("Define Exclude Options…")) { showExcludeSheet = true }
            }
            DragonSection {
                // Moved from the old bespoke About pane (About is now DragonKit's
                // shared pane, which carries no custom buttons).
                Button(L("Show Setup Guide…")) {
                    (NSApp.delegate as? AppDelegate)?.showOnboarding(reset: true)
                }
            }
        }
        .onAppear {
            loginItem = LoginItem.isEnabled   // reconcile with actual state
            $maxHistorySize.heal(into: PreferenceRanges.maxHistorySize)
        }
        .onChange(of: loginItem) { _, newValue in LoginItem.setEnabled(newValue) }
        .onChange(of: maxHistorySize) { oldValue, newValue in
            // Lowering the cap is destructive, so apply it now and say so, rather
            // than letting the menu hide the extra clips while they sit in the
            // store until the next copy trims them (ClipStore.enforceCapNow).
            // Raising it deletes nothing, so it needs no confirmation.
            guard newValue < oldValue else { return }
            let overflow = ClipStore.overflowCount(
                beyondCap: newValue, in: AppStore.container.mainContext)
            guard overflow > 0 else { return }
            pendingTrimCount = overflow
            capBeforeEdit = oldValue
            showTrimConfirm = true
        }
        .alert(L("Delete older clipboard history?"), isPresented: $showTrimConfirm) {
            Button(L("Delete"), role: .destructive) {
                ClipStore.enforceCapNow(in: AppStore.container.mainContext)
            }
            // Restoring the previous cap re-enters this handler as an INCREASE,
            // which the guard above ignores — so cancelling can't loop.
            Button(L("Cancel"), role: .cancel) { maxHistorySize = capBeforeEdit }
        } message: {
            Text(String(format: L("%d older clips will be deleted from your history. This can't be undone."),
                        pendingTrimCount))
        }
        .sheet(isPresented: $showExcludeSheet) { ExcludeAppsView() }
    }
}

// MARK: - Sync & Backup pane (folder backup + history export)

/// Sync & backup preferences. Snippets and settings are backed up to a folder you
/// choose; put that folder in Dropbox / iCloud Drive / Google Drive to sync across
/// Macs. A separate section handles the one-shot clipboard-history text export.
struct BackupPreferencesView: View {
    @AppStorage("exportHistoryAsSingleFile") private var exportAsSingleFile = true
    @AppStorage("tagOfSeparatorForExportHistoryToFile") private var separatorTag = 1
    @AppStorage(PreferenceKeys.automaticBackupEnabled) private var automaticBackup = true

    @State private var folderPath: String = BackupFolder.displayPath()
    @State private var status: String = ""
    @State private var working = false
    @State private var showRestore = false

    private var backupConfigured: Bool { BackupFolder.isConfigured() }

    var body: some View {
        Group {
            DragonSection(LocalizedStringKey(L("Sync & Backup"))) {
                LabeledContent(L("Backup folder")) {
                    Button(folderPath.isEmpty ? L("Choose…") : L("Change…"), action: chooseFolder)
                }
                if !folderPath.isEmpty {
                    Text(folderPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(L("Snippets and settings are backed up to this folder (the newest 20 are kept). Put it in Dropbox, iCloud Drive, or Google Drive to sync across your Macs or set up a new Mac."))
                    .font(.callout).foregroundStyle(.secondary)
                Toggle(L("Back up automatically when quitting"), isOn: $automaticBackup)
                HStack {
                    Button(L("Back up now")) { Task { await backUpNow() } }
                        .disabled(working || !backupConfigured)
                    Button(L("Restore…")) { showRestore = true }
                        .disabled(working || !backupConfigured)
                    if working { ProgressView().controlSize(.small) }
                }
                if !status.isEmpty {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }

            DragonSection(LocalizedStringKey(L("Clipboard History Export"))) {
                Picker("", selection: $exportAsSingleFile) {
                    Text(L("Single file")).tag(true)
                    Text(L("Multiple files")).tag(false)
                }
                .labelsHidden()
                Picker(L("separator:"), selection: $separatorTag) {
                    Text(L("None")).tag(0)
                    Text(L("New Line")).tag(1)
                    Text(L("Carriage Return and New Line")).tag(2)
                    Text(L("Carriage Return")).tag(3)
                    Text(L("Tab")).tag(4)
                    Text(L("Space")).tag(5)
                }
                .disabled(!exportAsSingleFile)
                Button(L("Export…"), action: export)
            }
        }
        .sheet(isPresented: $showRestore) {
            if let manager = BackupScheduler.makeManager() {
                RestoreVersionsView(manager: manager)
            } else {
                Text(L("Choose a backup folder first.")).padding()
            }
        }
    }

    /// Pick the backup folder, persist a (security-scoped) bookmark, and seed the
    /// settings sidecar so the folder immediately holds current settings.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        if let current = BackupFolder.resolvedURL() { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = BackupFolder.set(url)
        folderPath = BackupFolder.displayPath()
        let scoped = url.startAccessingSecurityScopedResource()
        SettingsSidecar.write(from: .standard, to: url.appending(path: SettingsSidecar.fileName))
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    private func backUpNow() async {
        working = true; defer { working = false }
        guard let manager = BackupScheduler.makeManager() else {
            status = L("Choose a backup folder first.")
            return
        }
        do {
            switch try await manager.backUpNow(kind: .manual) {
            case .created: status = L("Backup saved.")
            case .noChanges: status = L("No changes since the last backup.")
            }
            // Keep the settings sidecar current alongside the snippet version.
            if let folder = BackupFolder.resolvedURL() {
                let scoped = folder.startAccessingSecurityScopedResource()
                SettingsSidecar.write(from: .standard, to: folder.appending(path: SettingsSidecar.fileName))
                if scoped { folder.stopAccessingSecurityScopedResource() }
            }
        } catch {
            status = L("Backup failed. Try again later.")
        }
    }

    /// Export… (PrefsWindowController.m:482-499): save panel (single file) or
    /// folder chooser (multiple files), then HistoryExport.
    private func export() {
        let context = AppStore.container.mainContext
        // Export the same bounded, visible history the menu shows — not every row
        // ever stored — so it can't leak old clips past maxHistorySize
        // (design-invariants.md — History bound).
        let clips = (try? context.fetch(ClipStore.boundedHistoryDescriptor())) ?? []

        if exportAsSingleFile {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "ClipMenu History.txt"
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let strings = clips.compactMap(\.stringValue)
            HistoryExport.writeSingleFile(clipStrings: strings, separatorTag: separatorTag, to: url)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            HistoryExport.writeMultipleFiles(
                orderedClipStrings: clips.map(\.stringValue), toDirectory: dir)
        }
    }
}

/// Lists stored backup versions newest-first and restores the chosen one.
struct RestoreVersionsView: View {
    let manager: BackupManager
    @Environment(\.dismiss) private var dismiss

    @State private var versions: [BackupVersionMeta] = []
    @State private var loading = true
    @State private var restoring = false
    @State private var selectedID: String?
    @State private var error: String = ""
    @State private var otherFiles = 0

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    private var selected: BackupVersionMeta? { versions.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Restore from Backup")).font(.headline)

            if restoring {
                HStack { ProgressView().controlSize(.small); Text(L("Restoring…")) }
            } else if loading {
                ProgressView()
            } else if versions.isEmpty && error.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("No backups yet.")).foregroundStyle(.secondary)
                    if otherFiles > 0 {
                        Text("\(otherFiles) " + L("items in this folder aren't ClipMenu 2 backups (for example, exports from an older app)."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                List(selection: $selectedID) {
                    ForEach(versions) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.dateFormat.string(from: v.effectiveDate))
                            Text("\(kindLabel(v.kind)) · \(v.folderCount) \(L("folders")) · \(v.snippetCount) \(L("snippets")) · \(v.deviceName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(v.id)
                    }
                }
                .frame(minHeight: 200)
            }

            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.disabled(restoring)
                Button(L("Restore")) { confirmAndRestore() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || restoring || newerThanApp(selected))
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await load() }
    }

    /// Confirm with an AppKit alert before the destructive replace. SwiftUI's
    /// `.confirmationDialog` does not reliably present from inside a `.sheet` on
    /// macOS, so we use `NSAlert` — the confirmation pattern used elsewhere here.
    private func confirmAndRestore() {
        guard let v = selected else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Restore this backup?")
        alert.informativeText = confirmMessage(v)
        alert.addButton(withTitle: L("Restore"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await restore() }
    }

    /// Detail shown in the restore confirmation: which version, and that the
    /// current snippets are safely backed up before the destructive replace.
    private func confirmMessage(_ v: BackupVersionMeta) -> String {
        let when = Self.dateFormat.string(from: v.effectiveDate)
        let detail = "\(kindLabel(v.kind)) · \(v.folderCount) \(L("folders")) · \(v.snippetCount) \(L("snippets")) · \(v.deviceName)"
        return "\(when)\n\(detail)\n\n" + L("This replaces all your current snippets and folders. Your current snippets are backed up first.")
    }

    private func kindLabel(_ kind: BackupKind) -> String {
        switch kind {
        case .auto: return L("Automatic")
        case .manual: return L("Manual")
        case .preRestore: return L("Before restore")
        }
    }

    private func newerThanApp(_ v: BackupVersionMeta?) -> Bool {
        guard let v else { return false }
        return v.schemaVersion > SnippetSnapshot.currentSchemaVersion
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            versions = try await manager.listForUI()
            if versions.isEmpty { otherFiles = await manager.otherFolderItemCount() }
        }
        catch _ { error = L("Couldn't load backups from the folder.") }
    }

    private func restore() async {
        guard let v = selected else { return }
        restoring = true; defer { restoring = false }
        do { try await manager.restore(v); dismiss() }
        catch let e as SyncBackupError {
            switch e {
            case .preRestoreFailed:
                error = L("Couldn't save a safety backup, so the restore was cancelled.")
            case .unsupportedSchemaVersion:
                error = L("This version was made on a newer app version and can't be restored.")
            case .validationFailed:
                error = L("Restore failed. Your current data was not changed.")
            }
        } catch _ {
            error = L("Restore failed. Your current data was not changed.")
        }
    }
}

// MARK: - Sync & Backup pane (combined tab)

/// The single "Sync & Backup" Settings tab: folder-based snippet + settings backup
/// and restore, plus the one-shot clipboard-history export, in one grouped `Form`.
struct CloudBackupPreferencesView: View {
    var body: some View {
        DragonForm {
            BackupPreferencesView()
        }
    }
}

// Preferences panes. SwiftUI forms bound to the exact legacy UserDefaults keys
// and defaults (AppController.m:131-188; labels English.lproj/Preferences.strings).
// Legacy PrefsWindowController panes. @AppStorage defaults match the legacy registered
// defaults, so behavior is identical whether or not the user opens Settings.

// MARK: - Exclude-apps sheet (PrefsWindowController.m:378-478,789-877)

/// "Exclude these applications:" — apps whose frontmost clipboard activity is not
/// captured. Persisted as the `excludeApps` array of {bundleIdentifier, name},
/// which PasteboardReader gates on (AppController.m:_defaultExcludeList).
struct ExcludeAppsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [[String: String]] = ExcludeAppsView.load()
    @State private var selection: String?   // bundle identifier

    private static let key = "excludeApps"

    static func load() -> [[String: String]] {
        UserDefaults.standard.array(forKey: key) as? [[String: String]]
            ?? [["bundleIdentifier": "org.openoffice.script", "name": "OpenOffice.org"]]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Exclude these applications:")).font(.headline)
            List(selection: $selection) {
                ForEach(apps, id: \.self) { app in
                    Label(app["name"] ?? app["bundleIdentifier"] ?? "?", systemImage: "app.dashed")
                        .tag(app["bundleIdentifier"] ?? "")
                }
            }
            .frame(minWidth: 320, minHeight: 200)
            HStack {
                Menu {
                    ForEach(runningApps(), id: \.id) { app in
                        Button(app.name) { add(bundleID: app.id, name: app.name) }
                    }
                    Divider()
                    Button(L("Other…")) { addViaPanel() }
                } label: { Image(systemName: "plus") }
                .frame(width: 44)

                Button(action: removeSelected) { Image(systemName: "minus") }
                    .disabled(selection == nil)
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func runningApps() -> [(id: String, name: String)] {
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let mapped = regular.compactMap { app -> (String, String)? in
            guard let id = app.bundleIdentifier else { return nil }
            return (id, app.localizedName ?? id)
        }
        // De-dupe by bundle id, sorted by name.
        var seen = Set<String>()
        return mapped.filter { seen.insert($0.0).inserted }
            .map { (id: $0.0, name: $0.1) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func add(bundleID: String, name: String) {
        guard !apps.contains(where: { $0["bundleIdentifier"] == bundleID }) else { return }
        apps.append(["bundleIdentifier": bundleID, "name": name])
        persist()
    }

    /// "Other…" — choose an .app and read its bundle id (789-877).
    private func addViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        add(bundleID: id, name: name)
    }

    private func removeSelected() {
        guard let id = selection else { return }
        apps.removeAll { $0["bundleIdentifier"] == id }
        selection = nil
        persist()
    }

    private func persist() { UserDefaults.standard.set(apps, forKey: Self.key) }
}

// MARK: - Pane registry (DragonKit SettingsShell)

// The app's screens as `SettingsPane` conformers, listed by
// `SettingsWindowController.settingsPanes` in sidebar order. `title` is a
// localization key resolved by the shell via `L()`, so the sidebar switches
// language live. DragonKit's own panes (Permissions, What's New, Updates,
// About) are appended there — no bespoke About pane remains (its Setup Guide
// button moved to General; Check for Updates lives in the Updates pane).

struct GeneralPane: SettingsPane {
    let id = "general"
    let title = "General"
    let systemImage = "gearshape"
    var paneBody: some View { GeneralPreferencesView() }
}

struct SyncBackupPane: SettingsPane {
    let id = "syncBackup"
    let title = "Sync & Backup"
    let systemImage = "externaldrive.badge.timemachine"
    var paneBody: some View { CloudBackupPreferencesView() }
}

struct MenuPane: SettingsPane {
    let id = "menu"
    let title = "Menu"
    let systemImage = "menubar.rectangle"
    var paneBody: some View { MenuPreferencesView() }
}

struct TypePane: SettingsPane {
    let id = "type"
    let title = "Type"
    let systemImage = "doc.on.doc"
    var paneBody: some View { TypePreferencesView() }
}

struct ActionPane: SettingsPane {
    let id = "action"
    let title = "Action"
    let systemImage = "bolt"
    var paneBody: some View { ActionPreferencesView() }
}

struct ShortcutsPane: SettingsPane {
    let id = "shortcuts"
    let title = "Shortcuts"
    let systemImage = "command"
    var paneBody: some View { ShortcutsPreferencesView() }
}

/// Shortcuts pane — three hot-key recorders (PrefsWindowController.m:556-613;
/// labels from English.lproj/Preferences.strings:407-411, 488-489).
struct ShortcutsPreferencesView: View {
    var body: some View {
        DragonForm {
            LabeledContent(L("Main Menu:")) {
                ShortcutRecorder(hotKey: .main).frame(width: 150, height: 24)
            }
            LabeledContent(L("History Menu:")) {
                ShortcutRecorder(hotKey: .history).frame(width: 150, height: 24)
            }
            LabeledContent(L("Snippets Menu:")) {
                ShortcutRecorder(hotKey: .snippets).frame(width: 150, height: 24)
            }
        }
    }
}

// MARK: - Menu pane

struct MenuPreferencesView: View {
    @AppStorage(PreferenceKeys.numberOfItemsPlaceInline) private var inlineCount = 0
    @AppStorage(PreferenceKeys.numberOfItemsPlaceInsideFolder) private var perFolder = 10
    @AppStorage(PreferenceKeys.maxMenuItemTitleLength) private var maxTitleLength = 20
    @AppStorage(PreferenceKeys.menuItemsAreMarkedWithNumbers) private var markWithNumbers = true
    @AppStorage(PreferenceKeys.addNumericKeyEquivalents) private var numericKeyEquivalents = false
    @AppStorage(PreferenceKeys.showLabelsInMenu) private var showLabels = true
    @AppStorage(PreferenceKeys.addClearHistoryMenuItem) private var addClearHistory = true
    @AppStorage(PreferenceKeys.showAlertBeforeClearHistory) private var alertBeforeClear = true
    @AppStorage(PreferenceKeys.showToolTipOnMenuItem) private var showToolTip = true
    @AppStorage(PreferenceKeys.maxLengthOfToolTipKey) private var maxToolTipLength = 200
    @AppStorage(PreferenceKeys.changeFontSize) private var changeFontSize = false
    @AppStorage(PreferenceKeys.howToChangeFontSize) private var howToChangeFontSize = 0
    @AppStorage(PreferenceKeys.selectedFontSize) private var selectedFontSize = 14
    @AppStorage(PreferenceKeys.showImageInTheMenu) private var showImage = true
    @AppStorage(PreferenceKeys.thumbnailMaxSize) private var thumbnailMaxSize = 64
    @AppStorage(PreferenceKeys.showIconInTheMenu) private var showIcon = true
    @AppStorage(PreferenceKeys.menuIconSize) private var menuIconSize = 16
    @AppStorage(PreferenceKeys.positionOfSnippets) private var positionOfSnippets = 2
    @AppStorage(PreferenceKeys.groupSnippetsInFolder) private var groupSnippetsInFolder = true

    private static let fontSizes = Array(9...24) + [36, 48, 64, 72, 96]

    private var toolTipLength: Binding<Int> {
        $maxToolTipLength.clamped(to: PreferenceRanges.maxLengthOfToolTip)
    }

    var body: some View {
        DragonForm {
            DragonSection(LocalizedStringKey(L("Clipboard History"))) {
                LabeledContent(L("Number of items place inline:")) {
                    TextField("", value: $inlineCount.clamped(to: PreferenceRanges.numberOfItemsPlaceInline),
                              format: .number).frame(width: 60)
                }
                LabeledContent(L("Number of items place inside a folder:")) {
                    TextField("", value: $perFolder.clamped(to: PreferenceRanges.numberOfItemsPlaceInsideFolder),
                              format: .number).frame(width: 60)
                }
                LabeledContent(L("Number of characters in the menu:")) {
                    TextField("", value: $maxTitleLength.clamped(to: PreferenceRanges.maxMenuItemTitleLength),
                              format: .number).frame(width: 60)
                }
                Toggle(L("Mark menu items with numbers"), isOn: $markWithNumbers)
                Toggle(L("Add key equivalents to numeric keys"), isOn: $numericKeyEquivalents)
                Toggle(L("Show labels to indicate item types"), isOn: $showLabels)
                Toggle(L("Add a menu item to clear clipboard history"), isOn: $addClearHistory)
                Toggle(L("Show alert panel before clear history"), isOn: $alertBeforeClear)
                Toggle(L("Show tool tip on a menu item"), isOn: $showToolTip)
                LabeledContent(L("Max length of tool tip string:")) {
                    HStack {
                        TextField("", value: toolTipLength, format: .number).frame(width: 60)
                        Text(L("characters")).foregroundStyle(.secondary)
                    }
                }
            }

            DragonSection(LocalizedStringKey(L("Appearance"))) {
                Toggle(L("Change font size in the menu"), isOn: $changeFontSize)
                Picker(L("Font size:"), selection: $howToChangeFontSize) {
                    Text(L("Fit to the icon size")).tag(0)
                    Text(L("Select")).tag(1)
                }
                .disabled(!changeFontSize)
                Picker(L("Size:"), selection: $selectedFontSize) {
                    ForEach(Self.fontSizes, id: \.self) { Text("\($0) pt").tag($0) }
                }
                .disabled(!changeFontSize || howToChangeFontSize != 1)
            }

            DragonSection(LocalizedStringKey(L("Icon"))) {
                Toggle(L("Show Icon in the Menu"), isOn: $showIcon)
                Picker(L("Icon size:"), selection: $menuIconSize) {
                    Text("16").tag(16)
                    Text("32").tag(32)
                    Text("48").tag(48)
                }
                .disabled(!showIcon)
                Toggle(L("Show Image"), isOn: $showImage)
                LabeledContent(L("Maximum thumbnail size:")) {
                    HStack(spacing: 6) {
                        TextField("", value: $thumbnailMaxSize.clamped(to: PreferenceRanges.thumbnailMaxSize),
                                  format: .number).frame(width: 60)
                        Stepper("", value: $thumbnailMaxSize.clamped(to: PreferenceRanges.thumbnailMaxSize),
                                in: PreferenceRanges.thumbnailMaxSize, step: 8).labelsHidden()
                        Text(L("px")).foregroundStyle(.secondary)
                    }
                }
                .disabled(!showImage)
            }

            DragonSection {
                Picker(L("Snippets' position:"), selection: $positionOfSnippets) {
                    Text(L("None")).tag(0)
                    Text(L("Above the clipboard history")).tag(1)
                    Text(L("Below the clipboard history")).tag(2)
                }
                Toggle(L("Group snippets under one menu"), isOn: $groupSnippetsInFolder)
            }
        }
        // Pull values stored before these ranges existed back in, so a field can't
        // keep showing a number the rest of the app clamps away.
        .onAppear {
            $inlineCount.heal(into: PreferenceRanges.numberOfItemsPlaceInline)
            $perFolder.heal(into: PreferenceRanges.numberOfItemsPlaceInsideFolder)
            $maxTitleLength.heal(into: PreferenceRanges.maxMenuItemTitleLength)
            $maxToolTipLength.heal(into: PreferenceRanges.maxLengthOfToolTip)
            $thumbnailMaxSize.heal(into: PreferenceRanges.thumbnailMaxSize)
        }
    }
}

// MARK: - Type pane

/// "Select clipboard types to store:" — the 7 live store-type toggles
/// (Preferences.strings:1097-1104). Bound to the `storeTypes` [String:Bool]
/// UserDefaults dict that PasteboardReader gates capture on (AppController.m:142,
/// 48-58; ClipsController.m:670-678). The legacy PICT Image toggle is removed —
/// PICT is dead on modern macOS.
struct TypePreferencesView: View {
    /// Legacy type name (storeTypes key) → display label, in xib order.
    private static let types: [(name: String, label: String)] = [
        ("String", "Plain Text"),
        ("RTF", "Rich Text Format (RTF)"),
        ("PDF", "PDF"),
        ("Filenames", "Filenames"),
        ("URL", "URL"),
        ("TIFF", "TIFF Image"),
        ("RTFD", "Rich Text Format Directory (RTFD)"),
    ]

    @State private var store: [String: Bool]

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: PreferenceKeys.storeTypes) as? [String: Bool] ?? [:]
        var initial: [String: Bool] = [:]
        for type in Self.types { initial[type.name] = saved[type.name] ?? true }
        _store = State(initialValue: initial)
    }

    var body: some View {
        DragonForm {
            DragonSection(LocalizedStringKey(L("Select clipboard types to store:"))) {
                ForEach(Self.types, id: \.name) { type in
                    Toggle(L(type.label), isOn: Binding(
                        get: { store[type.name] ?? true },
                        set: { store[type.name] = $0; persist() }
                    ))
                }
            }
        }
    }

    /// Persist the whole dict (all 7 keys) so PasteboardReader.storeTypes() reads
    /// a complete picture.
    private func persist() {
        UserDefaults.standard.set(store, forKey: PreferenceKeys.storeTypes)
    }
}

// MARK: - Action pane

/// Action preferences: enable, invoke-immediately, and the per-modifier click
/// behavior pickers (AppController.m:184-186 defaults; PrefsWindowController.m:
/// 655-696 picker = None / Pop up Action Menu / a specific action).
struct ActionPreferencesView: View {
    @AppStorage(PreferenceKeys.enableAction) private var enableAction = true
    @AppStorage(PreferenceKeys.invokeActionImmediately) private var invokeImmediately = false
    @AppStorage(PreferenceKeys.controlClickBehavior) private var controlBehavior = "popUpActionMenu"
    @AppStorage(PreferenceKeys.shiftClickBehavior) private var shiftBehavior = ""
    @AppStorage(PreferenceKeys.optionClickBehavior) private var optionBehavior = ""
    @AppStorage(PreferenceKeys.commandClickBehavior) private var commandBehavior = ""

    private let leaves = ActionStore.flattenedLeaves()

    var body: some View {
        VStack(spacing: 0) {
            DragonForm {
                DragonSection {
                    Toggle(L("Enable Action"), isOn: $enableAction)
                    Toggle(L("Invoke the first action immediately if there is only one action"),
                           isOn: $invokeImmediately)
                }
                DragonSection(LocalizedStringKey(L("Click behavior"))) {
                    behaviorPicker(L("Control-click / right-click:"), $controlBehavior)
                    behaviorPicker(L("Shift-click:"), $shiftBehavior)
                    behaviorPicker(L("Option-click:"), $optionBehavior)
                    behaviorPicker(L("Command-click:"), $commandBehavior)
                }
                .disabled(!enableAction)
            }
            .frame(height: 230)

            Divider()
            ActionTreeEditorView().padding(8)
        }
    }

    private func behaviorPicker(_ label: String, _ selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Text(L("None")).tag("")
            Text(L("Pop up Action Menu")).tag("popUpActionMenu")
            Divider()
            ForEach(leaves, id: \.id) { leaf in
                Text(leaf.title).tag(leaf.id)
            }
        }
    }
}

/// Action-tree editor (ActionNodeController.m): a palette
/// (Built-in / Script / User Script) on the left whose selection is added to the
/// user's action tree on the right; remove + drag-reorder there. Persists to
/// ActionStore (actions.plist).
struct ActionTreeEditorView: View {
    @State private var userNodes: [ActionNode] = ActionStore.load()
    @State private var segment = 0
    @State private var paletteSelection: ActionNode.ID?
    @State private var treeSelection: ActionNode.ID?

    private var palette: [ActionNode] {
        switch segment {
        case 1:  return ActionStore.bundledNodes()
        case 2:  return ActionStore.usersNodes()
        default: return ActionStore.builtinNodes()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Actions")).font(.headline)
            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    Picker("", selection: $segment) {
                        Text(L("Built-in")).tag(0)
                        Text(L("Script")).tag(1)
                        Text(L("User Script")).tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    List(selection: $paletteSelection) {
                        OutlineGroup(palette, children: \.children) { node in
                            Text(node.title).tag(node.id)
                        }
                    }
                }
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Button(action: add) { Image(systemName: "arrow.right") }
                            .disabled(paletteSelection == nil)
                        Button(action: remove) { Image(systemName: "minus") }
                            .disabled(treeSelection == nil)
                        Spacer()
                    }
                    List(selection: $treeSelection) {
                        ForEach(userNodes) { node in
                            if let children = node.children {
                                DisclosureGroup {
                                    ForEach(children) { Text($0.title) }
                                } label: { Label(node.title, systemImage: "folder").tag(node.id) }
                            } else {
                                Text(node.title).tag(node.id)
                            }
                        }
                        .onMove { from, to in
                            userNodes.move(fromOffsets: from, toOffset: to)
                            persist()
                        }
                    }
                }
            }
            .frame(minHeight: 180)
        }
    }

    /// add: copy the selected palette node into the user tree (append, with fresh
    /// ids) — ActionNodeController.m:546-557.
    private func add() {
        guard let id = paletteSelection, let node = find(id, in: palette) else { return }
        userNodes.append(freshCopy(node))
        persist()
    }

    /// remove: delete the selected top-level node (ActionNodeController.m:559-570).
    private func remove() {
        guard let id = treeSelection else { return }
        userNodes.removeAll { $0.id == id }
        treeSelection = nil
        persist()
    }

    private func persist() { ActionStore.save(userNodes) }

    private func find(_ id: ActionNode.ID, in nodes: [ActionNode]) -> ActionNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let found = find(id, in: children) { return found }
        }
        return nil
    }

    /// Deep-copy with fresh identities so added copies are distinct rows.
    private func freshCopy(_ node: ActionNode) -> ActionNode {
        ActionNode(title: node.title, action: node.action, children: node.children?.map(freshCopy))
    }
}

// MARK: - Auto-paste info popover (App Store build)

/// Explains why the App Store build can't auto-paste and links to the
/// direct/Homebrew build that can. Shown from the disabled paste toggle's ⓘ.
private struct AutoPasteInfoPopover: View {
    private static let downloadURL = URL(string: "https://github.com/teddychan/clipmenu-2/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("About automatic paste"))
                .font(.headline)
            Text(L("When you pick a clip, this version copies it to the clipboard. Mac App Store apps run in a sandbox and aren't allowed to paste into other apps for you, so you press ⌘V yourself."))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("To paste automatically after selecting a clip, download ClipMenu 2 from GitHub or install it with Homebrew."))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            Link(L("Download ClipMenu 2"), destination: Self.downloadURL)
        }
        .padding()
        .frame(width: 320)
    }
}
