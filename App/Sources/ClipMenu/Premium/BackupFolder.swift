import Foundation

/// The user-chosen backup folder, persisted as a bookmark so it survives relaunch.
///
/// On the sandboxed Mac App Store build the bookmark is **security-scoped**
/// (requires the `files.user-selected.read-write` + `files.bookmarks.app-scope`
/// entitlements) so the app keeps access to a folder the user picked. On the
/// unsandboxed Developer ID build a plain bookmark is used — security scope there
/// is unnecessary and unavailable.
enum BackupFolder {
    /// Bookmark options for the running build: security-scoped only in the sandbox.
    private static var creationOptions: URL.BookmarkCreationOptions {
        DistributionChannel.current == .appStore ? [.withSecurityScope] : []
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        DistributionChannel.current == .appStore ? [.withSecurityScope] : []
    }

    /// Persist `url` as the backup folder (creates + stores the bookmark + a
    /// display path). Returns false if the bookmark couldn't be created.
    @discardableResult
    static func set(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? url.bookmarkData(
            options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return false }
        defaults.set(data, forKey: PreferenceKeys.backupFolderBookmark)
        defaults.set(url.path(percentEncoded: false), forKey: PreferenceKeys.backupFolderPath)
        return true
    }

    /// Resolve the bookmark, then fall back to the shared pane's stored path.
    static func resolvedURL(defaults: UserDefaults = .standard) -> URL? {
        if let data = defaults.data(forKey: PreferenceKeys.backupFolderBookmark), !data.isEmpty {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: resolutionOptions,
                relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale { _ = set(url, defaults: defaults) }
                return url
            }
        }
        guard let path = defaults.string(forKey: PreferenceKeys.backupFolderPath), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func isConfigured(defaults: UserDefaults = .standard) -> Bool {
        resolvedURL(defaults: defaults) != nil
    }

    static func displayPath(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: PreferenceKeys.backupFolderPath) ?? ""
    }

    /// Whether automatic (on-quit) backups are enabled (default true).
    static func automaticBackupEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: PreferenceKeys.automaticBackupEnabled) as? Bool ?? true
    }
}
