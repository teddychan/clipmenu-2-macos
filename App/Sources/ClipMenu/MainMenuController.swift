import AppKit
import Carbon.HIToolbox
import SwiftData
import DragonKit

// Main (⌘⇧V), History (⌘⌃V) and Snippets (⌘⇧B) menu hot-keys and the menus
// they pop up.
//
// Legacy parity:
//  - Default combos (AppController.m:81/85/89; legend at AppController.m:67-76):
//    Main = keyCode 9 'v' + 768 (command|shift); History = 9 'v' + 4352
//    (command|control); Snippets = keyCode 11 'b' + 768 (command|shift).
//  - Hot-key → action: AppController.m:442-445 (popUpClipMenu → Main),
//    483-485 (popUpHistoryMenu → History), 488-491 (popUpSnippetsMenu → Snippets).
//  - Menus + cursor pop-up: MenuController.m:443-508 (pop up at the mouse),
//    515-556 (`_buildClipMenu`), 1061-1069 (`_makeHistoryMenu` = clips only),
//    1071-1081 (`_makeSnippetsMenu` = folders/snippets only),
//    558-651 (`_addClipsToMenu`) and 653-739 (`_addSnippetsToMenu`).
//  - Snippet ordering/enabled display: SnippetsController.m:39-43 (index asc),
//    MenuController.m:687-733 (enabled folders → enabled snippets).

/// Carries the action node + its target (clip or snippet) on an Actions-menu
/// item's `representedObject` (legacy set the action dict as representedObject and
/// the selected clip/snippet via ActionController).
@MainActor
final class ActionInvocation {
    let node: ActionNode
    let clip: ClipRecord?
    let snippet: Snippet?
    init(node: ActionNode, clip: ClipRecord?, snippet: Snippet?) {
        self.node = node
        self.clip = clip
        self.snippet = snippet
    }
}

@MainActor
final class MainMenuController: NSObject, NSMenuDelegate {

    /// Shared instance so the SwiftUI Settings scene (Shortcuts recorders) and
    /// the AppKit menu layer act on the same registration state.
    static let shared = MainMenuController()

    /// The three menu hot-keys: legacy identifiers + default combos
    /// (AppController.m:81/85/89; CMUtilities.m:174-205 maps identifier→selector).
    enum MenuHotKey: String, CaseIterable {
        case main = "ClipMenu"          // kClipMenuIdentifier
        case history = "HistoryMenu"    // kHistoryMenuIdentifier
        case snippets = "SnippetsMenu"  // kSnippetsMenuIdentifier

        /// Legacy default combos (AppController.m:81/85/89).
        var defaultCombo: HotKeyCenter.Combo {
            switch self {
            case .main:     return .init(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
            case .history:  return .init(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | controlKey))
            case .snippets: return .init(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey))
            }
        }

