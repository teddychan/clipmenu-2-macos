import AppKit
import Foundation
import SwiftData

// Clipboard capture → SwiftData store. Mirrors ClipsController.m:
//  - _updateClips                  (587-649): dedup-by-hash bumps lastUsedDate, else add + trim
//  - _makeClipFromPasteboard       (651-729): per-type payload reads, RTFD-over-RTF, drop-when-empty
//  - _makeTypesFromPasteboard      (731-760): per-type store gating, TIFF/PICT fold
//  - _trimHistorySize              (795-813): drop oldest beyond maxHistorySize
//  - sortedClips                   (190-212): lastUsed (reorder) / created, descending
//
// PICT is dropped. Reading NSPasteboard happens off the main actor on
// the PasteboardMonitor actor (see PasteboardReader below); persistence runs
// off the main actor in a @ModelActor.

// MARK: - Supported types (the 7 live legacy types; Clip.m:110-136, PICT dropped)

/// Canonical legacy type names kept on `ClipRecord.typeIdentifiers` (priority order).
/// Using the legacy names keeps placeholder-title logic (row 44) simple.
enum ClipType {
    static func name(for type: NSPasteboard.PasteboardType) -> String? {
        switch type {
        case .string:  return "String"
        case .rtf:     return "RTF"
        case .rtfd:    return "RTFD"
        case .pdf:     return "PDF"
        case .fileURL: return "Filenames"
        case .URL:     return "URL"
        case .tiff:    return "TIFF"
        default:       return nil
        }
    }
}

// MARK: - Sendable snapshot (handed from the main actor to the store actor)

struct PasteboardSnapshot: Sendable {
    var typeNames: [String]          // legacy names, priority order (ClipRecord.typeIdentifiers)
    var stringValue: String?
    var rtfData: Data?
    var pdfData: Data?
    var filenames: [String]?
    var urlString: String?
    var imageData: Data?             // original TIFF bytes (menu thumbnail row 53 downsamples)
    var contentHash: Int             // stable content fingerprint for de-dup
}

// MARK: - Pasteboard read (off the main actor)

// Runs on the caller's executor — the PasteboardMonitor actor — so multi-MB
// payload copies (full TIFF/PDF/RTFD, and synchronous resolution of promised
// pasteboard data) never stall the main actor
// (design-invariants.md — Clipboard polling). NSPasteboard is
// not Sendable but is not @MainActor-bound either: each call obtains
// NSPasteboard.general locally and never sends it across an isolation
// boundary; only the Sendable PasteboardSnapshot crosses actors.
enum PasteboardReader {
    /// Build a snapshot from the general pasteboard, honoring per-type store
    /// gating and TIFF/PICT folding. Returns nil when nothing storable remains
    /// (ClipsController.m:670-678).
    static func snapshot() -> PasteboardSnapshot? {
        // Skip capture when the frontmost app is excluded (ClipsController.m:606-608,
        // 768-793; default exclude list = OpenOffice.org, AppController.m:103-118).
        if frontAppIsExcluded() { return nil }

        let pboard = NSPasteboard.general
        guard let available = pboard.types else { return nil }

        // Honor the nspasteboard.org privacy markers: password managers mark
        // secrets / transient / auto-generated writes with these types and
        // expect clipboard recorders to skip the change entirely.
        if containsPrivacyMarker(available.map(\.rawValue)) { return nil }

        let store = storeTypes()
        // If the user disabled every type, store nothing (ClipsController.m:675-678).
        guard store.values.contains(true) else { return nil }

        // Ordered, gated, TIFF/PICT-folded type names (ClipsController.m:731-760).
        var names: [String] = []
        for type in available {
            guard let name = ClipType.name(for: type) else { continue }
            guard store[name, default: true] else { continue }
            if name == "TIFF", names.contains("TIFF") { continue }
            if !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return nil }

        var stringValue: String?
        var rtfData: Data?
        var pdfData: Data?
        var filenames: [String]?
        var urlString: String?
        var imageData: Data?

        for name in names {
            switch name {
            case "String":
                stringValue = pboard.string(forType: .string)
            case "RTFD":
                rtfData = pboard.data(forType: .rtfd)
            case "RTF":
                if rtfData == nil { rtfData = pboard.data(forType: .rtf) } // RTFD wins (ClipsController.m:697)
            case "PDF":
                pdfData = pboard.data(forType: .pdf)
            case "Filenames":
                let urls = pboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                ) as? [URL]
                filenames = urls?.map(\.path)
            case "URL":
                urlString = NSURL(from: pboard)?.absoluteString
            case "TIFF":
                if NSImage.canInit(with: pboard) {
                    imageData = pboard.data(forType: .tiff)
                }
            default:
                break
            }
        }
        // An app can declare types and then supply no data for any of them. Store
        // nothing then: every such copy hashes alike, so one blank clip would keep
        // returning to the top of history.
        guard stringValue != nil || rtfData != nil || pdfData != nil
                || filenames?.isEmpty == false || urlString != nil || imageData != nil
        else { return nil }

