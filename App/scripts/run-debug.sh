#!/bin/bash
# Build + launch a LOCAL DEBUG build of ClipMenu with its OWN identity so it runs
# safely NEXT TO the installed release. Per dragon-mac-ops "Test / debug builds":
# the debug build gets bundle id com.dragonapp.clipmenu-2.debug and the name
# "ClipMenu 2 Debug", so it has its own TCC entry + UserDefaults domain and never
# fights the installed app's menu-bar/login-item instance.
#
# (clipmenu-2 is SwiftPM, not Xcode, so this adapts the skill's xcodebuild template
# to `swift build` + the same .app assembly as scripts/run.sh.)
#
# Usage:  ./scripts/run-debug.sh
set -euo pipefail
cd "$(dirname "$0")/.."            # package root (App/), which also holds the bundle inputs

# Compile the SAME product the release ships: CLIPMENU_SPARKLE=1 links
# DragonKitUpdates and defines SPARKLE, so the debug build exercises the direct /
# Developer ID code path (Updates pane, About's Sparkle attribution) rather than
# the Mac App Store variant. Embedding Sparkle is not the same as running it — the
# updater stays inert on the Debug channel; see UpdaterUI.isSupported and the
# SUEnableAutomaticChecks stamp below.
export CLIPMENU_SPARKLE=1         # include the Sparkle updater locally
swift build -c debug --arch arm64
BIN_PATH="$(swift build -c debug --arch arm64 --show-bin-path)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
MAJOR="${VERSION%%.*}"
APP_NAME="ClipMenu ${MAJOR} Debug"
DEBUG_ID="com.dragonapp.clipmenu-2.debug"
APP=".build/${APP_NAME}.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/ClipMenu" "$APP/Contents/MacOS/ClipMenu"
cp Info.plist "$APP/Contents/Info.plist"

pb=/usr/libexec/PlistBuddy
"$pb" -c "Set :CFBundleIdentifier ${DEBUG_ID}" "$APP/Contents/Info.plist"
"$pb" -c "Set :CFBundleName ${APP_NAME}" "$APP/Contents/Info.plist"
"$pb" -c "Add :CFBundleDisplayName string ${APP_NAME}" "$APP/Contents/Info.plist" 2>/dev/null \
  || "$pb" -c "Set :CFBundleDisplayName ${APP_NAME}" "$APP/Contents/Info.plist"

# Build number = git commit count (monotonic); About shows "Version X (build)".
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo "$VERSION")"
"$pb" -c "Set :CFBundleVersion ${BUILD}" "$APP/Contents/Info.plist"

# Commit timestamp (%cI) for About's version line; DragonAbout drops the timestamp
# when the key is absent rather than falling back to the executable's mtime.
COMMIT_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
if [ -n "$COMMIT_DATE" ]; then
    "$pb" -c "Set :DragonCommitDate ${COMMIT_DATE}" "$APP/Contents/Info.plist" 2>/dev/null \
      || "$pb" -c "Add :DragonCommitDate string ${COMMIT_DATE}" "$APP/Contents/Info.plist"
fi

# Mark the CHANNEL, never the version. This block used to append " (Debug)" to
# CFBundleShortVersionString — which is the one string the public release tag is
# asserted against (dragon-kit docs/MAC-APP-RELEASE-LIFECYCLE.md, "Public version rules": it
# holds only X.Y.Z, the numeric candidate the next release ships). A channel label
# inside it makes the version non-numeric and breaks that assertion. The label is
# presentation: DragonKit ≥3.3.0 reads DragonBuildChannel and renders
# "v2.20.1 Debug (1234)" in About, so a screenshot still can't be mistaken for the
# release build — which was the original reason for the suffix.
SHORT_VERSION="$("$pb" -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if ! [[ "$SHORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: CFBundleShortVersionString is '${SHORT_VERSION}', not a numeric X.Y.Z candidate." >&2
    echo "       Fix App/Info.plist: the public vX.Y.Z tag is checked against this field." >&2
    exit 1
