import Testing
import Foundation
import SwiftData
import AppKit
@testable import ClipMenu

// Characterization coverage for PasteboardReader.snapshot() driven against the real
// NSPasteboard.general, plus the pure helpers ClipType.name(for:) and
// excludedBundleIdentifiers() not already covered elsewhere.
//
// Serialized: it mutates NSPasteboard.general and UserDefaults.standard
// (storeTypes, excludeApps). Each test saves/restores the defaults it touches and
// clears/writes the general pasteboard through the same API the app uses.
extension PasteboardSerialized {

    @Suite(.serialized) struct PasteboardReaderCoverageTests {

        private func makeTIFFData() -> Data {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .tiff, properties: [:])!
        }

        /// Save the two defaults keys snapshot() reads, force a clean baseline
        /// (all types storable, no excluded apps), and return a restore closure.
        private func neutralizeDefaults() -> () -> Void {
            let prevStore = UserDefaults.standard.object(forKey: PreferenceKeys.storeTypes)
            let prevExclude = UserDefaults.standard.object(forKey: PreferenceKeys.excludeApps)
            UserDefaults.standard.removeObject(forKey: PreferenceKeys.storeTypes) // nil → all types default-YES
            UserDefaults.standard.set([], forKey: PreferenceKeys.excludeApps)     // exclude nothing
            return {
                UserDefaults.standard.set(prevStore, forKey: PreferenceKeys.storeTypes)
                UserDefaults.standard.set(prevExclude, forKey: PreferenceKeys.excludeApps)
            }
        }

        // MARK: snapshot() — storable content