        let hash = stableContentHash(
            typeNames: names, stringValue: stringValue, rtfData: rtfData,
            pdfData: pdfData, filenames: filenames, urlString: urlString, imageData: imageData
        )

        return PasteboardSnapshot(
            typeNames: names, stringValue: stringValue, rtfData: rtfData, pdfData: pdfData,
            filenames: filenames, urlString: urlString, imageData: imageData, contentHash: hash
        )
    }

    /// Pasteboard types that mark a clipboard write as not-for-recording
    /// (nspasteboard.org de facto standard, used by 1Password, Bitwarden,
    /// KeePassXC, Dashlane, …). Pure helper so the rule is unit-testable.
    static func containsPrivacyMarker(_ typeNames: [String]) -> Bool {
        let markers: Set<String> = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType",
        ]
        return typeNames.contains(where: markers.contains)
    }

    /// Per-type store toggles, default all-YES (AppController.m:142, 48-58).
    private static func storeTypes() -> [String: Bool] {
        let names = ["String", "RTF", "RTFD", "PDF", "Filenames", "URL", "TIFF"]
        let stored = UserDefaults.standard.dictionary(forKey: PreferenceKeys.storeTypes) as? [String: Bool]
        var result: [String: Bool] = [:]
        for name in names { result[name] = stored?[name] ?? true }
        return result
    }

    /// True if the frontmost app's bundle id is in the exclude list
    /// (ClipsController.m:768-793, `_frontProcessIsInExcludeList`).
    private static func frontAppIsExcluded() -> Bool {
        isExcluded(currentFrontBundleID(), in: excludedBundleIdentifiers())
    }

    /// The frontmost app's bundle id, or nil. Read on the caller's (off-main)
    /// executor, matching the rest of the snapshot read; NSWorkspace's frontmost
    /// query is safe from any thread.
    static func currentFrontBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Whether `bundleID` is excluded. Pure so the exclusion rule is unit-testable.
    static func isExcluded(_ bundleID: String?, in excluded: Set<String>) -> Bool {
        guard let bundleID, !excluded.isEmpty else { return false }
        return excluded.contains(bundleID)
    }

    /// Excluded app bundle identifiers from the `excludeApps` default; falls back
    /// to the legacy default of OpenOffice.org (AppController.m:103-118).
    static func excludedBundleIdentifiers() -> Set<String> {
        if let list = UserDefaults.standard.array(forKey: PreferenceKeys.excludeApps) as? [[String: String]] {
            return Set(list.compactMap { $0["bundleIdentifier"] })
        }
        return ["org.openoffice.script"]
    }
}

