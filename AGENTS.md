# AGENTS.md

ClipMenu 2: a macOS clipboard-history menu-bar app, built as a SwiftPM package under `App/` on top of the shared DragonKit package.

## Project rules

### Building and running

- For hands-on testing next to an installed ClipMenu, build with `App/scripts/run-debug.sh`. It re-ids the bundle to `com.dragonapp.clipmenu-2.debug` / "ClipMenu 2 Debug", so it gets its own permissions (TCC), defaults domain and menu-bar slot, then installs it as `/Applications/ClipMenu 2 Debug.app` (replacing the previous Debug copy) and launches it from there. `App/scripts/run.sh` and pressing Run on `App/Package.swift` in Xcode both produce the release bundle id `com.dragonapp.clipmenu-2` and collide with the installed app.
- Launch an assembled `.app` with `open -n`, as the scripts do. Don't execute `Contents/MacOS/ClipMenu` directly from a script or tool: macOS then attributes the menu-bar item to the parent process and records its show/hide flag per bundle id in a system store that can't be reset by hand. The one exception is reading a launch-time `fatalError`/SIGTRAP message, which crash-log symbolication hides: run the **debug** bundle's binary directly once to see its stderr, never a release-id bundle.
- When assembling a `.app`, copy every `*.bundle` from the SwiftPM bin directory into `Contents/Resources` (the scripts and release workflows already do). Without DragonKit's strings bundle the UI shows raw `DragonKit.*` keys.
- In app code, load bundled resources through `AppResources.bundle`, not `Bundle.module`: SwiftPM's `.module` accessor doesn't look in `Contents/Resources` and `fatalError`s inside a packaged `.app`.
- Give every `NSStatusItem` an `autosaveName` namespaced by bundle id (see `StatusItemController`). A shared literal makes release and debug builds share one menu-bar identity, so hiding one hides the other.

### DragonKit

- Shared behavior (settings shell, About, What's New, Permissions, Uninstall, Updates, localization, design primitives) comes from the `dragon-kit` package at a version tag. Never fork or vendor it into the app: change dragon-kit, tag a release there, and raise the requirement in `App/Package.swift`.
- Set `LocalizationManager.shared.appStringsBundle` at launch before any `L()` call.
- Deliberate deviations, don't "fix" them: folder backup and the Sync & Backup pane stay app-owned in `Sources/ClipMenu/Premium/` (DragonKit's backup only snapshots a UserDefaults suite), and settings stay flat `@AppStorage` rather than `DragonSettingsStore`.

### Sync and backup

- Don't reintroduce iCloud, CloudKit or `NSUbiquitousKeyValueStore` sync; the user-chosen backup folder is the sync mechanism. Those entitlements aren't provisioned for the Developer ID / Homebrew build, so iCloud sync silently did nothing there, while a folder in Dropbox or iCloud Drive works on every channel.

### Tests

- Write tests with Swift Testing (`@Test`/`@Suite`), not XCTest. ViewInspector is linked only by the `ClipMenuTests` target, never by the app product.
- Don't chase unit coverage of window hosting, `@main`/app-delegate lifecycle or Carbon hot-key registration; they can't run headlessly. Extract the logic into a pure helper and test that (as `ManualReorder` does for snippet drag-reorder).