fi
"$pb" -c "Set :DragonBuildChannel Debug" "$APP/Contents/Info.plist" 2>/dev/null \
  || "$pb" -c "Add :DragonBuildChannel string Debug" "$APP/Contents/Info.plist"

# Never update. This bundle would otherwise inherit the release's SUFeedURL, so a
# check would offer the PRODUCTION appcast and "updating" would swap the debug build
# for the release one. Deleting the feed is what makes that structural instead of
# cosmetic: Sparkle refuses to start without one, DragonUpdater catches the throw and
# leaves its SPUUpdater nil (DragonKitUpdates/Updates.swift:155-166), so
# `canCheckForUpdates` is false (:184) and the pane's Check button is disabled (:248).
# Every route — pane, toggles, button, menu item — then goes inert at the DATA layer
# rather than depending on some UI remembering to hide itself. The standard across all
# five Dragon apps. `|| true` because Delete errors when the key is already absent.
"$pb" -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
# Belt to that brace, and what stops a scheduled check even if a feed ever came back
# from user defaults. Add, not Set: the release Info.plist doesn't carry the key.
"$pb" -c "Set :SUEnableAutomaticChecks false" "$APP/Contents/Info.plist" 2>/dev/null \
  || "$pb" -c "Add :SUEnableAutomaticChecks bool false" "$APP/Contents/Info.plist"

cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# All SwiftPM resource bundles: the app's own + DragonKit's localized strings.
for BUNDLE_PATH in "$BIN_PATH"/*.bundle; do
    [ -d "$BUNDLE_PATH" ] || continue
    BUNDLE_NAME="$(basename "$BUNDLE_PATH")"
    cp -R "$BUNDLE_PATH" "$APP/Contents/Resources/$BUNDLE_NAME"
    chmod -R u+w "$APP/Contents/Resources/$BUNDLE_NAME"
done
if [ -d "$BIN_PATH/Sparkle.framework" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$BIN_PATH/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    chmod -R u+w "$APP/Contents/Frameworks/Sparkle.framework"
fi

# Prefer the stable "ClipMenu Dev" identity (keeps the debug bundle's TCC grant
# across rebuilds); fall back to ad-hoc.
SIGN_IDENTITY="ClipMenu Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    IDENTITY="$SIGN_IDENTITY"
    echo "Signing debug build with: $SIGN_IDENTITY"
else
    IDENTITY="-"
    echo "Ad-hoc signing — macOS re-prompts for permissions each rebuild."
fi
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    codesign --force --deep --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null || true
fi
codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null || true

echo "Assembled $APP (id ${DEBUG_ID})"

# Install into /Applications, where the release copy lives too, replacing the
# previous Debug copy outright. The rm -rf below runs in /Applications, so refuse
# unless the identity is the Debug one.
INSTALLED="/Applications/${APP_NAME}.app"
[[ "$APP_NAME" == *" Debug" && "$DEBUG_ID" == *.debug ]] \
  || { echo "error: refusing to install a non-Debug identity into /Applications" >&2; exit 1; }

# Quit ONLY the running debug instance, found by its .debug bundle id (never the
# installed release, whose id differs). This also catches a Debug copy launched
# from an older build folder.
for ASN in $(lsappinfo find bundleid="$DEBUG_ID" | grep -oE 'ASN:0x[0-9a-f]+-0x[0-9a-f]+-' || true); do
    PID="$(lsappinfo info -only pid "$ASN" | grep -oE 'pid"? ?= ?[0-9]+' | grep -oE '[0-9]+$' || true)"
    [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
done
sleep 1

rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
echo "Installed $INSTALLED"
# -n opens the bundle at THIS exact path. A plain `open` (or `open -b`) lets
# LaunchServices resolve the debug id to whichever bundle it likes — including a
# stale build in another checkout — so you'd debug a binary you didn't just
# compile. It also parents the app to launchd, so it outlives this shell.
open -n "$INSTALLED"
echo "Launched ${APP_NAME} v${SHORT_VERSION} Debug (build ${BUILD}) — runs next to the installed ClipMenu 2."