/// Stable content fingerprint (FNV-1a) over the clip's actual stored content.
/// Stable across launches (unlike `Hasher`), which persisted de-dup needs.
func stableContentHash(
    typeNames: [String], stringValue: String?, rtfData: Data?, pdfData: Data?,
    filenames: [String]?, urlString: String?, imageData: Data?
) -> Int {
    var hash: UInt64 = 1469598103934665603
    func feed(_ byte: UInt8) {
        hash = (hash ^ UInt64(byte)) &* 1099511628211
    }
    func feed(_ s: String) {
        for byte in s.utf8 { feed(byte) }
    }
    func feed(_ data: Data?, label: String) {
        guard let data else {
            feed("\(label):0")
            return
        }
        feed("\(label):\(data.count):")
        for byte in data { feed(byte) }
    }
    feed(typeNames.joined(separator: ","))
    if let stringValue { feed("s:" + stringValue) }
    if let filenames { feed("f:" + filenames.joined(separator: "\n")) }
    if let urlString { feed("u:" + urlString) }
    feed(rtfData, label: "rtf")
    feed(pdfData, label: "pdf")
    feed(imageData, label: "img")
    return Int(bitPattern: UInt(truncatingIfNeeded: hash))
}

// MARK: - Store actor (off the main actor)

@ModelActor
actor ClipStore {
    /// Capture a snapshot: bump lastUsedDate if an identical clip exists
    /// (ClipsController.m:619-636), else insert + trim (642-643).
    ///
    /// `defaults` is injectable purely so tests can exercise a specific history cap
    /// without writing to `UserDefaults.standard`, which is process-global: a cap
    /// leaked from one suite silently trims another suite's store, and Swift
    /// Testing runs sibling suites in parallel (see PasteboardSerialized). Matches
    /// the injectable domain the descriptors below already take.
    func capture(_ snapshot: PasteboardSnapshot, defaults: UserDefaults = .standard) {
        let hash = snapshot.contentHash
        let existing = FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.contentHash == hash })
        if let match = try? modelContext.fetch(existing).first {
            match.lastUsedDate = Date()
            try? modelContext.save()
            return
        }

        // Derive the small display thumbnail now (off the main actor). The
        // original bytes are stored untouched for byte-exact paste
        // (design-invariants.md — Images and memory).
        let thumbnailData = snapshot.imageData.flatMap(Thumbnailer.makeThumbnailData(from:))

        let record = ClipRecord(
            createdDate: Date(),
            lastUsedDate: Date(),
            typeIdentifiers: snapshot.typeNames,
            stringValue: snapshot.stringValue,
            rtfData: snapshot.rtfData,
            pdfData: snapshot.pdfData,
            filenames: snapshot.filenames,
            urlString: snapshot.urlString,
            image: snapshot.imageData.map(ClipImage.init(data:)),
            thumbnailData: thumbnailData,
            contentHash: hash
        )
        // Persist the new clip BEFORE trimming. trim() selects the overflow with a
        // fetchOffset descriptor, and an unsaved (pending) insert is not ordered by
        // that fetch the way a saved row is — so trimming first lets a full history
        // (count == maxHistorySize) pick the just-inserted clip as the "overflow"
        // and delete it, silently dropping every new copy once the store fills up.
        modelContext.insert(record)
        try? modelContext.save()
        trim(defaults: defaults)
        try? modelContext.save()
    }

    /// One-time migration: generate the small `thumbnailData` for image clips
    /// captured before thumbnails were stored, so they still show a picture in
    /// the menu. Memory-safe — each full image is read in its own short-lived
    /// context and released before the next, so peak usage is one image, not the
    /// whole history. Idempotent: after the first run no image clip lacks a
    /// thumbnail, so nothing is processed.
    func backfillThumbnails() {
        var descriptor = FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.thumbnailData == nil })
        descriptor.propertiesToFetch = [\.typeIdentifiers]
        guard let candidates = try? modelContext.fetch(descriptor) else { return }
        let ids = candidates
            .filter { $0.typeIdentifiers.contains("TIFF") }
            .map(\.persistentModelID)
        guard !ids.isEmpty else { return }

        for id in ids {
            let context = ModelContext(modelContainer)
            guard let clip = context.model(for: id) as? ClipRecord,
                  let data = clip.image?.data,
                  let thumbnail = Thumbnailer.makeThumbnailData(from: data) else { continue }
            clip.thumbnailData = thumbnail
            try? context.save()
            // `context` is released here, freeing the faulted full image.
        }
    }

    /// Delete clips that hold no data at all, saved before snapshot() skipped such
    /// copies; the menu showed each as a blank "N." row. Runs at every launch and
    /// finds nothing once they are gone.
    func removeEmptyClips() {
        // One condition only: CI's older compiler can't type-check a compound
        // #Predicate here. The rest is checked in Swift, cheapest field first.
        let descriptor = FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.stringValue == nil })
        guard let candidates = try? modelContext.fetch(descriptor) else { return }
        let empty = candidates.filter {
            $0.urlString == nil && $0.image == nil && ($0.filenames?.isEmpty ?? true)
                && $0.rtfData == nil && $0.pdfData == nil
        }
        guard !empty.isEmpty else { return }
        for clip in empty { modelContext.delete(clip) }
        try? modelContext.save()
    }

    /// Drop oldest clips beyond maxHistorySize (ClipsController.m:795-813). Runs on
    /// every capture, so it fetches only the overflow (offset past the cap), not the
    /// whole sorted history — with the `lastUsedDate`/`createdDate` index this stays
    /// cheap even under rapid copies and a large history
    /// (design-invariants.md — History bound).
    private func trim(defaults: UserDefaults) {
        // Fetch the overflow directly: the offset descriptor already returns []
        // when the store is at or under the cap, so the previous explicit
        // fetchCount guard was a redundant extra query on every capture. Dropping
        // it still trims correctly in bulk when the user LOWERS the cap — the
        // offset fetch then returns every clip beyond the new, smaller cap.
        guard let overflow = try? modelContext.fetch(Self.trimOverflowDescriptor(defaults)) else { return }
        for record in overflow {
            modelContext.delete(record)
        }
    }

    /// Sort: lastUsedDate (reorder, default) else createdDate, descending
    /// (ClipsController.m:190-212; reorder default AppController.m:134).
    static var sortDescriptor: SortDescriptor<ClipRecord> {
        let reorder = UserDefaults.standard.object(forKey: PreferenceKeys.reorderClipsAfterPasting) as? Bool ?? true
        return reorder
            ? SortDescriptor(\ClipRecord.lastUsedDate, order: .reverse)
            : SortDescriptor(\ClipRecord.createdDate, order: .reverse)
    }

    /// The user's configured history cap (default 20). Single source of truth for
    /// the bound applied everywhere clip history is materialized — storage
    /// (`trim`), the menu and its search, history export, and the upgrade
    /// migration — so the on-disk and in-view history never exceed it
    /// (design-invariants.md — History bound).
    ///
    /// Clamped to at least 1: the Settings field is free-form, and to the descriptors
    /// below a stored 0 does NOT mean "keep nothing". `fetchLimit = 0` means "no
    /// limit", so `boundedHistoryDescriptor` would materialize the WHOLE store, while
    /// `fetchOffset = 0` selects every row — so `trim()` would delete the entire
    /// history including the clip just captured (unrecoverable: history is not part of
    /// backup). A negative value makes the offset fetch throw (SQLite error 20), whose
    /// `try?` swallows it and silently stops trimming for good. 1 is the smallest cap
    /// both descriptors express correctly, and matches the `guard limit > 0` that
    /// `StoreMigration.copyClipsInBatches` already applies defensively.
    static func maxHistorySize(_ defaults: UserDefaults = .standard) -> Int {
        max(1, defaults.object(forKey: PreferenceKeys.maxHistorySize) as? Int ?? 20)
    }

    /// Newest-first fetch of the visible history, capped to `maxHistorySize`. The
    /// `ClipRecord.image` relationship stays faulted, so this never loads the
    /// multi-MB originals — callers that only need text/thumbnails (menu, search,
    /// export) pay nothing for image clips.
    static func boundedHistoryDescriptor(_ defaults: UserDefaults = .standard) -> FetchDescriptor<ClipRecord> {
        var descriptor = FetchDescriptor<ClipRecord>(sortBy: [sortDescriptor])
        descriptor.fetchLimit = maxHistorySize(defaults)
        return descriptor
    }

    /// Case/diacritic-insensitive "contains" match over a clip's text, used by the
    /// History-menu search (⌘⌃V) to filter in the store rather than fetching every
    /// row and filtering in Swift on each keystroke. Clips without text (image-only)
    /// never match. Kept beside the bounded-history descriptors so the whole
    /// history-fetch policy lives in one place and stays unit-testable.
    /// `localizedStandardContains` is the Finder-style match SwiftData pushes into
    /// SQLite (CONTAINS[cd]).
    static func searchPredicate(_ query: String) -> Predicate<ClipRecord> {
        #Predicate<ClipRecord> { clip in
            clip.stringValue?.localizedStandardContains(query) ?? false
        }
    }

    /// How many stored clips are past `cap` — i.e. how many `enforceCapNow` would
    /// delete. Uses a SQL COUNT rather than materializing rows, so the Settings
    /// pane can ask this on every edit of the history-size field.
    static func overflowCount(beyondCap cap: Int, in context: ModelContext) -> Int {
        let total = (try? context.fetchCount(FetchDescriptor<ClipRecord>())) ?? 0
        return max(0, total - max(1, cap))
    }

    /// `enforceCapNow` against an explicit defaults domain — injected by tests so
    /// they never touch `UserDefaults.standard`, which is process-global and would
    /// race the other suites (see PasteboardSerialized).
    @discardableResult
    static func enforceCapNow(in context: ModelContext, defaults: UserDefaults) -> Int {
        guard let overflow = try? context.fetch(trimOverflowDescriptor(defaults)) else { return 0 }
        for record in overflow { context.delete(record) }
        try? context.save()
        return overflow.count
    }

    /// Apply the current cap to `context` immediately, deleting every clip past it,
    /// and report how many were dropped.
    ///
    /// `trim()` runs only inside `capture()`, so LOWERING the cap otherwise left the
    /// older clips on disk until the user happened to copy something next. That was
    /// worse than it sounds: `boundedHistoryDescriptor` bounds the *view* straight
    /// away, so the menu hid those clips while they stayed fully readable in the
    /// store — a user who lowered the cap to prune sensitive history got a false
    /// sense of deletion, and raising it again brought every clip back.
    ///
    /// Destructive and unrecoverable (history is not part of backup), so the caller
    /// must confirm with the user first — see the history-size field in
    /// `GeneralPreferencesView`.
    @discardableResult
    static func enforceCapNow(in context: ModelContext) -> Int {
        enforceCapNow(in: context, defaults: .standard)
    }

    /// The overflow to drop in `trim()`: the clips PAST `maxHistorySize` in the
    /// same newest-first order, selected with the cap as a fetch offset. Symmetric
    /// with `boundedHistoryDescriptor` — what that keeps, this deletes — so the
    /// on-disk history matches the in-view cap. Only the `contentHash` column is
    /// faulted, never the image payloads.
    static func trimOverflowDescriptor(_ defaults: UserDefaults = .standard) -> FetchDescriptor<ClipRecord> {
        var descriptor = FetchDescriptor<ClipRecord>(sortBy: [sortDescriptor])
        descriptor.fetchOffset = maxHistorySize(defaults)
        descriptor.propertiesToFetch = [\.contentHash]
        return descriptor
    }
}
