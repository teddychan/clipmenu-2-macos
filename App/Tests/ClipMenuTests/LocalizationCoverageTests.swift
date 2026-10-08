import Testing
import Foundation
@testable import ClipMenu

// Pins the translated string tables against the sources. DragonKit's L() falls
// back to the key itself, so a literal L("…") key that no table defines shows
// English in that language with no other symptom — 18 keys once did, in every
// translation. A key resolves from the app's Localizable.strings or from
// DragonKit's own table. A translation must also keep its key's printf
// specifiers, or String(format:) misreads its arguments.

@Suite struct LocalizationCoverageTests {

    static let languages = ["es", "fr", "ja", "ko", "ru", "zh-Hans", "zh-Hant"]

    /// Every literal key passed to L() in the app's sources (interpolated ones skipped).
    static let sourceKeys: Set<String> = {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../Sources/ClipMenu").standardized
        let call = try! Regex(#"\bL\("((?:[^"\\]|\\.)*)"\)"#)
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try! String(contentsOf: url, encoding: .utf8)
            for match in text.matches(of: call) {
                guard let raw = match.output[1].substring.map(String.init), !raw.contains("\\(") else { continue }
                keys.insert(raw.replacingOccurrences(of: "\\\"", with: "\""))
            }
        }
        return keys
    }()

    static func table(_ bundle: Bundle, _ name: String, _ language: String) -> [String: String] {
        guard let path = bundle.path(forResource: name, ofType: "strings", inDirectory: nil, forLocalization: language)
        else { return [:] }
        return NSDictionary(contentsOfFile: path) as? [String: String] ?? [:]
    }

    /// The printf conversions in `s`, positional indices dropped, sorted.
    static func specifiers(_ s: String) -> [String] {
        let spec = try! Regex(#"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])"#)
        return s.matches(of: spec)
            .compactMap { $0.output[1].substring.map(String.init) }
            .filter { $0 != "%" }
            .sorted()
    }

    @Test func sourcesUseLocalizationKeys() {
        #expect(Self.sourceKeys.count > 100)
    }

    @Test(arguments: languages)
    func everySourceKeyIsTranslated(_ language: String) throws {
        let kitURL = AppResources.bundle.bundleURL.deletingLastPathComponent()
            .appending(path: "DragonKit_DragonKit.bundle")
        let kit = try #require(Bundle(url: kitURL))
        let app = Self.table(AppResources.bundle, "Localizable", language)
        let kitTable = Self.table(kit, "DragonKit", language)
        try #require(!app.isEmpty && !kitTable.isEmpty)
        let missing = Self.sourceKeys.filter { app[$0] == nil && kitTable[$0] == nil }
        #expect(missing.isEmpty, "\(language) has no translation for \(missing.sorted())")
    }

    @Test(arguments: ["en"] + languages)
    func translationsKeepTheirKeysFormatSpecifiers(_ language: String) throws {
        let app = Self.table(AppResources.bundle, "Localizable", language)
        try #require(!app.isEmpty)
        let mismatched = app.filter { Self.specifiers($0.key) != Self.specifiers($0.value) }.keys
        #expect(mismatched.isEmpty, "\(language) changes the format specifiers of \(mismatched.sorted())")
    }
}