        @Test func snapshotCapturesPlainString() {
            let restore = neutralizeDefaults(); defer { restore() }
            let pb = NSPasteboard.general
            pb.declareTypes([.string], owner: nil)
            pb.setString("hello snapshot", forType: .string)

            let snapshot = PasteboardReader.snapshot()
            #expect(snapshot?.typeNames == ["String"])
            #expect(snapshot?.stringValue == "hello snapshot")
            #expect(snapshot?.rtfData == nil)
            #expect(snapshot?.imageData == nil)
            // The hash matches the pure helper over the same fields.
            #expect(snapshot?.contentHash == stableContentHash(
                typeNames: ["String"], stringValue: "hello snapshot", rtfData: nil, pdfData: nil,
                filenames: nil, urlString: nil, imageData: nil))
        }

        // RTFD wins over RTF: with both present, rtfData holds the RTFD bytes even though
        // RTF is also listed (ClipCapture.swift:99-101).
        @Test func snapshotPrefersRTFDoverRTF() throws {
            let restore = neutralizeDefaults(); defer { restore() }
            let rtfdBytes = Data([0xAA, 0xBB, 0xCC, 0xDD])
            let rtfBytes = Data([0x11, 0x22, 0x33, 0x44])
            let pb = NSPasteboard.general
            pb.declareTypes([.rtfd, .rtf], owner: nil)
            pb.setData(rtfdBytes, forType: .rtfd)
            pb.setData(rtfBytes, forType: .rtf)

            let snapshot = try #require(PasteboardReader.snapshot())
            // macOS may synthesize a plain-text type alongside the rich text; the
            // characterization that matters is RTFD ordered ahead of RTF, and the
            // RTFD bytes winning.
            #expect(Array(snapshot.typeNames.prefix(2)) == ["RTFD", "RTF"])
            #expect(snapshot.rtfData == rtfdBytes, "RTFD bytes win over RTF")
        }

        @Test func snapshotCapturesURL() throws {
            let restore = neutralizeDefaults(); defer { restore() }
            let pb = NSPasteboard.general
            let url = URL(string: "https://example.com/path")!
            pb.clearContents()
            pb.writeObjects([url as NSURL])

            let snapshot = try #require(PasteboardReader.snapshot())
            #expect(snapshot.typeNames.contains("URL"))
            #expect(snapshot.urlString == "https://example.com/path")
        }

        @Test func snapshotCapturesFilenames() throws {
            let restore = neutralizeDefaults(); defer { restore() }
            let dir = URL.temporaryDirectory.appending(path: "ClipMenuFiles-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let f1 = dir.appending(path: "one.txt")
            let f2 = dir.appending(path: "two.txt")
            try Data().write(to: f1)
            try Data().write(to: f2)

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([f1 as NSURL, f2 as NSURL])

            let snapshot = try #require(PasteboardReader.snapshot())
            #expect(snapshot.typeNames.contains("Filenames"))
            let filenames = try #require(snapshot.filenames)
            #expect(filenames.count == 2)
            #expect(Set(filenames) == Set([f1.path, f2.path]))
        }

        @Test func snapshotCapturesTIFFImage() {
            let restore = neutralizeDefaults(); defer { restore() }
            let tiff = makeTIFFData()
            let pb = NSPasteboard.general
            pb.declareTypes([.tiff], owner: nil)
            pb.setData(tiff, forType: .tiff)

            let snapshot = PasteboardReader.snapshot()
            #expect(snapshot?.typeNames == ["TIFF"])
            #expect(snapshot?.imageData == tiff)
        }

        // MARK: snapshot() — skip paths (return nil)

        @Test func snapshotSkipsPrivacyMarkedWrites() {
            let restore = neutralizeDefaults(); defer { restore() }
            let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let pb = NSPasteboard.general
            pb.declareTypes([.string, concealed], owner: nil)
            pb.setString("secret", forType: .string)

            #expect(PasteboardReader.snapshot() == nil)
        }

        @Test func snapshotSkipsWhenAllTypesDisabled() {
            let prevStore = UserDefaults.standard.object(forKey: PreferenceKeys.storeTypes)
            let prevExclude = UserDefaults.standard.object(forKey: PreferenceKeys.excludeApps)
            // Every supported type disabled → nothing storable → nil.
            let allOff = ["String", "RTF", "RTFD", "PDF", "Filenames", "URL", "TIFF"]
                .reduce(into: [String: Bool]()) { $0[$1] = false }
            UserDefaults.standard.set(allOff, forKey: PreferenceKeys.storeTypes)
            UserDefaults.standard.set([], forKey: PreferenceKeys.excludeApps)
            defer {
                UserDefaults.standard.set(prevStore, forKey: PreferenceKeys.storeTypes)
                UserDefaults.standard.set(prevExclude, forKey: PreferenceKeys.excludeApps)
            }

            let pb = NSPasteboard.general
            pb.declareTypes([.string], owner: nil)
            pb.setString("nope", forType: .string)

            #expect(PasteboardReader.snapshot() == nil)
        }

        @Test func snapshotReturnsNilWhenNothingStorable() {
            let restore = neutralizeDefaults(); defer { restore() }
            let pb = NSPasteboard.general
            pb.clearContents() // no recognized types remain
            #expect(PasteboardReader.snapshot() == nil)
        }

        // Regression: an app can declare String and URL and then supply no data for
        // either. That copy used to become an empty clip, a blank "N." row, and since
        // every such copy hashes the same, each one moved that row back to the top.
        @Test func snapshotReturnsNilWhenDeclaredTypesHoldNoData() {
            let restore = neutralizeDefaults(); defer { restore() }
            let pb = NSPasteboard.general
            pb.declareTypes([.string, .URL], owner: nil) // declared, never written
            #expect(PasteboardReader.snapshot() == nil)
        }

        // MARK: pure helpers

        @Test func clipTypeNamesCoverAllSupportedTypesAndDropOthers() {
            #expect(ClipType.name(for: .string) == "String")
            #expect(ClipType.name(for: .rtf) == "RTF")
            #expect(ClipType.name(for: .rtfd) == "RTFD")
            #expect(ClipType.name(for: .pdf) == "PDF")
            #expect(ClipType.name(for: .fileURL) == "Filenames")
            #expect(ClipType.name(for: .URL) == "URL")
            #expect(ClipType.name(for: .tiff) == "TIFF")
            // Unsupported types map to nil (PICT and everything else is dropped).
            #expect(ClipType.name(for: .html) == nil)
            #expect(ClipType.name(for: .png) == nil)
        }

        @Test func excludedBundleIdentifiersReadsUserList() {
            let prev = UserDefaults.standard.object(forKey: PreferenceKeys.excludeApps)
            UserDefaults.standard.set(
                [["bundleIdentifier": "com.apple.Safari"], ["bundleIdentifier": "com.foo.Bar"]],
                forKey: PreferenceKeys.excludeApps)
            defer { UserDefaults.standard.set(prev, forKey: PreferenceKeys.excludeApps) }

            #expect(PasteboardReader.excludedBundleIdentifiers() == ["com.apple.Safari", "com.foo.Bar"])
        }

        @Test func excludedBundleIdentifiersFallsBackToLegacyDefault() {
            let prev = UserDefaults.standard.object(forKey: PreferenceKeys.excludeApps)
            UserDefaults.standard.removeObject(forKey: PreferenceKeys.excludeApps)
            defer { UserDefaults.standard.set(prev, forKey: PreferenceKeys.excludeApps) }

            // No configured list → legacy OpenOffice.org default (AppController.m:103-118).
            #expect(PasteboardReader.excludedBundleIdentifiers() == ["org.openoffice.script"])
        }
    }
}
