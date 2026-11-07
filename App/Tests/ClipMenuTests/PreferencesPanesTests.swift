import Testing
import SwiftUI
import SwiftData
import Foundation
import ViewInspector
import DragonKit
@testable import ClipMenu

// SwiftUI-body coverage for the Settings panes in PreferencesPanes.swift, driven
// by ViewInspector (see ViewInspectorSmokeTests for the working pattern).
//
// Strategy: each pane binds its controls to `@AppStorage` (UserDefaults.standard)
// or seeds `@State` from UserDefaults in `init`. We write a known value to the
// backing key BEFORE constructing the view, then inspect the tree with plain
// `try view.inspect()` (no ViewHosting) and assert the control reflects it.
// `@AppStorage` reads UserDefaults directly, so bindings resolve without a hosting
// environment; lifecycle hooks (`.onAppear`, `.task`) do NOT fire under plain
// inspection, so the seeded values survive.
//
// A throwing inspection is bound to a `let` with `try`, then asserted with
// `#expect` (the pattern the smoke test uses — `#expect(try …)` does not
// propagate the thrown error under this Testing version); presence-only checks use
// `#expect(throws: Never.self) { try … }`.
//
// THREADING / ISOLATION (critical): every suite is `@MainActor` (inspection and
// `L()` are main-actor) and `@Suite(.serialized)`. Swift Testing runs *sibling*
// suites in parallel, and `.serialized` only orders tests *within* a suite — so
// the codebase's real isolation invariant is that each `UserDefaults.standard`
// key is written by at most one suite. To honour it, value-reflection assertions
// here use ONLY keys no other suite mutates (verified against the test target);
// controls bound to keys another suite already owns (e.g. storeTypes, menuIconSize,
// the menu toggles owned by MainMenuControllerCoverageTests, the backupFolder*
// keys owned by BackupSchedulerCoverageTests) are covered by presence assertions
// that do not depend on the stored value. Every key written is snapshotted and
// restored via `defer`.
//
// Localized strings go through `L(...)`; expected strings are built with the same
// `L(...)` call the view uses, so assertions hold in any language.

// MARK: - Shared helper

/// Snapshot the given UserDefaults keys, run `body`, then restore each key to its
/// prior value (or remove it if it had none).
@MainActor
private func withPreservedDefaults(_ keys: [String], _ body: () throws -> Void) rethrows {
    let defaults = UserDefaults.standard
    let saved: [(String, Any?)] = keys.map { ($0, defaults.object(forKey: $0)) }
    defer {
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    try body()
}

// MARK: - General pane

@Suite(.serialized) @MainActor
struct GeneralPreferencesPaneTests {
    // Solely-owned keys (safe to assert values on).
    private static let ownedKeys = [
        PreferenceKeys.loginItem, PreferenceKeys.saveHistoryOnQuit,
        PreferenceKeys.showStatusItem,
    ]

    @Test func ownedTogglesAndPickerReflectStoredValues() throws {
        try withPreservedDefaults(Self.ownedKeys) {
            let d = UserDefaults.standard
            d.set(true, forKey: PreferenceKeys.loginItem)
            d.set(false, forKey: PreferenceKeys.saveHistoryOnQuit)
            d.set(0, forKey: PreferenceKeys.showStatusItem)

            let view = GeneralPreferencesView()
            // .onAppear (which would overwrite loginItem with LoginItem.isEnabled)
            // does not fire under plain inspection, so the seeded value survives.
            let login = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Launch on Login")).isOn()
            #expect(login == true)
            let save = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Save clipboard history on quit")).isOn()
            #expect(save == false)
            let statusIcon = try view.inspect().find(ViewType.Picker.self,
                containing: L("Status Bar icon style:")).selectedValue(Int.self)
            #expect(statusIcon == 0)
        }
    }

    @Test func controlsAndSectionsPresent() throws {
        let view = GeneralPreferencesView()
        // Present regardless of stored values (labels for controls whose keys are
        // owned by other suites, plus static sections/buttons).
        #expect(throws: Never.self) {
            try view.inspect().find(ViewType.Toggle.self,
                containing: L("Input \"⌘ + V\" after menu item selection"))   // else-branch (non-App-Store)
        }
        #expect(throws: Never.self) {
            try view.inspect().find(ViewType.Picker.self, containing: L("Sort history order by:"))
        }
        #expect(throws: Never.self) { try view.inspect().find(ViewType.Slider.self) }
        #expect(throws: Never.self) {
            try view.inspect().find(text: L("Max clipboard history size:"))
        }
        #expect(throws: Never.self) { try view.inspect().find(text: L("Exclude Applications")) }
        #expect(throws: Never.self) { try view.inspect().find(button: L("Define Exclude Options…")) }
        #expect(throws: Never.self) { try view.inspect().find(button: L("Show Setup Guide…")) }
    }
}

