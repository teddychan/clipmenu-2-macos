import Foundation
import SwiftData
import Testing
@testable import ClipMenu

@MainActor
@Suite(.serialized)
struct SettingsBackupTests {
    nonisolated static let keys = [
        "DragonKit.language", "appLanguage", "loginItem", "inputPasteCommand",
        "reorderClipsAfterPasting", "maxHistorySize", "timeInterval", "saveHistoryOnQuit",
        "showStatusItem", "exportHistoryAsSingleFile", "tagOfSeparatorForExportHistoryToFile",
        "numberOfItemsPlaceInline", "numberOfItemsPlaceInsideFolder", "maxMenuItemTitleLength",
        "menuItemsAreMarkedWithNumbers", "addNumericKeyEquivalents", "showLabelsInMenu",
        "addClearHistoryMenuItem", "showAlertBeforeClearHistory", "showToolTipOnMenuItem",
        "maxLengthOfToolTipKey", "changeFontSize", "howToChangeFontSize", "selectedFontSize",
        "showImageInTheMenu", "thumbnailMaxSize", "showIconInTheMenu", "menuIconSize",
        "positionOfSnippets", "groupSnippetsInFolder", "storeTypes", "enableAction",
        "invokeActionImmediately", "controlClickBehavior", "shiftClickBehavior",
        "optionClickBehavior", "commandClickBehavior", "hotKeys", "excludeApps",
        "automaticBackupEnabled", "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "snippetEditor.folderSort",
    ]

    @MainActor
    private final class Environment {
        let suite = "SettingsBackupTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let directory: URL
        let context: ModelContext
        let store = MockBackupStore()
        var loginEnabled = false
        var restored = 0

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let container = try ModelContainer(
                for: Folder.self, Snippet.self, ClipRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            context = ModelContext(container)
        }

        var actionsURL: URL { directory.appendingPathComponent("actions.plist") }
        var manager: BackupManager {
            BackupManager(store: store, context: context, deviceName: "Test", appVersion: "1.0.0",
                          defaults: defaults, actionsURL: actionsURL,
                          loginItemEnabled: { self.loginEnabled },
                          setLoginItemEnabled: { self.loginEnabled = $0 },
                          didRestoreSettings: { self.restored += 1 })
        }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func backup() async throws -> BackupVersionMeta {
            guard case let .created(version) = try await manager.backUpNow(kind: .manual) else {
                throw TestError.expectedBackup
            }
            return version
        }
        func writeActions(_ nodes: [ActionNode]) throws {
            try PropertyListEncoder().encode(nodes).write(to: actionsURL, options: .atomic)
        }
    }

    private enum TestError: Error { case expectedBackup }

    private func value(for key: String, alternate: Bool) -> Any {
        switch key {
        case "DragonKit.language", "appLanguage": return alternate ? "ja" : "fr"
        case "maxHistorySize": return alternate ? 321 : 123
        case "timeInterval": return alternate ? 0.25 : 0.5
        case "showStatusItem": return alternate ? 1 : 0
        case "tagOfSeparatorForExportHistoryToFile": return alternate ? 4 : 5
        case "numberOfItemsPlaceInline": return alternate ? 8 : 7
        case "numberOfItemsPlaceInsideFolder": return alternate ? 25 : 15
        case "maxMenuItemTitleLength": return alternate ? 80 : 60
        case "maxLengthOfToolTipKey": return alternate ? 900 : 800
        case "howToChangeFontSize": return alternate ? 0 : 1
        case "selectedFontSize": return alternate ? 24 : 18
        case "thumbnailMaxSize": return alternate ? 128 : 96
        case "menuIconSize": return alternate ? 48 : 32
        case "positionOfSnippets", "snippetEditor.folderSort": return alternate ? 2 : 1
        case "controlClickBehavior", "shiftClickBehavior", "optionClickBehavior", "commandClickBehavior":
            return alternate ? "popUpActionMenu" : "builtin:pasteAsPlainText:"
        case "storeTypes":
            return ["String": alternate, "RTF": !alternate, "PDF": alternate,
                    "Filenames": !alternate, "URL": alternate, "TIFF": !alternate, "RTFD": alternate]
        case "hotKeys":
            return ["ClipMenu": ["keyCode": alternate ? 10 : 9, "modifiers": 768],
                    "HistoryMenu": ["keyCode": alternate ? 12 : 11, "modifiers": 256],
                    "SnippetsMenu": ["keyCode": alternate ? 14 : 13, "modifiers": 512]]
        case "excludeApps":
            return [["bundleIdentifier": alternate ? "com.example.second" : "com.example.first",
                     "name": alternate ? "Second" : "First"]]
        default: return alternate
        }
    }

