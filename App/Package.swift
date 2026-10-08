// swift-tools-version: 6.0
import PackageDescription
import Foundation

// ClipMenu — modern rewrite (scaffold).
// Built as a SwiftPM executable so it compiles with the Command Line Tools
// toolchain (no full Xcode required). Agent / menu-bar behavior is established
// at runtime via NSApp.setActivationPolicy(.accessory); the bundled .app uses
// the LSUIElement Info.plist at App/Info.plist (SwiftPM forbids Info.plist as
// a target resource, so it lives outside Sources and is applied when the .app
// bundle / Xcode project is produced later).
//
// DragonKit is the shared foundation of every Dragon menu-bar app (settings
// shell, About / What's New / Permissions / Uninstall panes, localization).
// Depended on at a version tag — never vendored. Its Sparkle-backed updates
// live in a separate product, DragonKitUpdates, linked ONLY for the direct /
// Developer ID build: the Mac App Store build must not contain a self-updater
// (App Store policy + sandbox), so with CLIPMENU_SPARKLE unset nothing links
// Sparkle and the MAS / test builds stay Sparkle-free. The `SPARKLE` compile
// flag gates the app's update UI (scripts/run.sh and
// .github/workflows/release.yml set CLIPMENU_SPARKLE=1; the MAS workflow does
// not).
let sparkleEnabled = ProcessInfo.processInfo.environment["CLIPMENU_SPARKLE"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/teddychan/dragon-kit", from: "4.2.0"),
    // Test-only: SwiftUI view-tree inspection so the app's SwiftUI panes/views can
    // be asserted in unit tests. Linked ONLY by the ClipMenuTests target — never by
    // the app product — so it ships in no build.
    .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
]
var clipMenuDependencies: [Target.Dependency] = [
    .product(name: "DragonKit", package: "dragon-kit"),
]
var clipMenuSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
var clipMenuLinkerSettings: [LinkerSetting] = []

if sparkleEnabled {
    clipMenuDependencies.append(.product(name: "DragonKitUpdates", package: "dragon-kit"))
    clipMenuSwiftSettings.append(.define("SPARKLE"))
    // Sparkle.framework is embedded in Contents/Frameworks by the bundle-assembly
    // step; this rpath lets the executable find it at runtime. Passed via -Xlinker
    // because SwiftPM linkerSettings flags go through the Swift driver, not clang.
    clipMenuLinkerSettings.append(.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"]))
}

// Folder-based settings sync & backup (Sources/ClipMenu/Premium/) is compiled into
// every build and works identically on all distribution channels (Homebrew, GitHub,
// Mac App Store): the user picks a backup folder (local, Dropbox, iCloud Drive,
// Google Drive) to sync across Macs — no iCloud entitlement or CloudKit required.
var clipMenuTestSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "ClipMenu",
    // Base development language; localized .lproj resources live alongside
    // (Resources/<lang>.lproj/Localizable.strings) and fall back to English.
    defaultLocalization: "en",
    platforms: [
        // Apple Silicon only — a product decision, not a platform limit. (macOS 26
        // Tahoe still runs on some Intel Macs; macOS 27 is the first
        // Apple-silicon-only release.) ClipMenu supports macOS 26 and 27 and ships
        // a single arm64 slice — no universal/Intel build. The build script and CI
        // pass `--arch arm64` to enforce this explicitly (scripts/run.sh,
        // .github/workflows/release-mas.yml).
        .macOS("26.0") // minimum supported macOS (SDK 26.x)
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "ClipMenu",
            dependencies: clipMenuDependencies,
            path: "Sources/ClipMenu",
            resources: [
                // Bundled JS actions + libraries (legacy resource/script tree),
                // run verbatim by JSActionRunner for transform parity (OQ#3).
                .copy("Resources/script"),
                // Menu-bar status icon: a vector PDF template (Apple-recommended
                // for status items — stays crisp at any size), rendered at 18pt
                // by StatusItemController.
                .copy("Resources/MenuBarIcon.pdf"),
                // UI string translations (issue #19). Each .lproj is processed so
                // SwiftPM compiles it into the resource bundle under its locale.
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
                .process("Resources/zh-Hant.lproj"),
                .process("Resources/ja.lproj"),
                .process("Resources/ko.lproj"),
                .process("Resources/es.lproj"),
                .process("Resources/fr.lproj"),
                .process("Resources/ru.lproj")
            ],
            swiftSettings: clipMenuSwiftSettings,
            linkerSettings: clipMenuLinkerSettings
        ),
        .testTarget(
            name: "ClipMenuTests",
            dependencies: [
                "ClipMenu",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests/ClipMenuTests",
            swiftSettings: clipMenuTestSwiftSettings
        )
    ]
)