// MARK: - Menu pane

@Suite(.serialized) @MainActor
struct MenuPreferencesPaneTests {
    // Solely-owned keys (MainMenuControllerCoverageTests / MenuIconCacheCoverageTests
    // own menuItemsAreMarkedWithNumbers, showToolTipOnMenuItem, showIconInTheMenu,
    // groupSnippetsInFolder, positionOfSnippets, menuIconSize — not used here).
    private static let ownedKeys = [
        PreferenceKeys.changeFontSize, PreferenceKeys.howToChangeFontSize,
        PreferenceKeys.selectedFontSize, PreferenceKeys.showLabelsInMenu,
        PreferenceKeys.addClearHistoryMenuItem, PreferenceKeys.showImageInTheMenu,
        PreferenceKeys.addNumericKeyEquivalents,
    ]

    @Test func ownedTogglesReflectStoredValues() throws {
        try withPreservedDefaults(Self.ownedKeys) {
            let d = UserDefaults.standard
            d.set(true, forKey: PreferenceKeys.changeFontSize)
            d.set(false, forKey: PreferenceKeys.showLabelsInMenu)
            d.set(false, forKey: PreferenceKeys.addClearHistoryMenuItem)
            d.set(true, forKey: PreferenceKeys.addNumericKeyEquivalents)
            d.set(false, forKey: PreferenceKeys.showImageInTheMenu)

            let view = MenuPreferencesView()
            let fontToggle = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Change font size in the menu")).isOn()
            #expect(fontToggle == true)
            let labels = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Show labels to indicate item types")).isOn()
            #expect(labels == false)
            let clear = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Add a menu item to clear clipboard history")).isOn()
            #expect(clear == false)
            let numeric = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Add key equivalents to numeric keys")).isOn()
            #expect(numeric == true)
            let image = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Show Image")).isOn()
            #expect(image == false)
        }
    }

    @Test func ownedFontPickersReflectStoredValues() throws {
        try withPreservedDefaults(Self.ownedKeys) {
            let d = UserDefaults.standard
            d.set(1, forKey: PreferenceKeys.howToChangeFontSize)
            d.set(36, forKey: PreferenceKeys.selectedFontSize)

            let view = MenuPreferencesView()
            let how = try view.inspect().find(ViewType.Picker.self,
                containing: L("Font size:")).selectedValue(Int.self)
            #expect(how == 1)
            let size = try view.inspect().find(ViewType.Picker.self,
                containing: L("Size:")).selectedValue(Int.self)
            #expect(size == 36)
        }
    }

    @Test func sectionsControlsAndStepperPresent() throws {
        let view = MenuPreferencesView()
        for header in [L("Clipboard History"), L("Appearance"), L("Icon")] {
            #expect(throws: Never.self) { try view.inspect().find(text: header) }
        }
        // Maximum-thumbnail-size row carries a Stepper.
        #expect(throws: Never.self) { try view.inspect().find(ViewType.Stepper.self) }
        // Labels for toggles/rows whose keys are owned by other suites are still
        // rendered unconditionally.
        for label in [
            L("Mark menu items with numbers"), L("Show tool tip on a menu item"),
            L("Show Icon in the Menu"), L("Group snippets under one menu"),
            L("Number of items place inline:"), L("Max length of tool tip string:"),
        ] {
            #expect(throws: Never.self) { try view.inspect().find(text: label) }
        }
        #expect(throws: Never.self) {
            try view.inspect().find(ViewType.Picker.self, containing: L("Snippets' position:"))
        }
    }
}

