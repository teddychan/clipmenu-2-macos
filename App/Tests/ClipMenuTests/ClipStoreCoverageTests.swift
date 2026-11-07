import Testing
import Foundation
import SwiftData
import AppKit
@testable import ClipMenu

// Characterization coverage for ClipStore.capture() (thumbnail derivation on a
// new image clip, and the dedup path that bumps lastUsedDate instead of adding a
// row), ClipStore.backfillThumbnails() (idempotent; TIFF-only), and the
// reorder-driven sortDescriptor used by boundedHistoryDescriptor.
//
// Serialized because sortDescriptor reads UserDefaults.standard.reorderClipsAfterPasting;
// the two sort tests save and restore that key. The tests deliberately do NOT
// touch UserDefaults.standard.maxHistorySize — they use tiny fixtures (≤3 rows)
// that never approach any cap — so they can't race the parallel AtCapacityCaptureTests
// suite that mutates that same key. The fetch limit that would otherwise read the
// shared key is pinned via a private UserDefaults suite passed to the descriptor.
@Suite(.serialized) struct ClipStoreCoverageTests {

    /// Minimal decodable TIFF bytes (4×4 RGBA) built without touching a graphics
    /// context, so it's safe off the main actor. ImageIO can thumbnail it.
    private func makeTIFFData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .tiff, properties: [:])!
    }

    private func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Folder.self, Snippet.self, ClipRecord.self, ClipImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// A throwaway UserDefaults suite with a generous history cap, used only to pin
    /// the fetch LIMIT of boundedHistoryDescriptor so the sort tests never depend on
    /// the shared standard maxHistorySize key.
    private func generousDefaults() -> UserDefaults {
        let suite = "ClipStoreCoverage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(50, forKey: PreferenceKeys.maxHistorySize)
        return defaults
    }

    // A brand-new image clip: capture() derives a small thumbnail off the stored
    // TIFF, keeps the original bytes untouched in the ClipImage row, and inserts one
    // new record.
    @Test func captureNewImageClipDerivesThumbnailAndKeepsOriginal() async throws {
        let tiff = makeTIFFData()
        let container = try inMemoryContainer()
        let store = ClipStore(modelContainer: container)
        await store.capture(PasteboardSnapshot(
            typeNames: ["TIFF"], stringValue: nil, rtfData: nil, pdfData: nil,
            filenames: nil, urlString: nil, imageData: tiff, contentHash: 123))

        let ctx = ModelContext(container)
        let records = try ctx.fetch(FetchDescriptor<ClipRecord>())
        #expect(records.count == 1)
        let record = try #require(records.first)
        // Thumbnail derived at capture; original stored byte-for-byte.
        #expect(record.thumbnailData != nil)
        #expect(record.image?.data == tiff)
        #expect(record.typeIdentifiers == ["TIFF"])
    }

    // A text-only clip: no image → no thumbnail derivation, single row inserted.
    @Test func captureNewTextClipHasNoThumbnail() async throws {
        let container = try inMemoryContainer()
        let store = ClipStore(modelContainer: container)
        await store.capture(PasteboardSnapshot(
            typeNames: ["String"], stringValue: "plain text", rtfData: nil, pdfData: nil,
            filenames: nil, urlString: nil, imageData: nil, contentHash: 7))

        let ctx = ModelContext(container)
        let record = try #require(try ctx.fetch(FetchDescriptor<ClipRecord>()).first)
        #expect(record.stringValue == "plain text")
        #expect(record.thumbnailData == nil)
        #expect(record.image == nil)
    }

    // Re-capturing identical content bumps the existing clip's lastUsedDate rather
    // than inserting a second row (ClipsController.m:619-636).
    @Test func captureDedupBumpsLastUsedDateWithoutAddingRow() async throws {
        let container = try inMemoryContainer()
        let seed = ModelContext(container)
        let old = Date(timeIntervalSince1970: 1_000_000)
        seed.insert(ClipRecord(createdDate: old, lastUsedDate: old,
                               typeIdentifiers: ["String"], stringValue: "dup", contentHash: 42))
        try seed.save()

        let store = ClipStore(modelContainer: container)
        await store.capture(PasteboardSnapshot(
            typeNames: ["String"], stringValue: "dup", rtfData: nil, pdfData: nil,
            filenames: nil, urlString: nil, imageData: nil, contentHash: 42))

        let ctx = ModelContext(container)
        let records = try ctx.fetch(FetchDescriptor<ClipRecord>())
        #expect(records.count == 1, "dedup must not add a second row")
        let record = try #require(records.first)
        #expect(record.lastUsedDate > old, "the existing clip's lastUsedDate is bumped")
        #expect(record.createdDate == old, "createdDate is preserved on dedup")
    }

    // removeEmptyClips: deletes clips with no data in any field (saved before
    // snapshot() skipped empty copies) and keeps every clip that holds something.
    @Test func removeEmptyClipsDeletesOnlyClipsWithNoData() async throws {
        let container = try inMemoryContainer()
        let seed = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_000_000)
        func add(_ hash: Int, _ types: [String], string: String? = nil, url: String? = nil,
                 rtf: Data? = nil, files: [String]? = nil, image: Data? = nil) {
            seed.insert(ClipRecord(createdDate: base, lastUsedDate: base, typeIdentifiers: types,
                                   stringValue: string, rtfData: rtf, filenames: files, urlString: url,
                                   image: image.map(ClipImage.init(data:)), contentHash: hash))
        }
        add(1, ["String", "URL"])                       // empty: declared, no data
        add(2, ["TIFF"])                                // empty: no image
        add(3, ["Filenames"], files: [])                // empty: no file names
        add(4, ["String"], string: "text")
        add(5, ["URL"], url: "https://example.com")
        add(6, ["RTF"], rtf: Data("{\\rtf1 a}".utf8))
        add(7, ["Filenames"], files: ["/tmp/a"])
        add(8, ["TIFF"], image: makeTIFFData())
        try seed.save()

        let store = ClipStore(modelContainer: container)
        await store.removeEmptyClips()

        let ctx = ModelContext(container)
        let hashes = try ctx.fetch(FetchDescriptor<ClipRecord>()).map(\.contentHash).sorted()
        #expect(hashes == [4, 5, 6, 7, 8])
    }

    // backfillThumbnails: generates thumbnails for pre-thumbnail TIFF clips, ignores
    // non-image clips, and is idempotent (a second run changes nothing).
    @Test func backfillThumbnailsIsTiffOnlyAndIdempotent() async throws {
        let tiff = makeTIFFData()
        let container = try inMemoryContainer()
        let seed = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_000_000)
        // Legacy image clip with no thumbnail yet.
        seed.insert(ClipRecord(createdDate: base, lastUsedDate: base,
                               typeIdentifiers: ["TIFF"], image: ClipImage(data: tiff),
                               thumbnailData: nil, contentHash: 1))
        // Text clip without a thumbnail must be left untouched (not a TIFF clip).
        seed.insert(ClipRecord(createdDate: base, lastUsedDate: base,
                               typeIdentifiers: ["String"], stringValue: "text",
                               thumbnailData: nil, contentHash: 2))
        try seed.save()

        let store = ClipStore(modelContainer: container)
        await store.backfillThumbnails()

        func thumb(forHash hash: Int) throws -> Data? {
            let ctx = ModelContext(container)
            let descriptor = FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.contentHash == hash })
            return try ctx.fetch(descriptor).first?.thumbnailData
        }

        let tiffThumb = try thumb(forHash: 1)
        #expect(tiffThumb != nil, "the TIFF clip gets a thumbnail")
        #expect(try thumb(forHash: 2) == nil, "the text clip is left without a thumbnail")

        // Idempotent: no image clip lacks a thumbnail now, so a second run is a no-op.
        await store.backfillThumbnails()
        #expect(try thumb(forHash: 1) == tiffThumb, "second run leaves the thumbnail unchanged")
        let ctx = ModelContext(container)
        #expect(try ctx.fetchCount(FetchDescriptor<ClipRecord>()) == 2, "no rows added or removed")
    }

    // sortDescriptor (via boundedHistoryDescriptor) reorders by lastUsedDate when the
    // reorder-after-pasting default is on (its default), so the most recently used
    // clip is newest-first.
    @Test func sortDescriptorReordersByLastUsedWhenReorderOn() throws {
        let prevReorder = UserDefaults.standard.object(forKey: PreferenceKeys.reorderClipsAfterPasting)
        UserDefaults.standard.set(true, forKey: PreferenceKeys.reorderClipsAfterPasting)
        defer { UserDefaults.standard.set(prevReorder, forKey: PreferenceKeys.reorderClipsAfterPasting) }

        let context = ModelContext(try inMemoryContainer())
        let t = (0...2).map { Date(timeIntervalSince1970: 1_000_000 + Double($0)) }
        // A: created t0 / lastUsed t2, B: created t1 / lastUsed t0, C: created t2 / lastUsed t1
        context.insert(ClipRecord(createdDate: t[0], lastUsedDate: t[2], typeIdentifiers: ["String"], stringValue: "A", contentHash: 1))
        context.insert(ClipRecord(createdDate: t[1], lastUsedDate: t[0], typeIdentifiers: ["String"], stringValue: "B", contentHash: 2))
        context.insert(ClipRecord(createdDate: t[2], lastUsedDate: t[1], typeIdentifiers: ["String"], stringValue: "C", contentHash: 3))
        try context.save()

        let clips = try context.fetch(ClipStore.boundedHistoryDescriptor(generousDefaults()))
        // lastUsedDate descending → A(t2), C(t1), B(t0).
        #expect(clips.map(\.contentHash) == [1, 3, 2])
    }

    // With reorder off, the history is fixed to creation order (lastUsedDate is ignored).
    @Test func sortDescriptorUsesCreatedDateWhenReorderOff() throws {
        let prevReorder = UserDefaults.standard.object(forKey: PreferenceKeys.reorderClipsAfterPasting)
        UserDefaults.standard.set(false, forKey: PreferenceKeys.reorderClipsAfterPasting)
        defer { UserDefaults.standard.set(prevReorder, forKey: PreferenceKeys.reorderClipsAfterPasting) }

        let context = ModelContext(try inMemoryContainer())
        let t = (0...2).map { Date(timeIntervalSince1970: 1_000_000 + Double($0)) }
        context.insert(ClipRecord(createdDate: t[0], lastUsedDate: t[2], typeIdentifiers: ["String"], stringValue: "A", contentHash: 1))
        context.insert(ClipRecord(createdDate: t[1], lastUsedDate: t[0], typeIdentifiers: ["String"], stringValue: "B", contentHash: 2))
        context.insert(ClipRecord(createdDate: t[2], lastUsedDate: t[1], typeIdentifiers: ["String"], stringValue: "C", contentHash: 3))
        try context.save()

        let clips = try context.fetch(ClipStore.boundedHistoryDescriptor(generousDefaults()))
        // createdDate descending → C(t2), B(t1), A(t0).
        #expect(clips.map(\.contentHash) == [3, 2, 1])
    }
}
