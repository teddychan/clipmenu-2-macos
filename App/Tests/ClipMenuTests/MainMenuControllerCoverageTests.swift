import Testing
import Foundation
import AppKit
import Carbon.HIToolbox
import SwiftData
import DragonKit
@testable import ClipMenu

// Characterization tests for MainMenuController — the AppKit NSMenu builder for
// the Main (⌘⇧V), History (⌘⌃V), Snippets (⌘⇧B) and Actions menus. Everything here
// exercises the controller headlessly (no NSApplication run loop): it instantiates
// the controller, feeds representative data, invokes the build methods, and asserts
// on the resulting NSMenu trees. Assertions avoid depending on the user's real
// clip/snippet store or localized titles wherever possible:
//   - clip rows are fed through the History search field, filtered by a per-test
//     random marker, so only this test's seeded clips surface regardless of what
//     else is already in the shared AppStore.container;
//   - command items are matched by ObjC selector, not by (localizable) title —
//     except DragonAppMenu's closure-backed App-menu items, which carry no
//     per-command selector and are matched by their DragonKit title instead.
//
// Serialized + UserDefaults save/restore because the build methods snapshot
// preferences from UserDefaults.standard and read the process-wide
// AppStore.container. Seeded rows are always removed in a defer. What can't be
// driven deterministically headlessly (live paste, Carbon hot-key registration,
// image/PDF placeholder rows that carry no searchable text) is documented in the
// PR's COVERAGE NOTES rather than tested flakily.
@Suite(.serialized) @MainActor
struct MainMenuControllerCoverageTests {

    // MARK: - Helpers

    /// Snapshot the given UserDefaults keys; the returned closure restores them.
    private func snapshotDefaults(_ keys: [String]) -> () -> Void {
        let d = UserDefaults.standard
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        return { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
    }

    /// Every item in `menu`, depth-first including submenu contents.
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for item in menu.items {
            out.append(item)
            if let sub = item.submenu { out.append(contentsOf: allItems(sub)) }
        }
        return out
    }

    /// A short random token unlikely to collide with any real clip text, kept
    /// short so it doesn't dominate a truncated menu title.
    private func marker() -> String { "Zq\(UInt32.random(in: 100_000 ... 999_999))" }

    /// Seed `values` as String clips into the shared history store, oldest first.
    /// Returns the inserted records (seed order) and a cleanup closure.
    private func seedClips(_ values: [String]) -> ([ClipRecord], () -> Void) {
        let ctx = AppStore.container.mainContext
        let base = Date(timeIntervalSince1970: 2_000_000)
        var seeded: [ClipRecord] = []
        for (i, value) in values.enumerated() {
            let date = base.addingTimeInterval(Double(i))
            let clip = ClipRecord(createdDate: date, lastUsedDate: date,
                                  typeIdentifiers: ["String"], stringValue: value,
                                  contentHash: Int.random(in: Int.min ... Int.max))
            ctx.insert(clip)
            seeded.append(clip)
        }
        try? ctx.save()
        return (seeded, { for clip in seeded { ctx.delete(clip) }; try? ctx.save() })
    }

    /// Seed one folder + its snippets into the shared snippet store. Returns the
    /// folder, its snippets, and a cleanup closure (deleting the folder cascades).
    private func seedFolder(title: String, snippets: [(String, String)]) -> (Folder, [Snippet], () -> Void) {
        let ctx = AppStore.container.mainContext
        let folder = Folder(title: title, index: Int.random(in: 1_000 ... 9_000_000))
        ctx.insert(folder)
        var made: [Snippet] = []
        for (i, pair) in snippets.enumerated() {
            let snippet = Snippet(title: pair.0, content: pair.1, index: i, folder: folder)
            ctx.insert(snippet)
            made.append(snippet)
        }
        try? ctx.save()
        return (folder, made, { ctx.delete(folder); try? ctx.save() })
    }