        /// Localized menu name, shown in the shortcut recorder's conflict feedback.
        /// `L()` is main-actor isolated; the only caller (the recorder) is too.
        @MainActor var localizedName: String {
            switch self {
            case .main:     return L("Main menu")
            case .history:  return L("History menu")
            case .snippets: return L("Snippets menu")
            }
        }
    }

    /// Result of a live rebind, so the shortcut recorder can explain a rejection
    /// instead of only beeping (see ShortcutRecorderControl).
    enum RebindOutcome: Equatable {
        case bound                       // registered live
        case conflict(MenuHotKey)        // already assigned to another menu hot-key
        case registrationFailed          // Carbon refused it (e.g. system-owned combo)
    }

    /// Live Carbon hot-key id per identifier, so we can unregister on rebind.
    private var registeredHotKeyIDs: [MenuHotKey: UInt32] = [:]

    /// Cached per-type / folder / snippet menu icons (row 52).
    private let iconCache = MenuIconCache()

    /// Cached downsampled image thumbnails (row 53).
    private let thumbnailer = Thumbnailer()

    /// Type-to-filter for the History menu (⌘⌃V). The search field is the menu's
    /// top item; `historySearchQuery` holds the current text and `fetchClips()`
    /// filters by it. Empty for every other menu, so the Main menu is unaffected.
    private lazy var historySearchFieldView: HistorySearchFieldView = {
        let view = HistorySearchFieldView()
        view.onChange = { [weak self] query in self?.historyQueryDidChange(query) }
        return view
    }()
    private weak var historyMenu: NSMenu?
    private var historySearchQuery = ""

    /// Snapshot of the preferences consulted while building a menu, captured once
    /// per open at the top of each `populate*` entry point. The per-clip helpers
    /// read these from memory instead of hitting `UserDefaults` for every row —
    /// a 20-clip menu otherwise performs ~200 dictionary lookups per open. Each
    /// default mirrors the call site's former `?? value` fallback, so behavior
    /// is unchanged.
    private struct MenuPrefs {
        var showLabels = true
        var showIcons = true
        var markWithNumbers = true
        var showImages = true
        var showToolTips = true
        var addNumericKeyEquivalents = false
        var thumbnailMaxSize = 64
        var maxToolTipLength = 200
        var maxTitleLength = 20
        var groupSnippetsInFolder = true

        static func current() -> MenuPrefs {
            let d = UserDefaults.standard
            var p = MenuPrefs()
            p.showLabels = d.object(forKey: PreferenceKeys.showLabelsInMenu) as? Bool ?? true
            p.showIcons = d.object(forKey: PreferenceKeys.showIconInTheMenu) as? Bool ?? true
            p.markWithNumbers = d.object(forKey: PreferenceKeys.menuItemsAreMarkedWithNumbers) as? Bool ?? true
            p.showImages = d.object(forKey: PreferenceKeys.showImageInTheMenu) as? Bool ?? true
            p.showToolTips = d.object(forKey: PreferenceKeys.showToolTipOnMenuItem) as? Bool ?? true
            p.addNumericKeyEquivalents = d.object(forKey: PreferenceKeys.addNumericKeyEquivalents) as? Bool ?? false
            // Clamp to the stored thumbnail's usable range (16…256); a wild
            // UserDefaults value can't blow up menu row heights or exceed the
            // stored resolution.
            let rawThumb = d.object(forKey: PreferenceKeys.thumbnailMaxSize) as? Int ?? 64
            p.thumbnailMaxSize = min(256, max(16, rawThumb))
            // Clamp to a non-negative length: `clipToolTip` feeds this to
            // String.prefix(_:), which traps on a negative count — a wild
            // UserDefaults value would crash on every menu build.
            let rawTip = d.object(forKey: PreferenceKeys.maxLengthOfToolTipKey) as? Int ?? 200
            p.maxToolTipLength = max(0, rawTip)
            p.maxTitleLength = d.object(forKey: PreferenceKeys.maxMenuItemTitleLength) as? Int ?? 20
            p.groupSnippetsInFolder = d.object(forKey: PreferenceKeys.groupSnippetsInFolder) as? Bool ?? true
            return p
        }
    }

    /// The current snapshot, refreshed at the top of each `populate*` call.
    private var menuPrefs = MenuPrefs()

    /// showIconInTheMenu (default YES, AppController.m:162).
    private var showsMenuIcons: Bool { menuPrefs.showIcons }

    /// Register all three menu hot-keys from stored combos, falling back to the
    /// legacy defaults — mirrors AppController.m:601-633 (`_registerHotKeys`).
    /// RegisterEventHotKey needs no Accessibility/TCC (only synthetic event
    /// posting does), so this works for a background agent without prompting.
    func registerAllMenuHotKeys() {
        for hotKey in MenuHotKey.allCases { register(hotKey) }
    }

    /// (Re)register one hot-key: unregister the previous binding, then register
    /// the current combo. Used at launch and for live rebinding. Returns false
    /// when Carbon refused the registration (the previous binding is gone then;
    /// callers that care should restore and re-register).
    @discardableResult
    private func register(_ hotKey: MenuHotKey) -> Bool {
        if let oldID = registeredHotKeyIDs[hotKey] {
            HotKeyCenter.shared.unregister(oldID)
            registeredHotKeyIDs[hotKey] = nil
        }
        guard let id = HotKeyCenter.shared.register(currentCombo(for: hotKey), action: { [weak self] in
            self?.popUp(hotKey)
        }) else { return false }
        registeredHotKeyIDs[hotKey] = id
        return true
    }

    /// Pause/resume the three menu hot-keys while a shortcut recorder is
    /// recording. Carbon hot-keys swallow their keystroke system-wide (the app
    /// gets kEventHotKeyPressed instead of keyDown), so without this the
    /// recorder can never capture a combo that is currently bound — pressing
    /// it pops the menu over the Settings window instead.
    func setMenuHotKeysSuspended(_ suspended: Bool) {
        if suspended {
            for id in registeredHotKeyIDs.values { HotKeyCenter.shared.unregister(id) }
            registeredHotKeyIDs.removeAll()
        } else {
            registerAllMenuHotKeys()
        }
    }

    private func popUp(_ hotKey: MenuHotKey) {
        switch hotKey {
        case .main:     popUpMainMenuAtCursor()
        case .history:  popUpHistoryMenuAtCursor()
        case .snippets: popUpSnippetsMenuAtCursor()
        }
    }

    // MARK: Hot-key binding storage (Shortcuts recorder)

    /// Rebind from the recorder: persist the new combo and re-register live —
    /// PrefsWindowController.m:582-613 (change handler) + the KVO-driven
    /// re-register at AppController.m:601-633. Returns `.conflict` (binding
    /// unchanged) when the combo is already assigned to another menu — Carbon
    /// registers non-exclusively, so one keystroke would pop both menus — or
    /// `.registrationFailed` when Carbon refuses the registration (the previous
    /// binding is restored). `.bound` on success.
    @discardableResult
    func rebind(_ hotKey: MenuHotKey, to combo: HotKeyCenter.Combo) -> RebindOutcome {
        if let other = Self.conflictingHotKey(for: combo, excluding: hotKey, current: { currentCombo(for: $0) }) {
            return .conflict(other)
        }
        let previous = currentCombo(for: hotKey)
        storeCombo(combo, for: hotKey)
        if register(hotKey) { return .bound }
        // Registration failed (e.g. a system-owned combo): restore the
        // previous working binding instead of silently losing it.
        storeCombo(previous, for: hotKey)
        register(hotKey)
        return .registrationFailed
    }

    /// The other menu hot-key already bound to `combo`, or nil. Pure + injected
    /// lookup so the conflict rule is unit-testable.
    static func conflictingHotKey(for combo: HotKeyCenter.Combo,
                                  excluding hotKey: MenuHotKey,
                                  current: (MenuHotKey) -> HotKeyCenter.Combo) -> MenuHotKey? {
        MenuHotKey.allCases.first { $0 != hotKey && current($0) == combo }
    }

    /// Current combo = stored (`hotKeys` defaults) or the legacy default.
    func currentCombo(for hotKey: MenuHotKey) -> HotKeyCenter.Combo {
        storedCombo(for: hotKey) ?? hotKey.defaultCombo
    }

    private func storedCombo(for hotKey: MenuHotKey) -> HotKeyCenter.Combo? {
        guard let all = UserDefaults.standard.dictionary(forKey: PreferenceKeys.hotKeys),
              let entry = all[hotKey.rawValue] as? [String: Int],
              let code = entry["keyCode"], let mods = entry["modifiers"] else { return nil }
        return .init(keyCode: UInt32(code), modifiers: UInt32(mods))
    }

    /// Persist in the legacy `hotKeys` schema: {identifier: {keyCode, modifiers}}
    /// with Carbon modifier masks (PTKeyCombo plistRepresentation).
    private func storeCombo(_ combo: HotKeyCenter.Combo, for hotKey: MenuHotKey) {
        var all = UserDefaults.standard.dictionary(forKey: PreferenceKeys.hotKeys) ?? [:]
        all[hotKey.rawValue] = ["keyCode": Int(combo.keyCode), "modifiers": Int(combo.modifiers)]
        UserDefaults.standard.set(all, forKey: PreferenceKeys.hotKeys)
    }

    /// Build the Main menu in the legacy order (MenuController.m:515-556).
    /// Delegate-populated so live clip/snippet changes appear on each open.
    func buildMainMenu() -> NSMenu {
        let menu = NSMenu(title: "ClipMenu")
        menu.delegate = self
        menu.autoenablesItems = false
        populateMainMenu(menu)
        return menu
    }

    private func populateMainMenu(_ menu: NSMenu) {
        menuPrefs = .current()
        // Legacy registered default (AppController.m:152): YES.
        let addClearHistoryMenuItem = UserDefaults.standard.object(forKey: PreferenceKeys.addClearHistoryMenuItem) as? Bool ?? true

        // Snippets above clips / clips / snippets below clips, per positionOfSnippets
        // (MenuController.m:524-532). Default is Below (AppController.m:188).
        let position = snippetsPosition()
        if position == .above { addSnippetsSection(to: menu, position: .above) }
        addClipsSection(to: menu)
        if position == .below { addSnippetsSection(to: menu, position: .below) }

        menu.addItem(.separator())

        // Quick-actions zone (Liquid Glass §5A): the app's most-frequent actions,
        // directly above the standardized App menu.
        if addClearHistoryMenuItem {
            let clear = NSMenuItem(title: L("Clear History"),
                                   action: #selector(clearHistory(_:)), keyEquivalent: "")
            clear.target = self
            // Enabled only when history is non-empty (AppController.m:384-388, validateMenuItem).
            clear.isEnabled = clipCount() > 0
            menu.addItem(clear)
        }

        let editSnippets = NSMenuItem(title: L("Edit Snippets…"),
                                      action: #selector(editSnippets(_:)), keyEquivalent: "")
        editSnippets.target = self
        menu.addItem(editSnippets)

        addAppMenuSection(to: menu)

        applyMenuFont(to: menu)
    }

    /// History menu = clips only, no snippets or command items
    /// (MenuController.m:1061-1069, `_makeHistoryMenu`).
    func buildHistoryMenu() -> NSMenu {
        let menu = NSMenu(title: "HistoryMenu")
        menu.delegate = self
        menu.autoenablesItems = false
        populateHistoryMenu(menu)
        return menu
    }

    private func populateHistoryMenu(_ menu: NSMenu) {
        menuPrefs = .current()
        historyMenu = menu
        // Search field on top, then a separator that the live rebuild never
        // removes — keeping it as a stable anchor means the field (and its key
        // focus) survives while the user types and the clip rows below refresh.
        let searchItem = NSMenuItem()
        searchItem.view = historySearchFieldView
        menu.addItem(searchItem)
        menu.addItem(.separator())
        addClipsSection(to: menu)
        applyMenuFont(to: menu)
    }

    /// Snippets menu = folders/snippets only, no clips or command items
    /// (MenuController.m:1071-1081, `_makeSnippetsMenu`, position None).
    func buildSnippetsMenu() -> NSMenu {
        let menu = NSMenu(title: "SnippetsMenu")
        menu.delegate = self
        menu.autoenablesItems = false
        populateSnippetsMenu(menu)
        return menu
    }

    private func populateSnippetsMenu(_ menu: NSMenu) {
        menuPrefs = .current()
        addSnippetsSection(to: menu, position: .none)
        applyMenuFont(to: menu)
    }

    // MARK: - NSMenuDelegate (live refresh)

    /// Repopulate a menu just before it opens, so newly captured clips / edited
    /// snippets appear without rebuilding the status item's menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Every fresh open starts unfiltered; only live typing in the History
        // search field sets a query (see historyQueryDidChange). Resetting here
        // also keeps a stale query from leaking into the Main/Snippets menus.
        historySearchQuery = ""
        switch menu.title {
        case "ClipMenu":     populateMainMenu(menu)
        case "HistoryMenu":
            historySearchFieldView.reset()
            populateHistoryMenu(menu)
        case "SnippetsMenu": populateSnippetsMenu(menu)
        default: break
        }
    }

    /// Focus the History menu's search field as soon as it opens, so the user can
    /// type to filter right away. Deferred one main-actor hop because the field's
    /// hosting window only exists once the menu is on screen.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu.title == "HistoryMenu" else { return }
        Task { @MainActor [weak self] in self?.historySearchFieldView.focus() }
    }

    /// Re-filter the open History menu as the user types. The search field (item 0)
    /// and its separator (item 1) stay put; every clip row below is rebuilt from
    /// the filtered list. A disabled "No matches" row is shown when a non-empty
    /// query matches nothing.
    private func historyQueryDidChange(_ query: String) {
        historySearchQuery = query
        guard let menu = historyMenu else { return }
        while menu.numberOfItems > 2 { menu.removeItem(at: menu.numberOfItems - 1) }
        menuPrefs = .current()
        // Fetch + filter once per keystroke and reuse it for both the rows and the
        // "No matches" check — the previous code ran the bounded fetch and the
        // Swift filter twice on every keystroke (the search hot path).
        let clips = fetchClips()
        addClipsSection(to: menu, clips: clips)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, clips.isEmpty {
            let none = NSMenuItem(title: L("No matches"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        applyMenuFont(to: menu)
        menu.update()
    }

    /// Snippet position, mirroring `CMPositionOfSnippets` (MenuController.h:18-22).
    enum SnippetsPosition { case none, above, below }

    /// Adds the snippet section — legacy `_addSnippetsToMenu:atPosition:`
    /// (MenuController.m:653-739). Every folder (index asc) becomes a submenu of
    /// its snippets (index asc). A disabled "Snippets" label is shown when
    /// `showLabelsInMenu`. Below/Above add a bounding separator; None (the
    /// dedicated Snippets menu) adds neither. Nothing is added at all when there
    /// are no folders (MenuController.m:657-659), so the Main menu is unchanged
    /// while the store is empty.
    private func addSnippetsSection(to menu: NSMenu, position: SnippetsPosition) {
        let folders = fetchFolders()
        guard !folders.isEmpty else { return }

        if position == .below { menu.addItem(.separator()) }

        if menuPrefs.groupSnippetsInFolder {
            // Grouped: a single "Snippets" item whose submenu holds every folder,
            // keeping the menu compact. The item itself is the label, so the
            // separate "Snippets" header is redundant and omitted here.
            let snippetsItem = NSMenuItem(title: L("Snippets"), action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: L("Snippets"))
            submenu.autoenablesItems = false
            snippetsItem.submenu = submenu
            if showsMenuIcons {
                snippetsItem.image = iconCache.folderIcon
                snippetsItem.keepImageVisible()
            }
            menu.addItem(snippetsItem)
            addFolderItems(folders, to: submenu)
        } else {
            // Flattened: each folder is a top-level submenu, with an optional
            // disabled "Snippets" header when showLabelsInMenu is on.
            if menuPrefs.showLabels {
                let label = NSMenuItem(title: L("Snippets"),
                                       action: nil, keyEquivalent: "")
                label.isEnabled = false
                menu.addItem(label)
            }
            addFolderItems(folders, to: menu)
        }

        if position == .above { menu.addItem(.separator()) }
    }

    /// Append one submenu per folder (index asc) to `target`, each containing the
    /// folder's snippets (index asc). Snippets are numbered per folder from 1 with
    /// a trimmed title; marking honors menuItemsAreMarkedWithNumbers.
    private func addFolderItems(_ folders: [Folder], to target: NSMenu) {
        for folder in folders {
            let folderItem = NSMenuItem(title: folder.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: folder.title)
            submenu.autoenablesItems = false
            folderItem.submenu = submenu
            if showsMenuIcons {
                folderItem.image = iconCache.folderIcon
                folderItem.keepImageVisible()
            }
            target.addItem(folderItem)

            var number = 1
            let snippets = (folder.snippets ?? [])
                .sorted { $0.index < $1.index }
            for snippet in snippets {
                let item = NSMenuItem(title: markedTitle(trimTitle(snippet.title), number: number),
                                      action: #selector(selectSnippet(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = snippet
                item.toolTip = snippet.content // full content, unconditional (MenuController.m:888)
                if showsMenuIcons {
                    item.image = iconCache.snippetIcon
                    item.keepImageVisible()
                }
                submenu.addItem(item)
                number += 1
            }
        }
    }

    /// Fetch snippet folders sorted by `index` ascending
    /// (SnippetsController.m:39-43, 182-203). Read-only, on the main context;
    /// folder/snippet counts are small, so this stays cheap per menu open.
    private func fetchFolders() -> [Folder] {
        let descriptor = FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.index, order: .forward)])
        return (try? AppStore.container.mainContext.fetch(descriptor)) ?? []
    }

    /// Snippet placement for the Main menu (default Below — AppController.m:188).
    private func snippetsPosition() -> SnippetsPosition {
        let raw = UserDefaults.standard.object(forKey: PreferenceKeys.positionOfSnippets) as? Int ?? 2
        switch raw {
        case 1: return .above
        case 2: return .below
        default: return .none
        }
    }

    /// The clip section shared by the Main and History menus — legacy
    /// `_addClipsToMenu` (MenuController.m:558-651), called from both
    /// `_buildClipMenu` and `_makeHistoryMenu`. With `showLabelsInMenu` on
    /// (default), a disabled "History" label is shown even with zero clips
    /// (MenuController.m:574-582). Clip items are added once clipboard capture
    /// (§D) is implemented.
    private func addClipsSection(to menu: NSMenu, clips preloaded: [ClipRecord]? = nil) {
        let showLabelsInMenu = menuPrefs.showLabels
        if showLabelsInMenu {
            let label = NSMenuItem(title: L("History"),
                                   action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
        }

        // Clip layout (MenuController.m:558-651): the first
        // `numberOfItemsPlaceInline` clips appear inline; the rest are grouped
        // into "N - M" overflow folders of `numberOfItemsPlaceInsideFolder`.
        // Default inline=0 → every clip goes into folders (AppController.m:146-147).
        let defaults = UserDefaults.standard
        let inlineCount = max(defaults.object(forKey: PreferenceKeys.numberOfItemsPlaceInline) as? Int ?? 0, 0)
        let perFolder = max(defaults.object(forKey: PreferenceKeys.numberOfItemsPlaceInsideFolder) as? Int ?? 10, 1)

        // Display numbering: clips are marked "N. " when menuItemsAreMarkedWithNumbers
        // (default YES), as a CONTINUOUS running number 1,2,…,N across overflow
        // folders.
        let clips = preloaded ?? fetchClips()
        let total = clips.count
        for (i, clip) in clips.enumerated() {
            let listNumber = i + 1
            if inlineCount >= 1, i < inlineCount {
                menu.addItem(makeClipMenuItem(clip, count: i, listNumber: listNumber))
            } else {
                let offset = i - inlineCount
                if offset.isMultiple(of: perFolder) {
                    let folderBase = inlineCount + (offset / perFolder) * perFolder
                    menu.addItem(makeClipFolderItem(count: folderBase, total: total,
                                                    perFolder: perFolder))
                }
                menu.items.last?.submenu?.addItem(makeClipMenuItem(clip, count: i, listNumber: listNumber))
            }
        }
    }

    /// A selectable clip menu item; choosing it copies the clip and pastes it
    /// into the frontmost app (see `selectClip`).
    /// `count` is the clip's overall index, used for the numeric key-equivalent.
    private func makeClipMenuItem(_ clip: ClipRecord, count: Int, listNumber: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(selectClip(_:)),
                              keyEquivalent: clipKeyEquivalent(count: count))
        item.target = self
        item.representedObject = clip
        item.toolTip = clipToolTip(clip)
        if let thumbnail = clipThumbnail(clip) {
            // Image clips: "N." then the picture inline AFTER it, no "(Image)" text
            // and no leading icon (user request 2026-05-31). Uses an attributed
            // title so the thumbnail trails the number and standard highlight works.
            item.attributedTitle = clipImageTitle(number: listNumber, thumbnail: thumbnail)
        } else {
            item.title = markedTitle(clipMenuTitle(clip), number: listNumber)
            // No leading per-type icon on history clips — the generic document
            // glyph crowded the number without adding info (user request
            // 2026-05-31), matching the image-clip path above. Folder/snippet
            // icons (which are structural) are kept. Legacy showed it here
            // (MenuController.m:828-846); intentional parity deviation.
        }
        return item
    }

    /// "N. " followed by the thumbnail as an inline text attachment (image after
    /// the number). The prefix uses labelColor + the menu font so it renders
    /// correctly on the (dark/light) menu, since an attributed title bypasses the
    /// menu's default text color.
    private func clipImageTitle(number: Int, thumbnail: NSImage) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if menuPrefs.markWithNumbers {
            result.append(NSAttributedString(string: "\(number). ", attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: menuFont() ?? NSFont.menuFont(ofSize: 0),
            ]))
        }
        let attachment = NSTextAttachment()
        attachment.image = thumbnail
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    /// Downsampled thumbnail for an image clip, or nil — MenuController.m:828-840.
    /// Shown when showImageInTheMenu (default YES) and the clip carries image data
    /// and isn't a Filenames clip. Fit into a square box whose side is the user's
    /// thumbnailMaxSize (longest side, aspect-preserved, never upscaled).
    private func clipThumbnail(_ clip: ClipRecord) -> NSImage? {
        guard menuPrefs.showImages,
              clip.typeIdentifiers.first != "Filenames" else { return nil }
        let side = CGFloat(menuPrefs.thumbnailMaxSize)
        return thumbnailer.thumbnail(for: clip,
                                     fitting: NSSize(width: side, height: side))
    }

    /// Clip tool tip: the full string truncated to maxLengthOfToolTip (default
    /// 200), only when showToolTipOnMenuItem (default YES) — MenuController.m:795-802.
    /// Non-string clips (no stringValue) get no tip, as in legacy.
    private func clipToolTip(_ clip: ClipRecord) -> String? {
        guard menuPrefs.showToolTips,
              let string = clip.stringValue else { return nil }
        return String(string.prefix(menuPrefs.maxToolTipLength))
    }

    // MARK: - Display numbering

    /// "N. title" when menuItemsAreMarkedWithNumbers (default YES), else the title.
    private func markedTitle(_ title: String, number: Int) -> String {
        menuPrefs.markWithNumbers ? "\(number). \(title)" : title
    }

    // MARK: - Menu font size (MenuController.m:144-178, makeAttributedTitle)

    /// The custom menu font, or nil to use the system default. `nil` when
    /// changeFontSize is off (default). howToChangeFontSize 0 → size tracks the
    /// icon size (16→14, 32→28, 48→42 pt) when icons are shown; 1 → selectedFontSize.
    private func menuFont() -> NSFont? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PreferenceKeys.changeFontSize) as? Bool ?? false else { return nil }

        var size: CGFloat = 14 // DEFAULT_MENU_FONT_SIZE
        let how = defaults.object(forKey: PreferenceKeys.howToChangeFontSize) as? Int ?? 0
        if how == 0 {
            if defaults.object(forKey: PreferenceKeys.showIconInTheMenu) as? Bool ?? true {
                switch defaults.object(forKey: PreferenceKeys.menuIconSize) as? Int ?? 16 {
                case 32: size = 28 // LARGE_MENU_FONT_SIZE for LARGE_ICON_SIZE
                case 48: size = 42 // HUGE_MENU_FONT_SIZE for HUGE_ICON_SIZE
                default: break
                }
            }
        } else if how == 1 {
            size = CGFloat((defaults.object(forKey: PreferenceKeys.selectedFontSize) as? NSNumber)?.doubleValue ?? 14)
        }
        return NSFont.systemFont(ofSize: size)
    }

    /// Apply the custom menu font to every selectable/folder item (clips,
    /// snippets, folders, commands) — not the disabled labels or separators —
    /// recursing into submenus. Mirrors legacy applying makeAttributedTitle to
    /// clip/snippet/submenu/command items but not the History/Snippets labels.
    private func applyMenuFont(to menu: NSMenu) {
        guard let font = menuFont() else { return }
        applyFont(font, to: menu)
    }

    private func applyFont(_ font: NSFont, to menu: NSMenu) {
        for item in menu.items {
            if item.isSeparatorItem { continue }
            let isLabel = (item.action == nil && item.submenu == nil)
            // Preserve image-clip titles (they carry an inline thumbnail attachment
            // built with the menu font already); rebuilding from item.title would
            // drop the picture.
            var hasAttachment = false
            if let title = item.attributedTitle, title.length > 0 {
                hasAttachment = title.containsAttachments(in: NSRange(location: 0, length: title.length))
            }
            if !isLabel, !hasAttachment {
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
            }
            if let submenu = item.submenu { applyFont(font, to: submenu) }
        }
    }

    /// Max items that get a numeric key-equivalent (kMaxKeyEquivalents, MenuController.m:23).
    static let maxKeyEquivalents = 10

    /// Numeric key-equivalent for the clip at overall index `count`. Off by
    /// default (addNumericKeyEquivalents = NO). Digits 1–9 then 0 for the first
    /// ten clips; snippets and the 11th-plus clips get none.
    private func clipKeyEquivalent(count: Int) -> String {
        Self.numericKeyEquivalent(forIndex: count, enabled: menuPrefs.addNumericKeyEquivalents)
    }

    /// Pure numbering rule (unit-testable): the first ten 0-based indices map to
    /// "1"…"9","0"; anything at or beyond maxKeyEquivalents gets "" — a
    /// two-character string like "11" is not a valid single-char key equivalent.
    static func numericKeyEquivalent(forIndex index: Int, enabled: Bool) -> String {
        guard enabled, index >= 0, index < maxKeyEquivalents else { return "" }
        let shortcut = index + 1
        return shortcut == maxKeyEquivalents ? "0" : "\(shortcut)"
    }

    /// An overflow-folder submenu item titled "N - M". `count` is the running
    /// offset of the first clip in this folder.
    private func makeClipFolderItem(count: Int, total: Int, perFolder: Int) -> NSMenuItem {
        let base = count
        let lastNumber = min(base + perFolder, total)
        let folderItem = NSMenuItem(title: "\(base + 1) - \(lastNumber)", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "ClipFolder")
        submenu.autoenablesItems = false
        folderItem.submenu = submenu
        if showsMenuIcons {
            folderItem.image = iconCache.folderIcon
            folderItem.keepImageVisible()
        }
        return folderItem
    }

    /// Clips for display: sorted (lastUsed/created desc) and capped to
    /// maxHistorySize (ClipsController.m:190-212; AppController.m:135). Read-only
    /// on the main context.
    private func fetchClips() -> [ClipRecord] {
        // Shared bounded-history policy (newest-first, capped to maxHistorySize)
        // used by the menu, this search, and Export… (ClipStore). The original
        // image lives in the faulted `ClipRecord.image` relationship, so fetching
        // for the menu never loads the multi-MB bytes; only paste does
        // (design-invariants.md — Images and memory). The menu renders from the
        // small `thumbnailData` column on the row.
        var descriptor = ClipStore.boundedHistoryDescriptor()
        // History-menu search (⌘⌃V): filter in the store instead of fetching every
        // row and filtering in Swift on each keystroke — the search hot path. The
        // query is empty for the Main/Snippets menus, so this is a no-op there.
        // Storage is trimmed to maxHistorySize on every capture, so the store
        // already holds the whole history the user chose to keep; the predicate
        // therefore searches all of it while materializing only the matches, which
        // stays fast even with a large history
        // (design-invariants.md — History bound). `localizedStandardContains` is
        // the case/diacritic-insensitive, Finder-style match SwiftData can push
        // into SQLite. Image-only clips (no stringValue) never match, as expected.
        let query = historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            descriptor.predicate = ClipStore.searchPredicate(query)
        }
        return (try? AppStore.container.mainContext.fetch(descriptor)) ?? []
    }

    /// Menu title for a clip: trimmed first line, or a type placeholder
    /// (MenuController.m:810-826).
    private func clipMenuTitle(_ clip: ClipRecord) -> String {
        let base = trimTitle(clip.stringValue)
        switch clip.typeIdentifiers.first {
        case "TIFF": return L("(Image)")
        case "PDF":  return L("(PDF)")
        case "Filenames": return base.isEmpty ? L("(Filenames)") : base
        default: return base
        }
    }

    /// First line, whitespace-stripped, truncated with "..." to
    /// maxMenuItemTitleLength (MenuController.m:112-142; default 20).
    private func trimTitle(_ string: String?) -> String {
        guard let string else { return "" }
        let stripped = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = String(stripped.prefix { $0 != "\n" && $0 != "\r" })
        let shortenLength = 3 // "..."
        var maxLength = menuPrefs.maxTitleLength
        if maxLength < shortenLength { maxLength = shortenLength }
        if title.count > maxLength {
            title = String(title.prefix(maxLength - shortenLength)) + "..."
        }
        return title
    }

    /// Pop the Main menu up at the mouse cursor. Modern replacement for the legacy
    /// dummy-window + `popUpContextMenu:withEvent:` technique (MenuController.m:443-508):
    /// `NSMenu.popUp(positioning:at:in:)` with a nil view interprets the point in
    /// screen coordinates, which is exactly the cursor location.
    func popUpMainMenuAtCursor() {
        popUpAtCursor(buildMainMenu())
    }

    /// Pop the History menu up at the mouse cursor (AppController.m:483-485).
    func popUpHistoryMenuAtCursor() {
        popUpAtCursor(buildHistoryMenu())
    }

    /// Pop the Snippets menu up at the mouse cursor (AppController.m:488-491).
    func popUpSnippetsMenuAtCursor() {
        popUpAtCursor(buildSnippetsMenu())
    }

    /// Pop `menu` up at the mouse cursor, lifting the anchor when a tall menu would
    /// otherwise be clipped at the bottom of the screen. `popUp` places the menu's
    /// top-left at the anchor and grows it downward; near the screen bottom macOS
    /// falls back to scroll arrows instead of moving the menu up, which hides items.
    /// We measure the menu and raise the anchor so the whole menu stays on screen.
    private func popUpAtCursor(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: cursorAnchor(for: menu), in: nil)
    }

    /// Cursor location adjusted upward so `menu` fits within the visible screen.
    private func cursorAnchor(for menu: NSMenu) -> NSPoint {
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main else { return cursor }
        let visible = screen.visibleFrame
        let menuHeight = menu.size.height
        // Screen coords have a bottom-left origin; the menu spans [y - menuHeight, y].
        // If the bottom would fall below the visible area, raise the anchor so the
        // menu rests on the visible bottom, but never push the top off the top edge.
        guard cursor.y - menuHeight < visible.minY else { return cursor }
        let y = min(visible.maxY, visible.minY + menuHeight)
        return NSPoint(x: cursor.x, y: y)
    }

    // MARK: - Menu actions

    @objc private func clearHistory(_ sender: Any?) {
        // Confirm (with a "don't ask again" suppression) when showAlertBeforeClearHistory
        // is on (default YES), then clear all clips (AppController.m:411-440).
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PreferenceKeys.showAlertBeforeClearHistory) as? Bool ?? true {
            let alert = NSAlert()
            alert.messageText = L("Clear History")
            alert.informativeText = L("Are you sure you want to clear your clipboard history?")
            alert.addButton(withTitle: L("Clear History"))
            alert.addButton(withTitle: L("Cancel"))
            alert.showsSuppressionButton = true

            NSApp.activate(ignoringOtherApps: true)
            let result = alert.runModal()
            if alert.suppressionButton?.state == .on {
                defaults.set(false, forKey: PreferenceKeys.showAlertBeforeClearHistory)
            }
            guard result == .alertFirstButtonReturn else { return }
        }
        clearAllClips()
    }

    /// Delete every clip (ClipsController clearAll). Run on the main context; a
    /// clear is an infrequent, explicit user action.
    private func clearAllClips() {
        let context = AppStore.container.mainContext
        guard let all = try? context.fetch(FetchDescriptor<ClipRecord>()) else { return }
        for clip in all { context.delete(clip) }
        try? context.save()
        // The pre-2.3 combined store kept as a migration backup still holds the
        // full pre-upgrade history in plaintext; an explicit clear removes it too.
        StoreMigration.deleteLegacyBackupIfMigrated(folder: AppStore.folder)
    }

    /// Cheap count of stored clips (SQL COUNT), for the Clear History enabled state.
    private func clipCount() -> Int {
        (try? AppStore.container.mainContext.fetchCount(FetchDescriptor<ClipRecord>())) ?? 0
    }

    @objc private func editSnippets(_ sender: Any?) {
        // Open the Snippet Editor window (SnippetEditorController.m showWindow).
        SnippetEditorWindowController.shared.show()
    }

    @objc private func selectClip(_ sender: NSMenuItem) {
        guard let stale = sender.representedObject as? ClipRecord else { return }
        // While the menu was open, a background capture can have trimmed this
        // row from the ClipStore actor's context. Re-resolve against the store
        // so we never fault (or paste from) a deleted model.
        guard let clip = Self.liveClip(matching: stale, in: AppStore.container.mainContext) else { return }
        // Control/right-click → Actions menu (default behavior); else copy+paste
        // (AppController.m:493-506, _applyActionToTarget 669-703).
        if applyActionIfModified(clip: clip, snippet: nil) { return }
        Paster.copy(clip)
        Paster.paste()
    }

    /// Re-fetch a menu item's clip by persistent ID; nil when the row no longer
    /// exists (e.g. trimmed while the menu was open). Static + injectable
    /// context so the rule is unit-testable.
    static func liveClip(matching clip: ClipRecord, in context: ModelContext) -> ClipRecord? {
        let id = clip.persistentModelID
        var descriptor = FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    @objc private func selectSnippet(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? Snippet else { return }
        if applyActionIfModified(clip: nil, snippet: snippet) { return }
        // Copy the snippet's content and paste it (AppController.m:508-528).
        Paster.copy(string: snippet.content)
        Paster.paste()
    }

    // MARK: - Actions menu (§C41; MenuController.m:1083-1190; AppController.m:447-481,644-703)

    /// On a history/snippet click, run the modifier behavior. Only Control- or
    /// right-click is bound by default — to "popUpActionMenu"; Shift/Option/Command
    /// default to none (AppController.m:184-186). Gated by `enableAction` (default
    /// YES). Returns true if it handled the click (caller then skips the paste).
    private func applyActionIfModified(clip: ClipRecord?, snippet: Snippet?) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PreferenceKeys.enableAction) as? Bool ?? true else { return false }
        guard let event = NSApp.currentEvent else { return false }
        let mods = event.modifierFlags

        // Pick the configured behavior for the held modifier (priority + defaults
        // per AppController.m:684-701, 184-186). Control/right-click default to
        // "popUpActionMenu"; the rest default to None.
        let behavior: String
        if event.type == .rightMouseUp || mods.contains(.control) {
            behavior = defaults.object(forKey: PreferenceKeys.controlClickBehavior) as? String ?? "popUpActionMenu"
        } else if mods.contains(.shift) {
            behavior = defaults.object(forKey: PreferenceKeys.shiftClickBehavior) as? String ?? ""
        } else if mods.contains(.option) {
            behavior = defaults.object(forKey: PreferenceKeys.optionClickBehavior) as? String ?? ""
        } else if mods.contains(.command) {
            behavior = defaults.object(forKey: PreferenceKeys.commandClickBehavior) as? String ?? ""
        } else {
            return false   // no modifier → normal paste
        }
        return dispatchBehavior(behavior, clip: clip, snippet: snippet)
    }

    /// Run a click behavior (AppController.m:_invokeModifiedClickWithBehavior
    /// 644-666): "" = none (fall through to paste), "popUpActionMenu" = pop the
    /// Actions menu (honoring invoke-immediately-if-one), else a specific action.
    private func dispatchBehavior(_ behavior: String, clip: ClipRecord?, snippet: Snippet?) -> Bool {
        switch behavior {
        case "":
            return false
        case "popUpActionMenu":
            let topNodes = ActionStore.load()
            let invokeImmediately = UserDefaults.standard
                .object(forKey: PreferenceKeys.invokeActionImmediately) as? Bool ?? false
            if invokeImmediately, topNodes.count == 1, topNodes[0].action != nil {
                invoke(topNodes[0], clip: clip, snippet: snippet)
            } else {
                popUpActionsMenu(forClip: clip, snippet: snippet)
            }
            return true
        default:
            guard let node = ActionStore.node(forBehaviorID: behavior) else { return false }
            invoke(node, clip: clip, snippet: snippet)
            return true
        }
    }

    private func popUpActionsMenu(forClip clip: ClipRecord?, snippet: Snippet?) {
        let menu = buildActionsMenu(forClip: clip, snippet: snippet)
        let location = NSEvent.mouseLocation
        // Defer so the history/snippets menu finishes closing first.
        Task { @MainActor in
            menu.popUp(positioning: nil, at: location, in: nil)
        }
    }

    /// Build the type-filtered Actions menu for the target
    /// (MenuController.m:_makeActionMenu 1083-1109).
    func buildActionsMenu(forClip clip: ClipRecord?, snippet: Snippet?) -> NSMenu {
        let types = selectedTypes(clip: clip, snippet: snippet)
        let menu = NSMenu(title: "Actions")
        for node in ActionStore.load() {
            if let item = makeActionItem(node: node, types: types, clip: clip, snippet: snippet) {
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Selected item's pasteboard types for the type filter. A snippet is text
    /// (CMIsPerformableAction tag<0 → NSStringPboardType).
    private func selectedTypes(clip: ClipRecord?, snippet: Snippet?) -> [String] {
        clip?.typeIdentifiers ?? ["String"]
    }

    /// Recursive item builder (MenuController.m:_makeActionMenuItemFromNode 1112-1190):
    /// folders → submenus (dropped if empty after filtering); leaves → items only
    /// when performable for the selected types.
    private func makeActionItem(node: ActionNode, types: [String],
                                clip: ClipRecord?, snippet: Snippet?) -> NSMenuItem? {
        let defaults = UserDefaults.standard
        let showIcon = defaults.object(forKey: PreferenceKeys.showIconInTheMenu) as? Bool ?? true

        if let children = node.children {
            let sub = NSMenu(title: node.title)
            for child in children {
                if let item = makeActionItem(node: child, types: types, clip: clip, snippet: snippet) {
                    sub.addItem(item)
                }
            }
            guard sub.numberOfItems > 0 else { return nil }   // 1175-1178
            let folderItem = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
            folderItem.submenu = sub
            if showIcon {
                folderItem.image = iconCache.folderIcon
                folderItem.keepImageVisible()
            }
            return folderItem
        }

        guard let spec = node.action, isPerformable(spec, types: types) else { return nil }
        let item = NSMenuItem(title: node.title, action: #selector(selectActionItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ActionInvocation(node: node, clip: clip, snippet: snippet)
        if defaults.object(forKey: PreferenceKeys.showToolTipOnMenuItem) as? Bool ?? true {
            item.toolTip = Self.builtInToolTip(forName: spec.name)
        }
        if showIcon {
            item.image = (spec.type == ActionStore.jsType) ? iconCache.javaScriptIcon : iconCache.actionIcon
            item.keepImageVisible()
        }
        return item
    }

    /// Whether an action applies to the selected item's types (CMIsPerformableAction,
    /// MenuController.m:45-90; per-builtin types BuiltInActionController.m:108-130).
    private func isPerformable(_ spec: ActionSpec, types: [String]) -> Bool {
        switch spec.type {
        case ActionStore.builtinType:
            switch spec.name {
            case ActionStore.pasteAsPlainText: return types.contains("String")
            case ActionStore.pasteAsFilePath:  return types.contains("Filenames")
            case ActionStore.remove:           return true            // availableTypes (all)
            default:                           return false
            }
        case ActionStore.jsType:
            return types.contains("String")
        default:
            return false
        }
    }

    /// Built-in tool tips (BuiltInActionController.m:_prepareToolTips 62-72).
    private static func builtInToolTip(forName name: String?) -> String? {
        switch name {
        case ActionStore.remove:
            return L("Remove the clip from the clipboard history")
        case ActionStore.pasteAsPlainText:
            return L("Paste the clip as Plain Text")
        case ActionStore.pasteAsFilePath:
            return L("Paste the clip as POSIX File Path")
        default:
            return nil
        }
    }

    @objc private func selectActionItem(_ sender: NSMenuItem) {
        guard let invocation = sender.representedObject as? ActionInvocation else { return }
        invoke(invocation.node, clip: invocation.clip, snippet: invocation.snippet)
    }

    private func invoke(_ node: ActionNode, clip: ClipRecord?, snippet: Snippet?) {
        // prompt() → NSAlert; handler runs synchronously on the main actor.
        let prompt: JSActionRunner.PromptHandler = { message, defaultValue in
            MainActor.assumeIsolated { MainMenuController.runActionPrompt(message: message, default: defaultValue) }
        }
        if let clip {
            ActionEngine.apply(node, to: clip, prompt: prompt)
        } else if let snippet {
            ActionEngine.apply(node, to: snippet, prompt: prompt)
        }
    }

    /// JS `prompt()` dialog (Surround with Tags…): NSAlert + text field
    /// (legacy WebView prompt). Returns nil on Cancel.
    @MainActor
    static func runActionPrompt(message: String, default defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    @objc private func showPreferences(_ sender: Any?) {
        // Self-managed window — the SwiftUI `Settings` scene can't be opened
        // programmatically from an LSUIElement agent (no main-menu responder).
        SettingsWindowController.shared.show()
    }

    // MARK: - Standardized App menu (Liquid Glass §5A)

    /// The product name used in the App-menu titles and by the Uninstall settings
    /// pane. Read from the bundle so a debug build — which is re-id'd and renamed
    /// to "<App> Debug" by scripts/run-debug.sh so it can run beside the installed
    /// release — labels its own menu and its own Uninstall sheet, instead of
    /// claiming to be the release app while acting on the debug app's data.
    ///
    /// The literal is only a fallback for `swift run`, where there is no bundle at
    /// all (`Bundle.main.infoDictionary` is empty) — which is why this can't just
    /// use `AppInfo.displayName`, whose fallback drops the "2".
    static let canonicalName: String = {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? "ClipMenu 2"
    }()

    /// Append the standardized App menu (Liquid Glass §5A): About · Check for
    /// Updates… (Sparkle/direct build only) · Settings… (⌘,) · — · Quit (⌘Q).
    /// Built by DragonKit's `DragonAppMenu`, the single source of truth for this
    /// section in every Dragon app — including the titles, the leading SF Symbols
    /// and the divider before Quit, so the separator added here is only the one
    /// that closes off ClipMenu's own content above.
    ///
    /// Uninstall is deliberately not here: a rare destructive action does not
    /// belong one click from Quit. It lives in Settings as `UninstallSettingsPane`
    /// (last pane in the sidebar), so it stays one click from Settings….
    private func addAppMenuSection(to menu: NSMenu) {
        menu.addItem(.separator())

        let items = DragonAppMenu.items(DragonAppMenu.Config(
            appName: Self.canonicalName,
            onAbout: { [weak self] in self?.showAbout(nil) },
            onSettings: { [weak self] in self?.showPreferences(nil) },
            // Check for Updates… exists only in the Sparkle / Developer ID build; the
            // Mac App Store build is updated by the App Store, and passing nil here
            // omits the item entirely.
            onCheckForUpdates: UpdaterUI.isSupported ? { [weak self] in self?.checkForUpdates(nil) } : nil))
        for item in items { menu.addItem(item) }
    }

    /// "About ClipMenu 2" — opens Settings on the About pane specifically. (The
    /// Settings… item opens the last-used pane; About always lands on About.)
    @objc private func showAbout(_ sender: Any?) {
        SettingsWindowController.shared.show(paneID: "about")
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdaterUI.checkNow()
    }
}
