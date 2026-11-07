import AppKit
import Testing
@testable import ClipMenu

// Some apps copy text only as RTF, or a link only as a URL, with no plain-text
// flavor. The clip's stringValue is then nil, and the history menu used to show
// just "N." for it. clipText falls back to the RTF's text and the URL.

@Suite @MainActor
struct ClipTextTests {
    private func rtf(_ text: String) -> Data {
        let s = NSAttributedString(string: text)
        return s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:])!
    }

    @Test func plainTextWins() {
        let clip = ClipRecord(typeIdentifiers: ["String", "RTF"], stringValue: "plain", rtfData: rtf("styled"))
        #expect(MainMenuController.clipText(clip) == "plain")
    }

    @Test func rtfOnlyClipShowsItsText() {
        let clip = ClipRecord(typeIdentifiers: ["RTF"], rtfData: rtf("Styled text"))
        #expect(MainMenuController.clipText(clip) == "Styled text")
    }

    @Test func rtfdOnlyClipShowsItsText() {
        let s = NSAttributedString(string: "Rich text")
        let data = s.rtfd(from: NSRange(location: 0, length: s.length), documentAttributes: [:])!
        let clip = ClipRecord(typeIdentifiers: ["RTFD"], rtfData: data)
        #expect(MainMenuController.clipText(clip) == "Rich text")
    }

    @Test func urlOnlyClipShowsTheAddress() {
        let clip = ClipRecord(typeIdentifiers: ["URL"], urlString: "https://example.com/a")
        #expect(MainMenuController.clipText(clip) == "https://example.com/a")
    }

    @Test func fileURLOnlyClipShowsThePath() {
        let clip = ClipRecord(typeIdentifiers: ["URL"], urlString: "file:///tmp/My%20Notes.txt")
        #expect(MainMenuController.clipText(clip) == "/tmp/My Notes.txt")
    }

    @Test func clipWithNoTextHasNone() {
        #expect(MainMenuController.clipText(ClipRecord(typeIdentifiers: ["TIFF"])) == nil)
    }
}