// MARK: - Type pane

@Suite(.serialized) @MainActor
struct TypePreferencesPaneTests {
    // NOTE: storeTypes is owned by PasteboardReaderCoverageTests, so its stored
    // value is not asserted here (that would race). The pane always renders one
    // toggle per supported type regardless of the stored dict, so we cover the
    // body via presence/count assertions only.
    @Test func headerAndAllSevenTypeTogglesPresent() throws {
        let view = TypePreferencesView()
        #expect(throws: Never.self) {
            try view.inspect().find(text: L("Select clipboard types to store:"))
        }
        for label in [
            L("Plain Text"), L("Rich Text Format (RTF)"), L("PDF"), L("Filenames"),
            L("URL"), L("TIFF Image"), L("Rich Text Format Directory (RTFD)"),
        ] {
            #expect(throws: Never.self) { try view.inspect().find(ViewType.Toggle.self, containing: label) }
        }
        let toggles = try view.inspect().findAll(ViewType.Toggle.self).count
        #expect(toggles == 7)
    }
}

// MARK: - Action pane

@Suite(.serialized) @MainActor
struct ActionPreferencesPaneTests {
    // All click-behavior keys are solely owned here.
    private static let ownedKeys = [
        PreferenceKeys.enableAction, PreferenceKeys.invokeActionImmediately,
        PreferenceKeys.controlClickBehavior, PreferenceKeys.shiftClickBehavior,
        PreferenceKeys.optionClickBehavior, PreferenceKeys.commandClickBehavior,
    ]

    @Test func togglesReflectStoredValues() throws {
        try withPreservedDefaults(Self.ownedKeys) {
            let d = UserDefaults.standard
            d.set(false, forKey: PreferenceKeys.enableAction)
            d.set(true, forKey: PreferenceKeys.invokeActionImmediately)

            let view = ActionPreferencesView()
            let enable = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Enable Action")).isOn()
            #expect(enable == false)
            let invoke = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Invoke the first action immediately if there is only one action"))
                .isOn()
            #expect(invoke == true)
        }
    }

    @Test func clickBehaviorPickerReflectsStoredValue() throws {
        try withPreservedDefaults(Self.ownedKeys) {
            UserDefaults.standard.set("popUpActionMenu", forKey: PreferenceKeys.controlClickBehavior)
            let view = ActionPreferencesView()
            #expect(throws: Never.self) { try view.inspect().find(text: L("Click behavior")) }
            let control = try view.inspect().find(ViewType.Picker.self,
                containing: L("Control-click / right-click:")).selectedValue(String.self)
            #expect(control == "popUpActionMenu")
            // All four modifier pickers are present.
            let pickers = try view.inspect().findAll(ViewType.Picker.self).count
            #expect(pickers >= 4)
        }
    }

    @Test func actionTreeEditorPresent() throws {
        let view = ActionPreferencesView()
        // The embedded ActionTreeEditorView contributes the "Actions" header, the
        // palette segmented control, and two Lists (palette + user tree). The
        // user-tree List carries the `.onMove` reorder closure — its presence is
        // asserted here; the closure itself is not invocable via ViewInspector, so
        // reordering behavior is left to logic-level tests.
        #expect(throws: Never.self) { try view.inspect().find(text: L("Actions")) }
        #expect(throws: Never.self) {
            try view.inspect().find(ViewType.Picker.self, containing: L("Built-in"))
        }
        let lists = try view.inspect().findAll(ViewType.List.self).count
        #expect(lists >= 2)
    }
}

// MARK: - Action-tree editor (standalone)

@Suite(.serialized) @MainActor
struct ActionTreeEditorPaneTests {
    @Test func segmentControlAndListsPresent() throws {
        let view = ActionTreeEditorView()
        #expect(throws: Never.self) { try view.inspect().find(text: L("Actions")) }
        for segment in [L("Built-in"), L("Script"), L("User Script")] {
            #expect(throws: Never.self) { try view.inspect().find(text: segment) }
        }
        // Palette List + user-tree List (the latter hosts `.onMove`).
        let lists = try view.inspect().findAll(ViewType.List.self).count
        #expect(lists >= 2)
    }
}

