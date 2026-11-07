import Foundation

/// Mirrors a whitelist of preference keys to/from a `ClipMenu-Settings.plist` file
/// in the backup folder, so settings travel with snippet backups — and sync across
/// Macs when that folder lives in Dropbox / iCloud Drive / Google Drive. Replaces
/// the old `NSUbiquitousKeyValueStore` sync, which only worked in the sandboxed
/// Mac App Store build and silently no-op'd on the Developer ID build.
///
/// Pure / injectable (takes a `UserDefaults` and a file URL) so it is unit-testable.
enum SettingsSidecar {
    static let fileName = "ClipMenu-Settings.plist"

    /// Preference keys that follow the user across Macs. Excludes machine-local
    /// flags: `loginItem` (per-machine launch state), `suppressAlertForLoginItem`,
    /// `didMigrateToSplitStores`, the backup-folder bookmark/meta, and onboarding.
    static let syncedKeys: [String] = [
        // General
        PreferenceKeys.appLanguage, "DragonKit.language", PreferenceKeys.automaticBackupEnabled,
        PreferenceKeys.inputPasteCommand, PreferenceKeys.reorderClipsAfterPasting, PreferenceKeys.maxHistorySize, PreferenceKeys.timeInterval,
        PreferenceKeys.saveHistoryOnQuit, PreferenceKeys.showStatusItem, PreferenceKeys.exportHistoryAsSingleFile,
        PreferenceKeys.tagOfSeparatorForExportHistoryToFile,
        // Menu
        PreferenceKeys.numberOfItemsPlaceInline, PreferenceKeys.numberOfItemsPlaceInsideFolder, PreferenceKeys.maxMenuItemTitleLength,
        PreferenceKeys.menuItemsAreMarkedWithNumbers, PreferenceKeys.addNumericKeyEquivalents, PreferenceKeys.showLabelsInMenu,
        PreferenceKeys.addClearHistoryMenuItem, PreferenceKeys.showAlertBeforeClearHistory, PreferenceKeys.showToolTipOnMenuItem,
        PreferenceKeys.maxLengthOfToolTipKey, PreferenceKeys.changeFontSize, PreferenceKeys.howToChangeFontSize, PreferenceKeys.selectedFontSize,
        PreferenceKeys.showImageInTheMenu, PreferenceKeys.thumbnailMaxSize, PreferenceKeys.showIconInTheMenu,
        PreferenceKeys.menuIconSize, PreferenceKeys.positionOfSnippets, PreferenceKeys.groupSnippetsInFolder,
        // Type
        PreferenceKeys.storeTypes,
        // Action
        PreferenceKeys.enableAction, PreferenceKeys.invokeActionImmediately, PreferenceKeys.controlClickBehavior, PreferenceKeys.shiftClickBehavior,
        PreferenceKeys.optionClickBehavior, PreferenceKeys.commandClickBehavior,
        // Shortcuts + exclusions
        PreferenceKeys.hotKeys, PreferenceKeys.excludeApps, "snippetEditor.folderSort",
    ]

    static let backupKeys = syncedKeys + [
        PreferenceKeys.loginItem, "SUEnableAutomaticChecks", "SUAutomaticallyUpdate",
    ]

    static func capture(from defaults: UserDefaults) throws -> [String: Data] {
        var values: [String: Data] = [:]
        for key in backupKeys {
            if let value = defaults.object(forKey: key) {
                values[key] = try PropertyListSerialization.data(
                    fromPropertyList: ["value": value], format: .xml, options: 0)
            }
        }
        return values
    }

    static func decoded(_ values: [String: Data]) throws -> [String: Any] {
        var decoded: [String: Any] = [:]
        for key in backupKeys {
            guard let data = values[key] else { continue }
            guard let container = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
                  let value = container["value"] else { throw SyncBackupError.validationFailed }
            decoded[key] = value
        }
        return decoded
    }

    static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for key in backupKeys {
            if let value = values[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    /// Write the whitelisted values from `defaults` to `url` (atomic). Returns false
    /// on failure.
    @discardableResult
    static func write(keys: [String] = syncedKeys, from defaults: UserDefaults, to url: URL) -> Bool {
        var dict: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { dict[key] = value }
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0) else {
            return false
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Apply the whitelisted values stored at `url` onto `defaults`. Returns true if
    /// a sidecar was found and applied.
    @discardableResult
    static func read(keys: [String] = syncedKeys, from url: URL, into defaults: UserDefaults) -> Bool {
        guard
            let data = try? Data(contentsOf: url),
            let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return false }
        for key in keys where dict[key] != nil {
            defaults.set(dict[key], forKey: key)
        }
        return true
    }
}
