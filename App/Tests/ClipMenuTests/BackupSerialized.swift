import Foundation
import Testing

// Restore holds a process-wide flag across awaits. Swift Testing only coordinates
// sibling suites when they share a serialized parent.
@Suite(.serialized) struct BackupSerialized {}

final class BackupTestDefaults {
    private let suite = "BackupTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }
}