// MARK: - Shortcuts pane

@Suite(.serialized) @MainActor
struct ShortcutsPreferencesPaneTests {
    @Test func threeRecorderRowsPresent() throws {
        let view = ShortcutsPreferencesView()
        for label in [L("Main Menu:"), L("History Menu:"), L("Snippets Menu:")] {
            #expect(throws: Never.self) { try view.inspect().find(text: label) }
        }
    }
}

// MARK: - Sync & Backup pane (folder backup + restore + history export)

@Suite(.serialized) @MainActor
struct BackupRestorePaneTests {
    // Solely-owned keys. The backupFolder* keys are owned by
    // BackupSchedulerCoverageTests, so the Choose/Change + enabled/disabled state
    // (which reads them) is NOT asserted here — only the always-rendered controls
    // and the owned toggle/pickers are.
    private static let ownedKeys = [
        PreferenceKeys.automaticBackupEnabled,
        PreferenceKeys.exportHistoryAsSingleFile,
        PreferenceKeys.tagOfSeparatorForExportHistoryToFile,
    ]

    @Test func syncSectionControlsPresentAndAutoToggleReflectsValue() throws {
        try withPreservedDefaults(Self.ownedKeys) {
            UserDefaults.standard.set(false, forKey: PreferenceKeys.automaticBackupEnabled)

            let view = BackupAdditionalSettingsView()

            // Automatic-backup toggle reflects its (owned) stored value.
            let auto = try view.inspect().find(ViewType.Toggle.self,
                containing: L("Back up automatically when quitting")).isOn()
            #expect(auto == false)
        }
    }

    @Test func exportSectionReflectsStoredSelections() throws {
        try withPreservedDefaults(Self.ownedKeys) {
            let d = UserDefaults.standard
            d.set(false, forKey: PreferenceKeys.exportHistoryAsSingleFile)
            d.set(4, forKey: PreferenceKeys.tagOfSeparatorForExportHistoryToFile)

            let view = BackupAdditionalSettingsView()

            #expect(throws: Never.self) {
                try view.inspect().find(text: L("Clipboard History Export"))
            }
            // Single/Multiple picker (labelsHidden) — located via an option label.
            let single = try view.inspect().find(ViewType.Picker.self,
                containing: L("Single file")).selectedValue(Bool.self)
            #expect(single == false)
            // Separator picker reflects the stored tag.
            let separator = try view.inspect().find(ViewType.Picker.self,
                containing: L("separator:")).selectedValue(Int.self)
            #expect(separator == 4)
            #expect(throws: Never.self) { try view.inspect().find(button: L("Export…")) }
        }
    }

    @Test func sharedBackupPaneUsesCanonicalIdentityAndContents() {
        let pane = BackupSettingsPane(config: ClipMenuBackup.config) {
            BackupAdditionalSettingsView()
        }
        #expect(pane.id == "backup")
        #expect(pane.title == "DragonKit.pane.backup")
        #expect(pane.systemImage == "arrow.clockwise.circle")
        #expect(ClipMenuBackup.config.contents.count == 3)
        #expect(ClipMenuBackup.config.operations != nil)
        #expect(ClipMenuBackup.config.folderPathKey == PreferenceKeys.backupFolderPath)
        #expect(ClipMenuBackup.config.folderBookmarkKey == PreferenceKeys.backupFolderBookmark)
    }

}

// MARK: - Exclude-apps sheet

@Suite(.serialized) @MainActor
struct ExcludeAppsPaneTests {
    // excludeApps is owned by PasteboardReaderCoverageTests, so this test does not
    // write it or assert its contents — only the static structure of the sheet.
    @Test func headerListAndDoneButtonPresent() throws {
        let view = ExcludeAppsView()
        #expect(throws: Never.self) {
            try view.inspect().find(text: L("Exclude these applications:"))
        }
        #expect(throws: Never.self) { try view.inspect().find(ViewType.List.self) }
        #expect(throws: Never.self) { try view.inspect().find(button: L("Done")) }
    }
}