    /// Build the History menu, detach its delegate (so the internal `menu.update()`
    /// can't re-fire menuNeedsUpdate and wipe the filtered rows), then type `query`
    /// into its search field to drive the live filter path. Returns the menu.
    private func historyMenu(driving query: String, on controller: MainMenuController) throws -> NSMenu {
        let menu = controller.buildHistoryMenu()
        let searchView = try #require(menu.items.first?.view as? HistorySearchFieldView)
        menu.delegate = nil
        searchView.onChange?(query)
        return menu
    }

    // MARK: - MenuHotKey enum / constants

    @Test func menuHotKeyDefaultCombosMatchLegacyDefaults() {
        typealias K = MainMenuController.MenuHotKey
        #expect(K.allCases.count == 3)
        #expect(K.main.rawValue == "ClipMenu")
        #expect(K.history.rawValue == "HistoryMenu")
        #expect(K.snippets.rawValue == "SnippetsMenu")
        #expect(K.main.defaultCombo
                == HotKeyCenter.Combo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)))
        #expect(K.history.defaultCombo
                == HotKeyCenter.Combo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | controlKey)))
        #expect(K.snippets.defaultCombo
                == HotKeyCenter.Combo(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey)))
    }

    @Test func menuHotKeyLocalizedNamesAreDistinctAndNonEmpty() {
        let names = MainMenuController.MenuHotKey.allCases.map(\.localizedName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == 3)
    }

    @Test func exposedConstants() {
        #expect(MainMenuController.maxKeyEquivalents == 10)
        #expect(MainMenuController.canonicalName == "ClipMenu 2")
    }

    // MARK: - Hot-key combo storage (no Carbon registration)

    @Test func currentComboFallsBackToDefaultWhenUnset() {
        let restore = snapshotDefaults([PreferenceKeys.hotKeys])
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: PreferenceKeys.hotKeys)

        let c = MainMenuController()
        for hotKey in MainMenuController.MenuHotKey.allCases {
            #expect(c.currentCombo(for: hotKey) == hotKey.defaultCombo)
        }
    }

    @Test func currentComboReturnsStoredCombo() {
        let restore = snapshotDefaults([PreferenceKeys.hotKeys])
        defer { restore() }
        UserDefaults.standard.set(
            ["SnippetsMenu": ["keyCode": 40, "modifiers": 4096]],
            forKey: PreferenceKeys.hotKeys)

        let c = MainMenuController()
        #expect(c.currentCombo(for: .snippets) == HotKeyCenter.Combo(keyCode: 40, modifiers: 4096))
        // The unset ones still fall back to their defaults.
        #expect(c.currentCombo(for: .main) == MainMenuController.MenuHotKey.main.defaultCombo)
    }

    @Test func rebindRejectsComboAlreadyBoundToAnotherMenu() {
        let restore = snapshotDefaults([PreferenceKeys.hotKeys])
        defer { restore() }
        UserDefaults.standard.removeObject(forKey: PreferenceKeys.hotKeys)

        let c = MainMenuController()
        // Rebinding History to Main's (default) combo must be rejected before any
        // Carbon registration happens.
        let outcome = c.rebind(.history, to: c.currentCombo(for: .main))
        #expect(outcome == .conflict(.main))
    }

    // MARK: - Menu skeleton (robust to store contents)

    @Test func historyMenuStartsWithSearchFieldThenSeparator() {
        let c = MainMenuController()
        let menu = c.buildHistoryMenu()
        #expect(menu.title == "HistoryMenu")
        #expect(menu.delegate === c)
        #expect(menu.autoenablesItems == false)
        #expect(menu.items.first?.view is HistorySearchFieldView)
        #expect(menu.items.count >= 2)
        #expect(menu.items[1].isSeparatorItem)
    }

    @Test func snippetsMenuHasNoCommandItems() {
        let c = MainMenuController()
        let menu = c.buildSnippetsMenu()
        #expect(menu.title == "SnippetsMenu")
        #expect(menu.delegate === c)
        let actions = allItems(menu).compactMap(\.action)
        #expect(!actions.contains(Selector(("terminate:"))))
        #expect(!actions.contains(Selector(("showPreferences:"))))
        #expect(!actions.contains(Selector(("clearHistory:"))))
    }

    @Test func mainMenuContainsStandardCommandItems() {
        let c = MainMenuController()
        let menu = c.buildMainMenu()
        #expect(menu.title == "ClipMenu")
        let items = allItems(menu)
        let actions = Set(items.compactMap(\.action))
        let titles = items.map(\.title)
        let name = MainMenuController.canonicalName
        // Quick-actions zone (ClipMenu's own selectors) + standardized App menu
        // (DragonKit's DragonAppMenu). The App-menu items other than Quit are
        // closure-backed, so there is no per-command selector to match: they are
        // identified by the same DragonKit title the menu builder renders.
        #expect(actions.contains(Selector(("editSnippets:"))))
        #expect(titles.contains(String(format: L("DragonKit.menu.about"), name)))
        #expect(titles.contains(L("DragonKit.menu.settings")))
        #expect(actions.contains(Selector(("terminate:"))))
        // Clear History is present by default (addClearHistoryMenuItem defaults YES).
        #expect(actions.contains(Selector(("clearHistory:"))))
        // "Check for Updates…" only exists in the Sparkle build; tests build with
        // CLIPMENU_SPARKLE unset, so it must be absent.
        #expect(!titles.contains(L("DragonKit.menu.checkForUpdates")))
        // Uninstall was dropped from the canonical menu in DragonKit 2.0.0 — a rare
        // destructive action does not belong one click from Quit; it lives in Settings
        // as UninstallSettingsPane. Scoped to the App-menu tail (About → end of the
        // top level) so a clipboard entry in the zone above can't decide this.
        let appMenu = menu.items.drop { $0.title != String(format: L("DragonKit.menu.about"), name) }
        #expect(!appMenu.contains { $0.title.localizedCaseInsensitiveContains("uninstall") })

        // Settings… → ⌘, ; Quit → ⌘Q.
        let settings = try? #require(items.first { $0.title == L("DragonKit.menu.settings") })
        #expect(settings?.keyEquivalent == ",")
        #expect(settings?.keyEquivalentModifierMask == .command)
        let quit = items.first { $0.action == Selector(("terminate:")) }
        #expect(quit?.keyEquivalent == "q")
    }

    @Test func mainMenuOmitsSnippetsSectionWhenPositionIsNone() {
        let restore = snapshotDefaults([PreferenceKeys.positionOfSnippets, PreferenceKeys.groupSnippetsInFolder])
        defer { restore() }
        UserDefaults.standard.set(0, forKey: PreferenceKeys.positionOfSnippets)   // None
        UserDefaults.standard.set(true, forKey: PreferenceKeys.groupSnippetsInFolder)

        // Even with a folder present, position None means no snippet section is
        // added to the Main menu at all (addSnippetsSection is never called).
        let (_, _, cleanup) = seedFolder(title: "Zq\(UInt32.random(in: 0 ... .max))", snippets: [("a", "A")])
        defer { cleanup() }

        let c = MainMenuController()
        let menu = c.buildMainMenu()
        let titles = allItems(menu).map(\.title)
        #expect(!titles.contains(L("Snippets")))
    }

    // MARK: - Snippets menu content

    @Test func snippetsMenuGroupedNumbersSnippetsPerFolder() throws {
        let restore = snapshotDefaults([
            PreferenceKeys.groupSnippetsInFolder, PreferenceKeys.showIconInTheMenu,
            PreferenceKeys.menuItemsAreMarkedWithNumbers,
        ])
        defer { restore() }
        UserDefaults.standard.set(true, forKey: PreferenceKeys.groupSnippetsInFolder)
        UserDefaults.standard.set(true, forKey: PreferenceKeys.showIconInTheMenu)
        UserDefaults.standard.set(true, forKey: PreferenceKeys.menuItemsAreMarkedWithNumbers)

        let title = "ZqFolder\(UInt32.random(in: 0 ... .max))"
        let (_, snippets, cleanup) = seedFolder(
            title: title, snippets: [("Alpha", "alpha body"), ("Bravo", "bravo body")])
        defer { cleanup() }

        let c = MainMenuController()
        let menu = c.buildSnippetsMenu()

        // Grouped mode: a single wrapper item whose submenu holds every folder.
        let wrapper = try #require(menu.items.first { $0.submenu != nil })
        let folderItem = try #require(wrapper.submenu?.items.first { $0.title == title })
        #expect(folderItem.image != nil)                       // folder icon (showIcon on)
        let sub = try #require(folderItem.submenu)
        #expect(sub.items.count == 2)

        #expect(sub.items[0].title == "1. Alpha")
        #expect(sub.items[1].title == "2. Bravo")
        for (item, snippet) in zip(sub.items, snippets) {
            #expect(item.action == Selector(("selectSnippet:")))
            #expect(item.target === c)
            #expect((item.representedObject as? Snippet) === snippet)
            #expect(item.toolTip == snippet.content)           // full content, unconditional
            #expect(item.image != nil)                         // snippet icon
        }
    }

    @Test func snippetsMenuFlattenedPutsEachFolderAtTopLevel() throws {
        let restore = snapshotDefaults([
            PreferenceKeys.groupSnippetsInFolder, PreferenceKeys.showLabelsInMenu,
        ])
        defer { restore() }
        UserDefaults.standard.set(false, forKey: PreferenceKeys.groupSnippetsInFolder)
        UserDefaults.standard.set(true, forKey: PreferenceKeys.showLabelsInMenu)

        let title = "ZqFlat\(UInt32.random(in: 0 ... .max))"
        let (_, _, cleanup) = seedFolder(title: title, snippets: [("One", "1")])
        defer { cleanup() }

        let c = MainMenuController()
        let menu = c.buildSnippetsMenu()
        // Flattened: the folder is a top-level submenu (not nested under a wrapper).
        let folderItem = try #require(menu.items.first { $0.title == title })
        #expect(folderItem.submenu?.items.count == 1)
        #expect(folderItem.submenu?.items.first?.title == "1. One")
    }

    // MARK: - History clip rows (driven through the search filter)

    @Test func historySearchInlineClipsCarryNumbersTitlesTooltipsAndKeyEquivalents() throws {
        let restore = snapshotDefaults([
            PreferenceKeys.numberOfItemsPlaceInline, PreferenceKeys.menuItemsAreMarkedWithNumbers,
            PreferenceKeys.addNumericKeyEquivalents, PreferenceKeys.showToolTipOnMenuItem,
            PreferenceKeys.showImageInTheMenu, PreferenceKeys.showLabelsInMenu,
        ])
        defer { restore() }
        let d = UserDefaults.standard
        d.set(999, forKey: PreferenceKeys.numberOfItemsPlaceInline)      // all inline, no folders
        d.set(true, forKey: PreferenceKeys.menuItemsAreMarkedWithNumbers)
        d.set(true, forKey: PreferenceKeys.addNumericKeyEquivalents)
        d.set(true, forKey: PreferenceKeys.showToolTipOnMenuItem)
        d.set(true, forKey: PreferenceKeys.showImageInTheMenu)
        d.set(true, forKey: PreferenceKeys.showLabelsInMenu)

        let m = marker()
        let (seeded, cleanup) = seedClips(["\(m)Alpha", "\(m)Bravo", "\(m)Charlie"])
        defer { cleanup() }

        let c = MainMenuController()
        let menu = try historyMenu(driving: m, on: c)

        // Newest-first: Charlie (seeded last) is row 1.
        let clipItems = allItems(menu).filter { $0.action == Selector(("selectClip:")) }
        #expect(clipItems.count == 3)
        #expect(clipItems.map(\.title) == ["1. \(m)Charlie", "2. \(m)Bravo", "3. \(m)Alpha"])
        #expect(clipItems.map(\.keyEquivalent) == ["1", "2", "3"])

        let expectedOrder = Array(seeded.reversed())
        for (item, clip) in zip(clipItems, expectedOrder) {
            #expect(item.target === c)
            #expect((item.representedObject as? ClipRecord) === clip)
            #expect(item.toolTip == clip.stringValue)
        }
    }

    @Test func historySearchWithMarkingOffOmitsTheNumberPrefix() throws {
        let restore = snapshotDefaults([
            PreferenceKeys.numberOfItemsPlaceInline, PreferenceKeys.menuItemsAreMarkedWithNumbers,
            PreferenceKeys.addNumericKeyEquivalents,
        ])
        defer { restore() }
        UserDefaults.standard.set(999, forKey: PreferenceKeys.numberOfItemsPlaceInline)
        UserDefaults.standard.set(false, forKey: PreferenceKeys.menuItemsAreMarkedWithNumbers)
        UserDefaults.standard.set(false, forKey: PreferenceKeys.addNumericKeyEquivalents)

        let m = marker()
        let (_, cleanup) = seedClips(["\(m)Hello"])
        defer { cleanup() }

        let c = MainMenuController()
        let menu = try historyMenu(driving: m, on: c)
        let clipItem = try #require(allItems(menu).first { $0.action == Selector(("selectClip:")) })
        #expect(clipItem.title == "\(m)Hello")     // no "1. " prefix
        #expect(clipItem.keyEquivalent == "")       // numeric key equivalents off
    }

    @Test func historyClipTitleIsFirstLineTruncatedToMaxLength() throws {
        let restore = snapshotDefaults([
            PreferenceKeys.numberOfItemsPlaceInline, PreferenceKeys.menuItemsAreMarkedWithNumbers,
            PreferenceKeys.maxMenuItemTitleLength,
        ])
        defer { restore() }
        UserDefaults.standard.set(999, forKey: PreferenceKeys.numberOfItemsPlaceInline)
        UserDefaults.standard.set(false, forKey: PreferenceKeys.menuItemsAreMarkedWithNumbers)
        UserDefaults.standard.set(20, forKey: PreferenceKeys.maxMenuItemTitleLength)

        let m = marker()
        // First line only (drop everything after the newline).
        let (_, cleanupA) = seedClips(["\(m)FirstLine\nSecondLine"])
        defer { cleanupA() }
        let cA = MainMenuController()
        let menuA = try historyMenu(driving: m, on: cA)
        let firstLineItem = try #require(allItems(menuA).first { $0.action == Selector(("selectClip:")) })
        #expect(firstLineItem.title == "\(m)FirstLine")

        // Over-length single line is truncated to exactly maxMenuItemTitleLength
        // with a trailing ellipsis.
        let m2 = marker()
        let (_, cleanupB) = seedClips(["\(m2)0123456789012345678901234567890"])
        defer { cleanupB() }
        let cB = MainMenuController()
        let menuB = try historyMenu(driving: m2, on: cB)
        let longItem = try #require(allItems(menuB).first { $0.action == Selector(("selectClip:")) })
        #expect(longItem.title.count == 20)
        #expect(longItem.title.hasSuffix("..."))
    }

    // Regression (crash): maxLengthOfToolTip comes from a free-form Settings field
    // and lands in String.prefix(_:), which traps on a negative count — a stored -1
    // killed the app (SIGTRAP) on every Main/History menu build, permanently, since
    // the value is persisted. MenuPrefs clamps it to 0, so the tip is just empty.
    @Test func historyClipToolTipSurvivesNegativeMaxToolTipLength() throws {
        let restore = snapshotDefaults([
            PreferenceKeys.numberOfItemsPlaceInline, PreferenceKeys.showToolTipOnMenuItem,
            PreferenceKeys.maxLengthOfToolTipKey,
        ])
        defer { restore() }
        UserDefaults.standard.set(999, forKey: PreferenceKeys.numberOfItemsPlaceInline)
        UserDefaults.standard.set(true, forKey: PreferenceKeys.showToolTipOnMenuItem)
        UserDefaults.standard.set(-1, forKey: PreferenceKeys.maxLengthOfToolTipKey)

        let m = marker()
        let (_, cleanup) = seedClips(["\(m)Tooltip"])
        defer { cleanup() }

        let c = MainMenuController()
        let menu = try historyMenu(driving: m, on: c)
        let clipItem = try #require(allItems(menu).first { $0.representedObject is ClipRecord })
        #expect(clipItem.toolTip == "")
    }

    @Test func historySearchGroupsOverflowClipsIntoNumberedFolders() throws {
        let restore = snapshotDefaults([
            PreferenceKeys.numberOfItemsPlaceInline, PreferenceKeys.numberOfItemsPlaceInsideFolder,
        ])
        defer { restore() }
        UserDefaults.standard.set(0, forKey: PreferenceKeys.numberOfItemsPlaceInline)       // nothing inline
        UserDefaults.standard.set(2, forKey: PreferenceKeys.numberOfItemsPlaceInsideFolder) // 2 per folder

        let m = marker()
        let (_, cleanup) = seedClips(["\(m)A", "\(m)B", "\(m)C"])
        defer { cleanup() }

        let c = MainMenuController()
        let menu = try historyMenu(driving: m, on: c)

        // 3 clips, 2 per overflow folder → "1 - 2" and "3 - 3".
        let folderTitles = menu.items.filter { $0.submenu != nil }.map(\.title)
        #expect(folderTitles.contains("1 - 2"))
        #expect(folderTitles.contains("3 - 3"))
        let clipItems = allItems(menu).filter { $0.action == Selector(("selectClip:")) }
        #expect(clipItems.count == 3)
    }

    @Test func historySearchWithNoMatchesShowsDisabledPlaceholder() throws {
        let restore = snapshotDefaults([PreferenceKeys.showLabelsInMenu])
        defer { restore() }
        UserDefaults.standard.set(true, forKey: PreferenceKeys.showLabelsInMenu)

        let c = MainMenuController()
        // A marker matching nothing in the store: search field (0), separator (1),
        // "History" label (2), "No matches" (3, disabled).
        let menu = try historyMenu(driving: marker(), on: c)
        #expect(menu.numberOfItems == 4)
        let last = try #require(menu.items.last)
        #expect(last.action == nil)
        #expect(last.isEnabled == false)
    }

    // MARK: - Actions menu

    /// Run `body` with a known default action tree on disk and menu prefs at their
    /// defaults, restoring both afterward.
    private func withDefaultActions(_ body: () throws -> Void) rethrows {
        let restore = snapshotDefaults([PreferenceKeys.showIconInTheMenu, PreferenceKeys.showToolTipOnMenuItem])
        defer { restore() }
        UserDefaults.standard.set(true, forKey: PreferenceKeys.showIconInTheMenu)
        UserDefaults.standard.set(true, forKey: PreferenceKeys.showToolTipOnMenuItem)

        let url = ActionStore.saveURL
        let backup = url.flatMap { try? Data(contentsOf: $0) }
        defer {
            if let url {
                if let backup { try? backup.write(to: url) }
                else { try? FileManager.default.removeItem(at: url) }
            }
        }
        ActionStore.save(ActionStore.defaultNodes())
        try body()
    }

    @Test func actionsMenuForStringClipListsWholeDefaultTree() throws {
        try withDefaultActions {
            let c = MainMenuController()
            let clip = ClipRecord(typeIdentifiers: ["String"], stringValue: "hi", contentHash: 1)
            let menu = c.buildActionsMenu(forClip: clip, snippet: nil)

            #expect(menu.items.map(\.title) == ["Paste as Plain Text", "Case", "Trim", "Remove"])

            // Folders are submenus with their JS leaves; leaves target the controller.
            let paste = menu.items[0]
            #expect(paste.action == Selector(("selectActionItem:")))
            #expect(paste.target === c)
            #expect((paste.representedObject as? ActionInvocation)?.clip === clip)
            #expect(paste.toolTip != nil)                        // built-in tool tip

            #expect(menu.items[1].submenu?.items.count == 4)     // Case: 4 JS actions
            #expect(menu.items[2].submenu?.items.count == 3)     // Trim: 3 JS actions
            // Folder rows are submenus, not selectable actions.
            #expect(menu.items[1].action != Selector(("selectActionItem:")))

            let remove = menu.items[3]
            #expect(remove.action == Selector(("selectActionItem:")))
            #expect(remove.toolTip != nil)
        }
    }

    @Test func actionsMenuForFilenamesClipShowsOnlyRemove() throws {
        try withDefaultActions {
            let c = MainMenuController()
            // A Filenames-only clip: "Paste as Plain Text" and the JS actions need
            // String, so Case/Trim filter to empty and drop out — only the
            // all-types "Remove" survives.
            let clip = ClipRecord(typeIdentifiers: ["Filenames"], filenames: ["/tmp/x"], contentHash: 2)
            let menu = c.buildActionsMenu(forClip: clip, snippet: nil)
            #expect(menu.items.map(\.title) == ["Remove"])
        }
    }

    @Test func actionsMenuForSnippetTreatsTargetAsString() throws {
        try withDefaultActions {
            let c = MainMenuController()
            let snippet = Snippet(title: "t", content: "c")
            let menu = c.buildActionsMenu(forClip: nil, snippet: snippet)
            #expect(menu.items.map(\.title) == ["Paste as Plain Text", "Case", "Trim", "Remove"])
            #expect((menu.items[0].representedObject as? ActionInvocation)?.snippet === snippet)
        }
    }

    // MARK: - Menu icons on macOS 27

    /// macOS 27 hides an NSMenuItem's image unless the item opts in, read by name
    /// because the release SDK (macOS 26) doesn't declare the property.
    private func imagedItemsHiddenOnMacOS27(_ menu: NSMenu) -> [String] {
        let imaged = allItems(menu).filter { $0.image != nil }
        #expect(!imaged.isEmpty, "menu \(menu.title) has no imaged items to check")
        guard #available(macOS 27, *) else { return [] }
        return imaged
            .filter { $0.value(forKey: "preferredImageVisibility") as? Int != 1 }
            .map(\.title)
    }

    @Test func everyImagedItemKeepsItsIconOnMacOS27() throws {
        let restore = snapshotDefaults([
            PreferenceKeys.groupSnippetsInFolder,
            PreferenceKeys.numberOfItemsPlaceInline, PreferenceKeys.numberOfItemsPlaceInsideFolder,
        ])
        defer { restore() }
        UserDefaults.standard.set(true, forKey: PreferenceKeys.groupSnippetsInFolder)
        UserDefaults.standard.set(0, forKey: PreferenceKeys.numberOfItemsPlaceInline)
        UserDefaults.standard.set(2, forKey: PreferenceKeys.numberOfItemsPlaceInsideFolder)

        let (_, _, cleanupFolder) = seedFolder(
            title: "ZqIcons\(UInt32.random(in: 0 ... .max))", snippets: [("Alpha", "alpha body")])
        defer { cleanupFolder() }
        let m = marker()
        let (_, cleanupClips) = seedClips(["\(m)A", "\(m)B", "\(m)C"])
        defer { cleanupClips() }

        try withDefaultActions {
            let c = MainMenuController()
            let clip = ClipRecord(typeIdentifiers: ["String"], stringValue: "hi", contentHash: 1)
            #expect(imagedItemsHiddenOnMacOS27(c.buildSnippetsMenu()) == [])
            let history = try historyMenu(driving: m, on: c)
            #expect(imagedItemsHiddenOnMacOS27(history) == [])
            #expect(imagedItemsHiddenOnMacOS27(c.buildActionsMenu(forClip: clip, snippet: nil)) == [])
        }
    }
}