    @Test(arguments: keys)
    func everySettingCreatesVersionAndRestoresItsValue(key: String) async throws {
        let env = try Environment()
        defer { env.cleanup() }
        let original = value(for: key, alternate: false)
        env.defaults.set(original, forKey: key)
        env.loginEnabled = false
        let first = try await env.backup()
        #expect(try await env.manager.backUpNow(kind: .manual) == .noChanges)
        env.defaults.set(value(for: key, alternate: true), forKey: key)
        if key == "loginItem" { env.loginEnabled = true }
        let second = try await env.backup()
        #expect(second.contentHash != first.contentHash)
        try await env.manager.restore(first)
        #expect(NSDictionary(dictionary: [key: try #require(env.defaults.object(forKey: key))])
            .isEqual(to: [key: original]), "Restored \(key)")
        if key == "loginItem" { #expect(!env.loginEnabled) }
        #expect(env.restored == 1)
    }

    @Test(arguments: ["String", "RTF", "PDF", "Filenames", "URL", "TIFF", "RTFD"])
    func everyCaptureTypeRestoresIndependently(type: String) async throws {
        let env = try Environment()
        defer { env.cleanup() }
        env.defaults.set([type: false], forKey: "storeTypes")
        let version = try await env.backup()
        env.defaults.set([type: true], forKey: "storeTypes")
        _ = try await env.backup()
        try await env.manager.restore(version)
        #expect(env.defaults.dictionary(forKey: "storeTypes") as? [String: Bool] == [type: false])
    }

    @Test(arguments: ["ClipMenu", "HistoryMenu", "SnippetsMenu"], ["keyCode", "modifiers"])
    func everyShortcutRestoresItsKeyAndModifiers(shortcut: String, component: String) async throws {
        let env = try Environment()
        defer { env.cleanup() }
        let original = [shortcut: ["keyCode": 9, "modifiers": 768]]
        env.defaults.set(original, forKey: "hotKeys")
        let version = try await env.backup()
        var changed = original
        changed[shortcut]?[component] = component == "keyCode" ? 20 : 256
        env.defaults.set(changed, forKey: "hotKeys")
        _ = try await env.backup()
        try await env.manager.restore(version)
        #expect(env.defaults.dictionary(forKey: "hotKeys") as? [String: [String: Int]] == original)
    }

