# Changelog

Developer-facing notes for ClipMenu. User-facing release notes live in
`App/Sources/ClipMenu/WhatsNewConfig.swift` (shown in the in-app What's New pane).

## Unreleased

### Added
- **Russian.** `ru.lproj` translates every key in `en.lproj`, in the same order and with the
  same printf specifiers, plus the four live Uninstall-pane keys that `en.lproj` omits (English
  falls back to the key itself; every other locale carries them). The terminology follows the
  translation @shendrykau contributed to Ice 2 and DragonKit in teddychan/ice-2#132 — Строка меню,
  Системные настройки, Универсальный доступ, Правка — so the kit's panes and the app's own
  strings use the same words.

  Russian has three plural forms and these tables are not `.stringsdict`, so counts read
  "Label: %d". Where the code prints the number itself and appends a key, the translation uses a
  count-neutral form ("шт.", "симв.") — except the backup row's "folders" / "snippets", which
  have none and read "<n> папок", wrong after 1–4, until that call site formats the label itself.

  **Every release's What's New text now needs a Russian line too.** dragon-release-ci's exporter
  discovers each `*.lproj` beside `WhatsNewConfig.swift` and fails the release on a key missing
  from any of them, so the current `app.whatsNew.summary` / `changed1` are translated here.

### Changed
- **DragonKit 4.1.2 → 4.2.0**, which adds `DragonLanguage.ru`. CONFORMANCE §R13 reads the kit's
  language list from dragon-kit main, so from 4.2.0's tag every PR here failed §R13 — a bare
  `LanguagePicker()` offers all eight kit languages, and the app shipped seven — until Russian
  landed. Both moved in this one change, which is why the pin bump is not a separate PR.

## 2.21.2 — 2026-08-20

The app agrees with itself about its own name.

### Changed
- **Twelve user-facing strings renamed "ClipMenu" → "ClipMenu 2".** 2.21.1 set `CFBundleName`
  to "ClipMenu 2" and stopped there, so the menu bar and About said one name while Quit, Open,
  the onboarding screens, the launch-at-login prompt, the paste-permission hint and the backup
  folder warning said another. All twelve are `L()` call sites; the dead What's New strings from
  earlier releases were left alone, and `AboutConfig`'s credit to Naotaka Morimoto's original
  ClipMenu deliberately keeps the original name.

  Because this app localizes with **the English sentence as the localization key**, each rename
  moved the key as well as the text — so the Swift call site and all seven `.strings` files had
  to change in lockstep or the six translations would have orphaned. Verified after the fact by
  diffing every live `L(…ClipMenu…)` call site against `en.lproj`'s key set: zero unresolved.
  This coupling is the reason the fleet is moving off English-as-key.

- **`AppInfo.displayName`'s fallback is now "ClipMenu 2".** It read "ClipMenu" while
  `MainMenuController.canonicalName`'s equivalent fallback read "ClipMenu 2" — a documented
  inconsistency whose own comment pointed at it ("whose fallback drops the \"2\""). Only reachable
  outside a configured bundle, e.g. `swift run`.

- 2.21.1's `.fixed` uninstall entry is **dropped** from What's New rather than carried forward.
  It shipped in 2.21.1; repeating it would tell a user the same fix landed twice.

## 2.21.1 — 2026-08-20

One user-facing fix, inherited from a DragonKit dependency bump. The What's New pane names it and
nothing else — the release also carries a debug-only fix that no user could ever see.

- **Uninstall now refuses to run when more than one copy of ClipMenu is on the Mac** (#94,
  DragonKit 4.1.0 → 4.1.1). Settings, the login item, support files and the Homebrew record are
  all keyed to the app's identity rather than its location, so two copies share every one of them
  and there is no way to tell whose is whose. Moving the running copy to the Trash was always
  safe; uninstalling a spare copy was not; it could silently remove the settings belonging to the
  copy actually in use. It now stops before removing anything and lists where the copies are.

- **DragonKit 4.1.1 also fixes a raw developer error surfaced by Settings > Updates** (#94), but
  only in local Debug builds — the real update checker was never reachable from a shipped copy, so
  no user could hit it. Recorded here rather than in the What's New pane, which is for changes a
  user can observe.

- **`CFBundleName` in the committed `Info.plist` now says "ClipMenu 2", matching what every build
  already produced.** Nothing a user can observe changes, and the entry says so rather than
  claiming a rename: the value in that file has never reached anyone. `App/scripts/run.sh`,
  `run-debug.sh` and dragon-release-ci's bundle-assembly step each `PlistBuddy Set :CFBundleName`
  from an app-name template that resolves to "ClipMenu 2", so the shipped app, the local release
  build and the Debug build have all called themselves "ClipMenu 2" the whole time. The committed
  "ClipMenu" was dead weight that read like the app's name while being overwritten in every path —
  which is the only reason it is worth correcting. `AppStore.folder`'s Application Support path is
  a separate hardcoded literal and is untouched, so no clipboard history or snippets move.

## 2.21.0 — 2026-08-18

Retires the last Sparkle appcast mirror in the Dragon fleet. Nothing a user can observe changed —
this release exists to move a publish destination, and the What's New pane says so rather than
dressing it up.

- **The appcast is published only to this repository** (#92). `release.yml` no longer passes
  `appcast_mirror_repo: teddychan/www.dragonapp.com`, so `docs/clipmenu-2/appcast.xml` here is the
  single destination. `MAC-APP-RELEASE-LIFECYCLE.md`: "Sparkle appcasts are update infrastructure,
  not marketing content." ClipMenu 2 was the last of the five apps still mirroring — spectacle-2
  and dragon-sample-app never did, ice-2 retired its mirror at v2.15.0 and yahoo-keykey-2 at
  v2.12.0 — so no Dragon app now publishes an appcast to the marketing site.

  Invisible to users by construction: `SUFeedURL` moved to the app-owned URL back in 2.20.4, and
  the mirror has only ever been a second copy of a feed nothing has read since. The release also
  stops depending on `PUBLIC_RELEASE_TOKEN` reaching the marketing-site repo; the built-in
  `GITHUB_TOKEN` publishes here, and that token is now used only for the Homebrew cask bump.

- **`www.dragonapp.com/clipmenu-2/appcast.xml` is left in place, frozen at v2.20.10.** It is
  deliberately not deleted: a stale feed offers an old version to anything still reading it, which
  is recoverable, while a 404 is not.

- **This had to ride a minor.** The trigger was chosen on 2026-08-11 to replace "when no supported
  version still reads the site", which named no measurable condition — the site is GitHub Pages and
  exposes no per-path traffic, so the last reader is unobservable. Dropping the mirror on a 2.20.x
  patch would have stranded copies still at 2.20.3 or older, which read the site and only the site.

## 2.20.10 — 2026-08-18

A maintenance release. Nothing in the app's own behaviour changed; both entries below are
internal, and the What's New pane says so rather than dressing them up.

- **DragonKit 4.0.0 → 4.1.0** (#88). The pin was already stale enough that CONFORMANCE §R10 was
  failing every PR in this repo, which is what prompted the bump. 4.1.0 adds §R16 to the kit's
  conformance spec and rewrites the kit's own changelog; it moves no shared pane, string or
  public signature, so every ClipMenu surface DragonKit owns renders identically to 2.20.9's.
  The one part a user can observe is About's `Built with · DragonKit v4.1.0` row — the same
  single observable the 2.20.4 and 2.20.5 notes claimed, and the reason this release reuses
  those notes' wording instead of inventing new copy.

- **`app/` is now `App/`** (#87), so the bundle inputs live where DragonKit CONFORMANCE §R16
  puts them: `App/Info.plist`, `App/AppIcon.icns`, `App/ClipMenu.entitlements`. 107 Swift files
  moved and none changed — paths, not code. `release.yml` already passed
  `swiftpm_working_directory: App` and `whats_new_path: App/Sources/…`, and the §R16 move is
  what `release.yml`'s `verify_only` dispatch was added for: a change to the build rather than
  to the app, previously testable only by cutting a public release.

- **The What's New notes reuse 2.20.2's two localized keys verbatim,** exactly as 2.20.5 did.
  The copy is already present in all seven `.lproj` files and is still exactly true, so no new
  key enters this release; a near-identical eighth translation of a true sentence is the drift
  those notes exist to avoid. The release gate still sees this file move, because the date and
  the section kind did.

## 2.20.9 — 2026-08-11

Ships #85, the last step of unifying one field across all five Dragon apps.

- **The bundle's copyright notice matches the About row byte for byte.**
  `NSHumanReadableCopyright` drops the word "Copyright": `Copyright © 2026 Teddy Chan` becomes
  `© 2026 Teddy Chan`, exactly what `DragonAbout.copyright(years:holder:)` renders.

  2.20.8 set the holder right and left the prefix, on the platform convention that Apple's own
  apps write `Copyright © 2024 Apple Inc.`. The convention is real, but it was the wrong
  tie-break: the point of this field is to say the same thing About says, and a value differing
  by one word still has to be compared rather than recognised.

- **All five apps now carry the identical value in both places.** The field held four different
  states when the audit started — a tagline here, two holders in Ice 2, and nothing at all in
  Spectacle 2, Yahoo! KeyKey 2 and Dragon Sample App. It shipped as ClipMenu 2.20.9, Ice 2
  2.14.7, Spectacle 2 2.5.5, Yahoo! KeyKey 2 2.12.1 and Dragon Sample App 1.4.5.

  Ice 2 was the last holdout and the interesting one: it kept both holders deliberately, on the
  reasoning that GPL-3.0 §4 makes this plist key the binary's copyright notice. §4's requirement
  is real; the identification of the key with it was not. `NSHumanReadableCopyright` is an
  **optional** Apple key that no licence names, and §4 is carried by Ice 2's `LICENSE` — which
  fills in the GPL's own notice template with Jordan Baird's name and year — and by its bundled
  acknowledgements. Both still name him.

- **`LICENSE` is untouched and still names both holders.** It is the licence document; this key
  is a display string. That distinction is the whole reason the two are allowed to differ, and
  the reason this release could change one without touching the other.

- **The notes describe the end state, not the delta.** Three releases touched this key within a
  few hours. Nearly every user arrives from 2.20.6, so the entry names what they will actually
  see change — a tagline replaced by a copyright — rather than narrating three steps none of
  them observed. The summary key is reused verbatim from 2.20.7; only the entry is restated, in
  all seven languages.

## 2.20.8 — 2026-08-11

Ships #82, which finishes what 2.20.7 started an hour earlier and gets the second half right.

- **The bundle's copyright notice names one holder.** `NSHumanReadableCopyright` is now
  `Copyright © 2026 Teddy Chan`. 2.20.7 had just set it to
  `Copyright © 2008–2014 Naotaka Morimoto · © 2026 Teddy Chan`; the part of that release worth
  keeping is that the key held `ClipMenu modern rewrite.` — a tagline where a copyright
  belongs — and the part worth undoing is the second holder.

- **The field is presentation, and that is what decides it.**
  `NSHumanReadableCopyright` is an **optional** Apple key. No licence names it and nothing
  requires it to exist — spectacle-2, yahoo-keykey-2 and dragon-sample-app ship no value at
  all. MIT's "include the above copyright notice in all copies" is discharged by `LICENSE`,
  which is untouched and still names both holders.

  So the same argument that settled About's copyright row — one holder, the app's own, with
  lineage carried by the `Original project` link and the `Based on` credit — reaches this field
  too. 2.20.7 reasoned that because CONFORMANCE §R14 leaves the key out of scope, it should
  mirror `LICENSE` instead. Out of scope means the rule does not reach the field; it does not
  mean the field must therefore disagree. The second reading is what left the About pane and
  Finder's Get Info panel making different claims about the same app.

- **ice-2 deliberately does not follow this.** It keeps both holders in its
  `INFOPLIST_KEY_NSHumanReadableCopyright`, and should: it is a git **fork** carrying Jordan
  Baird's actual source and history under GPL-3.0, whose §4 requires his notice to travel with
  the work, where ClipMenu 2 is an independent reimplementation reusing none of Naotaka
  Morimoto's source. The rationale is recorded in ice-2's own `AboutConfig.swift`. All five
  Dragon apps' About **panes** already render `© 2026 Teddy Chan` — that is DragonKit 4.0.0
  canon and no app can opt out, the two-holder overload being `@available(*, unavailable)`.

- **The notes describe the end state, not this version's delta.** The What's New pane shows
  only the current version's notes, and 2.20.7 existed for about an hour, so nearly every user
  arrives here from 2.20.6 and needs to be told the tagline is gone — not told about a
  distinction between two copyright values they never saw. The summary key is reused verbatim
  from 2.20.7 because it is still exactly true; only the entry is restated, plural to singular,
  in all seven languages. 2.20.5 set the precedent for reusing a key that still says the right
  thing.

## 2.20.7 — 2026-08-11

Ships #80, and nothing else. One string, in the one field where a wrong value is a legal
notice rather than a typo.

- **`NSHumanReadableCopyright` was a tagline, not a copyright.** `app/Info.plist` set it to
  `ClipMenu modern rewrite.` — a description of the app in the key macOS reserves for the
  bundle's copyright notice. It now reads
  `Copyright © 2008–2014 Naotaka Morimoto · © 2026 Teddy Chan`.

  Exactly the defect DragonKit records from yahoo-keykey-2, which once shipped
  `倉頡／簡易 輸入法` in its About copyright slot — see the doc comment on
  `DragonAbout.copyright(years:holder:)`. Both are the same mistake: a field that answers
  "who holds the copyright" filled with an answer to "what is this app".

  Narrow but observable, which is why it ships as `.fixed` rather than as maintenance.
  Finder's Get Info panel reads the key, so ⌘I on ClipMenu.app displays it. (The standard
  AppKit About panel reads it too; ClipMenu never opens one — its About is DragonKit's
  settings pane, which does not consult this key.) No ClipMenu source reads it either, so no
  behaviour changes.

- **The value tracks `LICENSE`, and the two dashes in it are not the same character.**
  `LICENSE` names two holders — `Copyright (c) 2008-2014 Naotaka Morimoto (original ClipMenu
  — …)` and `Copyright (c) 2026 Teddy Chan (this reimplementation)` — and the plist now names
  the same two, with the same years, in the same order.

  It does not copy `LICENSE`'s ASCII typography, because the plist value is display text and
  the licence document is not: `(c)` becomes `©`, and the hyphen in `2008-2014` becomes an en
  dash. That is the repo's own rendering of these two holders, not an invention — the About
  pane displayed `© 2008–2014 Naotaka Morimoto · © 2026 Teddy Chan`, en dash included, from
  #62 until #78 removed it. The `Copyright © … · © …` shape matches ice-2's
  `INFOPLIST_KEY_NSHumanReadableCopyright`, which is the only other Dragon app that has two
  holders to name.

- **This does not walk back 2.20.6's "names one holder instead of two".** Two different fields
  with two different jobs, and they are meant to differ. About's copyright row is a
  presentation slot DragonKit fixes at one holder — CONFORMANCE §R14 — and that rule puts
  `LICENSE`, `NSHumanReadableCopyright` and the licences page explicitly out of its own scope.
  ice-2 is the worked example: both holders in its `Info.plist`, one rendered in About.
  `AboutConfig` is untouched, and `contentSingleSourcesNameAndCopyright` still pins
  `© 2026 Teddy Chan`.

  Worth recording that DragonKit has since narrowed *why*. 2.20.6's note below justified the
  single-holder About row by arguing that ClipMenu 2 reuses none of the original's source and
  so has no upstream copyright to assert. The kit tried the same reasoning and retracted it
  (dragon-kit #63): it holds for yahoo-keykey-2 and fails for the two apps the change actually
  touched — ice-2 is a GPL-3.0 fork whose §4 requires the upstream notice to travel, and
  ClipMenu's own `LICENSE` names two holders outright. What survives is narrower and is all
  §R14 ever needed: the About row is a slot in a settings pane that read one way in three apps
  and another in two. Nothing about it displaces a legal notice, which is precisely why this
  release can fix one without touching the other. #80 corrects that reasoning where it was
  written down, in `contentSingleSourcesNameAndCopyright`'s doc comment; the 2.20.6 entry
  below is left as it shipped.

- **Two new What's New keys, translated into all seven languages.** The notes name the surface
  as each locale's Finder does — 情報を見る, 顯示簡介, 显示简介, Obtener información, Lire les
  informations — rather than transliterating "Get Info".

- **Nothing guards the key yet.** `swift test` runs without the app bundle, which is why
  `AppInfoCoverageTests` pins shapes rather than literals and why nothing here caught this in
  twenty patch releases. A guard belongs in DragonKit's conformance checker, where one rule
  would cover all five apps at once, rather than in a bespoke test in this repo — three of the
  five omit the key entirely.

## 2.20.6 — 2026-08-11

A real fix, unlike the last three patches: two rows of the About pane were wrong, and both
are things a user can open the pane and look at. Both were found the same way — by putting
all five Dragon apps' About panes side by side — and DragonKit 4.0.0, which this release
pins, is what makes each of them impossible to reintroduce.

- **`Original project` was missing from the links.** `AboutContent.originalWork` carried a
  name and an author but no URL: the URL was a separate optional `originalProjectURL:`
  parameter, and ClipMenu never passed it. So Credits read "Based on ClipMenu by Naotaka
  Morimoto" while the pane linked to ClipMenu nowhere — crediting a project and then not
  pointing at it. ice-2 had the identical gap; the other three apps did not.

  4.0.0 folds the URL into `OriginalWork`, which now drives both the link row and the
  credit, so half of it can no longer be supplied. The URL is
  `https://github.com/naotaka/ClipMenu` — the same repository `LICENSE` and `README.md`
  already cite, kept in one `private static let` so the pane cannot name a different fork
  or casing than the notices do.

- **The copyright named two holders.** It rendered
  `© 2008–2014 Naotaka Morimoto · © 2026 Teddy Chan`. Only ClipMenu and ice-2 did that, so
  two of five panes carried a line the other three lacked, and consistency is the smaller
  half of why it is gone. ClipMenu 2 is an independent Swift 6 reimplementation that reuses
  none of the original's source, so asserting Naotaka Morimoto's copyright over *this*
  binary states something the app's own notices contradict — yahoo-keykey-2 had already
  reasoned its way to the single-holder form for exactly that reason.

  The lineage is not lost by dropping it: it is carried twice over, by the `Original
  project` link and the `Based on` credit, and the original's licence text travels on the
  licences page. `LICENSE` keeps both holders and should — it is the licence document, and
  its upstream grant is what the MIT terms require. The About row is not that document.

- **DragonKit 3.4.0 → 4.0.0, and it is breaking.** Three call-site changes, all in
  `AboutConfig.swift`: `licensesURL` is required and moves to its fixed position after
  `supportURL`; `OriginalWork` takes `url:`; and `DragonAbout.copyright(original:)` is gone
  in favour of `copyright(years:holder:)`, with an `@available(*, unavailable)` overload
  left behind to turn a stale call into a readable error rather than "extra argument".

  Nothing else in the app needed adapting — the kit's About slots are compile-enforced now,
  which is the point of the major. `licensesURL` stays **ungated** on purpose: the four
  bundled JavaScript libraries behind the Actions transforms ship in every build, including
  the Mac App Store one where Sparkle does not, so the page always has something to say.
  `attributions` keeps its `SPARKLE` gating for the same reason inverted — the MAS build
  bundles no third-party code and must not claim it does.

- **Three new What's New keys, translated into all seven languages.** No reuse this time.
  2.20.5 deliberately reused 2.20.2's copy because it was the same release (a kit bump with
  nothing user-facing); this one has something new to say, so it says it. The notes name the
  About pane the way each locale's UI does — `DragonKit.pane.about` renders as Acerca de,
  À propos, 情報, 정보, 关于 and 關於 — rather than transliterating "About".

- **The appcast mirror stays.** `appcast_mirror_repo` is retired by the next MINOR release,
  per the trigger recorded in `release.yml` at 2.20.5. This is a patch, so it keeps
  publishing to both locations.

## 2.20.5 — 2026-08-11

Maintenance only, and unusually literally so: the only thing that changed about the shipped
app is which version of the shared kit it links, and the only place that is visible is the
About pane.

- **DragonKit 3.3.0 → 3.4.0 is the whole release.** `app/Package.swift`'s pin moved, so
  About's Credits now reads "Built with · DragonKit v3.4.0" instead of v3.3.0. That row is
  the single observable difference; no behaviour, setting, shortcut or stored file changes.

  Both of 3.4.0's new parameters are defaulted — `LanguagePicker(languages:onChange:)` —
  so the bump is source-compatible and nothing here had to be adapted for it. ClipMenu
  calls `LanguagePicker()` in `PreferencesPanes.swift` and deliberately keeps the default
  language list: the argument was added for ice-2, which has translated its own strings
  into Simplified Chinese only and whose picker therefore offered six languages it could
  not deliver, whereas ClipMenu ships all seven the kit does. The picker it renders is
  byte-for-byte the one 2.20.4 rendered.

  The What's New notes reuse 2.20.2's summary *and* entry keys rather than adding an eighth
  near-identical sentence across seven `.lproj` files. 2.20.2 was this same release —
  DragonKit 3.2.0 → 3.3.0, nothing user-facing — and
  "Updated the shared Dragon toolkit that ClipMenu is built with." was already the vetted
  translation of it. `2.20.4`'s SUFeedURL sentence stays in the strings files: it describes
  a release users can still be upgrading from.
- **No release-plumbing change, despite `release.yml` moving.** The other commit since
  v2.20.4 was comment-only — it replaced the mirror's unmeasurable retirement condition
  ("when no supported version still reads the site") with a real trigger, the next MINOR
  release. `appcast_mirror_repo` therefore stays through this patch and goes away at
  2.21.0; the parsed workflow is identical to v2.20.4's.

## 2.20.4 — 2026-08-11

Maintenance only from a user's point of view. Step 2 of 2 in giving ClipMenu its own
Sparkle update feed.

- **`SUFeedURL` now points at this repository** —
  `raw.githubusercontent.com/teddychan/clipmenu-2/main/docs/clipmenu-2/appcast.xml` —
  instead of `www.dragonapp.com/clipmenu-2/appcast.xml`. dragon-kit's
  `docs/MAC-APP-RELEASE-LIFECYCLE.md`: "Sparkle appcasts are update infrastructure, not
  marketing content. Each app should host its production appcast in its own repository so
  an outage, permission problem, or rejected change in the marketing-site repository
  cannot interfere with update delivery."

  2.20.3 was step 1: it set `appcast_repo` to this repo and `appcast_mirror_repo` to the
  site, which is what first created `docs/clipmenu-2/appcast.xml` here. The order matters
  in one direction only — flipping `SUFeedURL` before a release had populated the new
  location would have pointed every install at a 404. Verified before this change: both
  copies exist and are byte-identical (sha256 `8c56943…`), and the new URL serves 200.

  `appcast_mirror_repo` deliberately stays. Every copy at 2.20.3 or earlier still reads
  the site, and it is the release after which no supported version does that may drop it.
- **The Mac App Store workflow no longer owns a `mas-v*` tag series.** It is dispatch-only
  and takes an existing public `vX.Y.Z`, per the same spec's "one public tag namespace per
  repository". Nothing about the shipped app changes; the nine historical `mas-v*` tags stay
  for provenance.

## 2.20.3 — 2026-08-11

One user-visible fix; the other two changes are release plumbing.

- **Uninstalling left Homebrew's records claiming ClipMenu was still installed.**
  `UninstallConfig` never passed `homebrewCask`, so the in-app uninstall moved the app
  to the Trash and stopped there. Homebrew never watches the filesystem, so its receipt
  still said the cask was installed and `Caskroom/clipmenu-2/<version>/ClipMenu 2.app`
  was a dangling symlink; `brew install --cask clipmenu-2` then refused outright —
  "already installed" — for an app that wasn't there, with nothing pointing at
  `brew reinstall` as the way out. ice-2 and dragon-sample-app already passed the token.

  Passing it flat would have been worse: `brew uninstall --cask --force` is not
  bundle-scoped, and `Casks/clipmenu-2.rb` carries
  `uninstall quit: "com.dragonapp.clipmenu-2"`, so from the Debug build it would have
  quit and deleted the installed release. Three builds must issue nothing — the Debug
  build and a build with no bundle id (both caught by the kit's fail-closed
  `UninstallConfig.caskToken`), and the Mac App Store build, which no bundle-id
  comparison can see because it is sandboxed but carries the same id. That one is
  excluded by `DistributionChannel`, this app's existing runtime channel check.
- **The release moved to `dragon-release-ci@v6`, with `whats_new_path`.** v6's tag gate
  accepts only an exact `vX.Y.Z` and requires a What's New source that has changed since
  the preceding tag. Both halves had to land in one commit: passing `whats_new_path` to
  v5 fails at startup, and omitting it on v6 fails the gate.
- **The Sparkle appcast now publishes to this repository as well as the marketing site.**
  Step 1 of 2 in giving the app its own update feed, per dragon-kit's
  `docs/MAC-APP-RELEASE-LIFECYCLE.md`. `SUFeedURL` still points at the site — which is
  still being written — so nothing changes for any existing install; this release is what
  first populates `docs/clipmenu-2/appcast.xml` here. Step 2 moves `SUFeedURL` to it.

## 2.20.2 — 2026-08-10

Maintenance only from a user's point of view: every defect below is reachable
solely from a local Debug build running beside the installed release, so the
What's New entry says maintenance-only rather than inventing a fix to claim.

- **`scripts/run-debug.sh` appended ` (Debug)` to `CFBundleShortVersionString`.**
  That field is the sole source of truth for the app's semantic version and the one
  string the release tag is checked against (`assert_tag_matches_plist`); a channel
  label inside it makes the version non-numeric. dragon-kit's
  `docs/MAC-APP-RELEASE-LIFECYCLE.md` forbids it outright. The script now asserts
  `X.Y.Z` and stamps `DragonBuildChannel = Debug`, which DragonKit 3.3.0 renders as
  `v2.20.2 Debug (76)` — so a screenshot still can't be mistaken for the release
  build, which was the suffix's original purpose.
- **The debug bundle could have checked the production appcast.** It inherited the
  release's `SUFeedURL`, so an update would have replaced the debug build with the
  public one. The script now deletes `SUFeedURL` and sets `SUEnableAutomaticChecks`
  false: Sparkle refuses to start without a feed, `DragonUpdater` leaves its
  `SPUUpdater` nil, and every route goes inert at the data layer. `UpdaterUI`
  additionally reports unsupported on the Debug channel, so the menu item is absent
  rather than inert. The Updates *pane* is deliberately still built — with no feed it
  renders inert, and the sidebar then matches the release build pane for pane.
- **`ActionStore.saveURL` wrote `actions.plist` into the release's folder.** It
  hardcoded `Application Support/ClipMenu` while everything else routes through the
  debug-aware `AppStore.folder`, so a debug build edited the installed release's
  action set — or wrote the defaults over it on first launch. It was also the path
  `SettingsWindowController.uninstallConfig` already declared, so uninstall was
  cleaning a file nothing wrote. Identical for a release build; no migration.
- DragonKit 3.2.0 → 3.3.0 (`DragonAbout.buildChannel` / `isDebugBuild`, and the
  channel-aware `versionString()`).

## 2.20.1 — 2026-08-10

Housekeeping only — no user-facing change, and no What's New entry.

- **The committed `CFBundleVersion` was a stale `2.18.1`, two releases behind the
  marketing version beside it.** It is inert: every build path stamps
  `git rev-list --count HEAD` over it before the app is assembled —
  `app/scripts/run.sh`, `app/scripts/run-debug.sh`, `.github/workflows/release-mas.yml`,
  and the free channel inside `teddychan/dragon-release-ci`. So nothing shipped with
  the wrong build number; the problem was that the checked-in value *read* like a real
  version and invited someone to trust or "fix" it. Reset to `1`, the obvious inert
  placeholder the sibling Dragon repos use (dragon-kit's `sample-app/Info.plist`), so
  the file says "this gets overwritten" instead of naming a release.
- `CFBundleShortVersionString` 2.20.0 → 2.20.1. This is the only version the release
  tag is checked against (`assert_tag_matches_plist`), and it stays hand-maintained.

## 2.19.1 — 2026-08-07

Fixes from an engineering-standard audit of the clipboard, menu, and snippet
paths. Two were reachable from the Settings panes by typing a plausible number.

- **Data loss: a history size of `0` deleted the entire clipboard history.** The
  cap was passed unclamped into the trim query, where Core Data reads
  `fetchOffset = 0` as "select every row" (and `fetchLimit = 0` as "no limit") —
  so the next copy deleted every clip including the one just captured, with no
  warning and no recovery (history is not part of backup). A negative value made
  the fetch throw, which `try?` swallowed, silently disabling trimming for good.
  `ClipStore.maxHistorySize` now floors at 1.
- **Crash: a negative tool-tip length trapped on every menu build.**
  `clipToolTip` feeds the value to `String.prefix(_:)`, which traps on a negative
  count, so the app died on every status-item click until the pref was reset.
  Clamped in `MainMenuController.MenuPrefs`, beside the existing thumbnail clamp.
- **Lowering the history cap now applies immediately, after a confirmation.**
  `trim()` only ran inside `capture()`, so the menu hid the surplus clips while
  they stayed readable on disk until the next copy — lowering the cap to prune
  sensitive history gave a false sense of deletion, and raising it brought every
  clip back. New `ClipStore.enforceCapNow`; the alert names the exact count.
- **The numeric preference fields are bounded** (`PreferenceRanges`), replacing
  free-form text fields that accepted any integer. Settings and the onboarding
  wizard now share the constants instead of drifting (`1...999` vs unbounded).
- **Snippet edits no longer lose work silently.** All 12 mutation sites in the
  editor saved with `try? context.save()`; a failed write left the views showing
  the in-memory context while the work was gone at next launch. They route
  through one helper that raises a single persistent banner, localized in all 7
  languages.
- **The App menu and Uninstall pane read the app's real name.** They used a
  hardcoded `"ClipMenu 2"`, so a debug build labelled itself as the release app
  while acting on debug data. Now read from the bundle, with the literal kept as
  the `swift run` fallback.
- **19 comments cited a deleted `CLAUDE.md`.** Its invariants are published as
  `docs/design-invariants.md` and cited by section *name* — the numbers had
  already drifted, with several `§2` citations pointing at the wrong section.
- `scripts/run-debug.sh` stamps `(Debug)` onto the version and launches with
  `open -n`, so a debug build can't be mistaken for the release in a screenshot
  and LaunchServices can't resolve to a stale bundle from another checkout.
- **DragonKit 2.1.0 → 2.3.0** (`app/Package.swift`, `app/Package.resolved`),
  clearing conformance R10. Of the kit's three fixes only the failed-uninstall
  one reaches this app — it ships `UninstallSettingsPane`; it does not use
  `DragonSettingsStore` (so the settings-reset-on-upgrade bug never applied) or
  `DragonBackup` (so the malformed-restore fix never applied). No app code
  changes were needed.

## 2.19.0 — 2026-08-04

Uninstall left the status-item menu. DragonKit 2.0.0's `DragonAppMenu` no longer
takes an `onUninstall` handler, so the App-menu section is About · Check for
Updates… (direct build only) · Settings… · — · Quit. A rare destructive action
does not belong one click from Quit; it stays reachable as DragonKit's
`UninstallSettingsPane`, the last pane in Settings, which ClipMenu already ships.

- **DragonKit 1.5.0 → 2.0.0** (`app/Package.swift`, `app/Package.resolved`).
  Breaking only in the menu-builder signature described above.
- `MainMenuController` drops its `uninstall(_:)` action; the menu assertion in
  `MainMenuControllerCoverageTests` now checks Uninstall is *absent*, scoped to
  the App-menu tail so a clipboard entry above can't satisfy the match.
- What's New copy refreshed for this release in all 7 localizations.

## 2.17.11 — 2026-07-11

Maintenance release: test-coverage and internal quality only — no user-facing
behavior changes (the app is functionally identical to 2.17.10).

### Tests & coverage — phase 2 (SwiftUI + reorder + backup/restore)

Pushed coverage from the logic layer into the SwiftUI/UI layer and the
drag-reorder ("layout movement") and backup/restore code.

- **Test cases: 313 → 374** (+61), across **53 → 59** test files.
- **Line coverage: 39.3% → 74.2%** overall (region 45.8% → 67.3%, function 67.3%).
- **Backup & restore → 100%** (all in ClipMenu's `Premium/`, not DragonKit):
  `BackupManager`, `BackupModels`, `BackupFolder` at 100%; `FolderBackupStore` 97%,
  `BackupRetention` 97%, `SnippetSnapshot` 93%, `SettingsSidecar` 95%. Restore
  error paths (undecodable payload, newer-schema rejection) and the restore UI
  (`RestoreVersionsView`) are covered.
- **Layout movement (drag-reorder):** extracted the snippet editor's reorder /
  index-renumber arithmetic out of `SnippetEditorView` into a pure, testable
  `ManualReorder` helper (`moved` / `afterRemoving` / `nextIndex`) — now **100%**;
  `SnippetEditorView` 0% → 59%.
- **SwiftUI panes via ViewInspector** (new test-only dependency, `ClipMenuTests`
  target only — never linked by the app): `PreferencesPanes` 0% → 76% (incl. the
  Sync & Backup pane), `OnboardingView` 0% → 88%, `MainMenuController` 61%.
- **Test execution is now serial.** Run the suite with `app/scripts/test.sh`
  (wraps `swift test --arch arm64 --no-parallel`). Several suites exercise
  process-global singletons (`NSPasteboard.general`, the shared UserDefaults backup
  baseline); Swift Testing's default cross-suite parallelism races them, and
  `.serialized` only orders tests within a suite — so the canonical run is serial.
- Still not unit-testable (need a running `NSApplication` / real system state):
  window `show()` hosting (`SettingsWindowController`, the window controllers), the
  `@main`/AppDelegate lifecycle (`App`), Carbon hot-key registration, and the
  fire-and-forget backup `Task` against the live store — these are the bulk of the
  remaining ~26%.

### Tests & coverage

Expanded the unit-test suite (Swift Testing) to lock down the app's logic layer.

- **Test cases: 147 → 313** (+166), across **29 → 53** test files. All green.
- **Line coverage: 18.8% → 39.3%** overall (region 21.6% → 37.6%), measured with
  `swift test --enable-code-coverage` + `xcrun llvm-cov`.
- The **non-UI logic layer is now near-exhaustively covered** — 24 source files at
  ≥93%, including:
  - `ClipCapture` (clipboard capture, dedup, trim, thumbnails) 49% → **98.8%**
  - `ActionStore` 65% → **97.9%**, `ScriptableClip` 62% → **97.8%**
  - `ActionEngine` 8% → **93.2%**, `BuiltInActions`, `Paster`, `HotKeyCenter` (pure logic)
  - `MainMenuController` (NSMenu building) 5.8% → **60.9%**
  - `Thumbnailer`, `MenuIconCache`, `StatusItemController` 0% → **95–98%**
  - Backup/premium stack (`BackupManager`, `FolderBackupStore`, `BackupRetention`,
    `BackupModels`, `BackupScheduler`) and `StoreMigration`
  - `HistoryExport`, `Updater`, `AboutConfig`, `WhatsNewConfig`, `DistributionChannel` at **100%**
- New characterization tests assert real behavior only (menu trees, pasteboard
  contents, dedup/thumbnail derivation, Codable round-trips, Carbon⇄Cocoa key
  formatting); no source code was modified.

**Coverage ceiling (documented, not a gap to chase):** the remaining ~60% is code
a headless `swift test` process cannot execute — pure SwiftUI view bodies
(`PreferencesPanes`, `SnippetEditorView`, `OnboardingView`), the `@main`/AppDelegate
lifecycle and window `show()` hosting, and system side-effects (live `CGEvent`
paste, Carbon hot-key registration, cursor-anchored pop-ups). Covering the SwiftUI
views would need the ViewInspector test dependency (~65% ceiling); true ~90% would
require an XCUITest UI-automation target driving a launched app.