    @Test func restoringUnsetPreferencesRemovesLaterOverrides() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        let version = try await env.backup()
        for key in Self.keys where key != "loginItem" {
            env.defaults.set(value(for: key, alternate: true), forKey: key)
        }
        try await env.manager.restore(version)
        for key in Self.keys where key != "loginItem" {
            #expect(env.defaults.object(forKey: key) == nil, "Reset \(key)")
        }
    }

    @Test func safetyBackupPreservesSettingsBeforeRestore() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        env.defaults.set("fr", forKey: "DragonKit.language")
        let first = try await env.backup()
        env.defaults.set("ja", forKey: "DragonKit.language")
        try await env.manager.restore(first)
        let safety = try #require(await env.store.versions.last { $0.meta.kind == .preRestore })
        try await env.manager.restore(safety.meta)
        #expect(env.defaults.string(forKey: "DragonKit.language") == "ja")
    }

    @Test func failedSafetyBackupLeavesPreferencesAndActionsIntact() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        env.defaults.set("fr", forKey: "DragonKit.language")
        try env.writeActions([.builtin("Original", name: "remove:")])
        let version = try await env.backup()
        env.defaults.set("ja", forKey: "DragonKit.language")
        let changed: [ActionNode] = [.javaScript("Case/lowercase.js")]
        try env.writeActions(changed)
        await env.store.setFailSave(.preRestore)
        await #expect(throws: SyncBackupError.preRestoreFailed) { try await env.manager.restore(version) }
        #expect(env.defaults.string(forKey: "DragonKit.language") == "ja")
        #expect(try PropertyListDecoder().decode([ActionNode].self, from: Data(contentsOf: env.actionsURL)) == changed)
        #expect(env.restored == 0)
    }

    @Test func legacyBackupLeavesCurrentSettingsAndActionsAlone() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        env.defaults.set("ja", forKey: "DragonKit.language")
        let actions: [ActionNode] = [.javaScript("Case/lowercase.js")]
        try env.writeActions(actions)
        let legacy = Data(#"{"schemaVersion":1,"folders":[],"orphanSnippets":[]}"#.utf8)
        let meta = BackupSaveMeta(kind: .manual, clientDate: Date(), deviceName: "Old", appVersion: "1.0.0",
                                  folderCount: 0, snippetCount: 0, contentHash: "legacy", schemaVersion: 1)
        let version = try await env.store.save(payload: legacy, meta: meta)
        try await env.manager.restore(version)
        #expect(env.defaults.string(forKey: "DragonKit.language") == "ja")
        #expect(try PropertyListDecoder().decode([ActionNode].self, from: Data(contentsOf: env.actionsURL)) == actions)
    }

    @Test func actionTreeEditsCreateVersionsAndRestoreStructureAndOrder() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        let original: [ActionNode] = [
            .folder("Custom", [.javaScript("Case/lowercase.js"), .builtin("Remove", name: "remove:")]),
            .builtin("Paste", name: "pasteAsPlainText:"),
        ]
        try env.writeActions(original)
        let first = try await env.backup()
        #expect(try await env.manager.backUpNow(kind: .manual) == .noChanges)
        try env.writeActions(Array(original.reversed()) + [.javaScript("Trim/Trim.js")])
        let second = try await env.backup()
        #expect(first.contentHash != second.contentHash)
        try await env.manager.restore(first)
        #expect(try PropertyListDecoder().decode([ActionNode].self, from: Data(contentsOf: env.actionsURL)) == original)
    }

    @Test func machineLocalFolderAndBookkeepingSurviveRestore() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        let version = try await env.backup()
        let local: [String: Any] = ["backupFolderBookmark": Data([1, 2, 3]), "backupFolderPath": "/different/folder",
                                    "onboardingCompleted": true, "onboardingStep": 4, "settingsSelectedTab": "menu"]
        for (key, value) in local { env.defaults.set(value, forKey: key) }
        try await env.manager.restore(version)
        for (key, value) in local {
            #expect(NSDictionary(dictionary: [key: try #require(env.defaults.object(forKey: key))]).isEqual(to: [key: value]))
        }
    }

    @Test func equivalentNestedDictionariesDoNotCreateAnotherVersion() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        var first: [String: [String: Int]] = [:]
        first["ClipMenu"] = ["keyCode": 9, "modifiers": 768]
        first["HistoryMenu"] = ["keyCode": 11, "modifiers": 256]
        env.defaults.set(first, forKey: "hotKeys")
        _ = try await env.backup()
        var second: [String: [String: Int]] = [:]
        var combo: [String: Int] = [:]
        combo["modifiers"] = 768
        combo["keyCode"] = 9
        second["HistoryMenu"] = ["modifiers": 256, "keyCode": 11]
        second["ClipMenu"] = combo
        env.defaults.set(second, forKey: "hotKeys")
        #expect(try await env.manager.backUpNow(kind: .manual) == .noChanges)
    }

    @Test func backupRegistryHasAnIndependentFixtureForEveryKey() {
        #expect(Set(SettingsSidecar.backupKeys) == Set(Self.keys))
        #expect(SettingsSidecar.backupKeys.count == Self.keys.count)
    }

    @Test func malformedSettingsAreRejectedBeforeAnyMutationOrSafetyBackup() async throws {
        let env = try Environment()
        defer { env.cleanup() }
        env.defaults.set("ja", forKey: "DragonKit.language")
        let snapshot = SnippetSnapshot(schemaVersion: 2, folders: [], orphanSnippets: [],
                                       settings: ["DragonKit.language": Data([0, 1, 2])])
        let meta = BackupSaveMeta(kind: .manual, clientDate: Date(), deviceName: "Broken", appVersion: "1.0.0",
                                  folderCount: 0, snippetCount: 0, contentHash: "broken", schemaVersion: 2)
        let version = try await env.store.save(payload: snapshot.canonicalPayload(), meta: meta)
        await #expect(throws: SyncBackupError.validationFailed) { try await env.manager.restore(version) }
        #expect(env.defaults.string(forKey: "DragonKit.language") == "ja")
        #expect(await env.store.saveKinds == [.manual])
        #expect(env.restored == 0)
    }

    @Test func editableAppStorageKeysHaveExplicitRoundTripFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources/ClipMenu")
        let files = try #require(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var source = ""
        for case let url as URL in files where url.pathExtension == "swift" {
            source += try String(contentsOf: url, encoding: .utf8) + "\n"
        }
        let pattern = #"@AppStorage\((?:PreferenceKeys\.)?(?:"([^"]+)"|(\w+))\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let text = source as NSString
        let keys = regex.matches(in: source, range: NSRange(location: 0, length: text.length)).map { match in
            text.substring(with: match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1))
        }
        #expect(!keys.isEmpty)
        #expect(Set(keys).subtracting(Self.keys).subtracting(["onboardingStep"]).isEmpty)
    }
}
