import Testing
import SwiftUI
import SwiftData
import ViewInspector
import DragonKit
@testable import ClipMenu

// ViewInspector coverage for SnippetEditorView (issue #31): the 3-column snippet
// editor (folders / snippets / detail). SnippetEditorView drives its data through
// @Environment(\.modelContext) + @Query(sort: \Folder.index), so the view is
// hosted with an in-memory ModelContainer via ViewHosting so those dynamic
// properties resolve, then inspected.
//
// Deterministic-snapshot note: whether `@Query` rows appear in the initial
// `inspect()` snapshot depends on the OS (they do on macOS 26, not on macOS 27),
// so no test here relies on folder rows; the row's title view is tested directly.
// `@State` mutated in `.onAppear` (selectedFolderID = first folder) is NOT
// reflected in the snapshot either, so selection is always nil when inspected and
// the snippets/detail columns render their empty states. See the coverage notes
// at the bottom of this file for what is not coverable.
//
// Localized strings come from DragonKit's L(...); the tests call L(...) so they
// assert whatever the test bundle actually returns (the base English key here).

// MARK: - Hosted view-body coverage

@MainActor
@Suite(.serialized) struct SnippetEditorViewChromeTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Folder.self, Snippet.self, ClipRecord.self, ClipImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Runs `body` with the @AppStorage folder-sort key ("snippetEditor.folderSort")
    /// pinned to `raw`, restoring the previous value afterwards. SnippetEditorView
    /// reads this key via @AppStorage, so pinning it keeps hosted renders
    /// deterministic regardless of what a prior run or the real app left behind.
    private func withFolderSort(_ raw: Int, _ body: () throws -> Void) rethrows {
        let key = "snippetEditor.folderSort"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(raw, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try body()
    }

    @Test func bodyIsThreeColumnHSplitView() throws {
        try withFolderSort(0) {
            let view = SnippetEditorView().modelContainer(try makeContainer())
            ViewHosting.host(view: view)
            defer { ViewHosting.expel() }
            let split = try view.inspect().find(ViewType.HSplitView.self)
            #expect(split.count == 3)
        }
    }

    @Test func columnHeadersRender() throws {
        try withFolderSort(0) {
            let view = SnippetEditorView().modelContainer(try makeContainer())
            ViewHosting.host(view: view)
            defer { ViewHosting.expel() }
            // Folders column header, snippets column header (no folder selected →
            // the "Snippets" fallback title), and the detail column header.
            #expect(throws: Never.self) { try view.inspect().find(text: L("Folders")) }
            #expect(throws: Never.self) { try view.inspect().find(text: L("Snippets")) }
            #expect(throws: Never.self) { try view.inspect().find(text: L("Snippet")) }
        }
    }

    @Test func emptyStatesRenderWhenNothingSelected() throws {
        try withFolderSort(0) {
            let view = SnippetEditorView().modelContainer(try makeContainer())
            ViewHosting.host(view: view)
            defer { ViewHosting.expel() }
            // ContentUnavailableView for both the snippets and detail columns.
            #expect(throws: Never.self) { try view.inspect().find(text: L("No Folder Selected")) }
            #expect(throws: Never.self) { try view.inspect().find(text: L("No Snippet Selected")) }
        }
    }

    @Test func footersExposeTheirButtons() throws {
        try withFolderSort(0) {
            let view = SnippetEditorView().modelContainer(try makeContainer())
            ViewHosting.host(view: view)
            defer { ViewHosting.expel() }
            // Folders footer, snippets footer, detail footer.
            #expect(throws: Never.self) { try view.inspect().find(button: L("New Folder")) }
            #expect(throws: Never.self) { try view.inspect().find(button: L("New Snippet")) }
            #expect(throws: Never.self) { try view.inspect().find(button: L("Import…")) }
            #expect(throws: Never.self) { try view.inspect().find(button: L("Export…")) }
            // "Delete" appears in both the folders and snippets footers.
            let deletes = try view.inspect().findAll(ViewType.Button.self).filter {
                (try? $0.labelView().text().string()) == L("Delete")
            }
            #expect(deletes.count >= 2)
        }
    }

    @Test func folderSortMenuListsEveryOptionLabel() throws {
        try withFolderSort(0) {
            let view = SnippetEditorView().modelContainer(try makeContainer())
            ViewHosting.host(view: view)
            defer { ViewHosting.expel() }
            // The folders column header hosts a sort Menu whose content is one
            // Button per SnippetSort case (sortLabel covers all three cases).
            #expect(throws: Never.self) { try view.inspect().find(ViewType.Menu.self) }
            #expect(throws: Never.self) { try view.inspect().find(text: L("Manual (drag)")) }
            #expect(throws: Never.self) { try view.inspect().find(text: L("Name (A → Z)")) }
            #expect(throws: Never.self) { try view.inspect().find(text: L("Name (Z → A)")) }
        }
    }

    @Test func folderSortPreferenceDrivesTheMenuLabel() throws {
        // folderSortRaw = 2 → .nameDescending: the sort Menu's own label (the
        // current selection) becomes "Name (Z → A)", exercising the folderSort
        // computed getter with a non-default raw value and the `option == current`
        // checkmark branch on a non-first option.
        try withFolderSort(2) {
            let view = SnippetEditorView().modelContainer(try makeContainer())
            ViewHosting.host(view: view)
            defer { ViewHosting.expel() }
            #expect(throws: Never.self) { try view.inspect().find(text: L("Name (Z → A)")) }
        }
    }

    @Test func folderTitleShowsAsTextWhenNotEditing() throws {
        let field = FolderNameField(text: .constant("Alpha"), isEditing: .constant(false))
        #expect(try field.inspect().find(ViewType.Text.self).string() == "Alpha")
        #expect((try? field.inspect().find(ViewType.TextField.self)) == nil)
    }

    @Test func folderTitleBecomesEditableWhenEditing() throws {
        let field = FolderNameField(text: .constant("Alpha"), isEditing: .constant(true))
        #expect(throws: Never.self) { try field.inspect().find(ViewType.TextField.self) }
        #expect((try? field.inspect().find(text: "Alpha")) == nil)
    }
}

// MARK: - Save-failure reporting

// The editor commits every mutation through `SnippetEditorView.save()`, which asks
// `commitFailed` whether the write went through and raises the editor's banner when
// it didn't. Before that, all 12 mutation sites saved with `try? context.save()`, so
// an unwritable store (disk full, revoked permissions, external-storage failure) lost
// user-authored snippets silently — the views kept rendering the in-memory context,
// so the UI looked correct and the work was gone at next launch.
//
// `commitFailed` takes the save as a closure precisely so the failure path is
// testable without an unwritable store (the same seam as
// `BackupManager.applyWithRollback`). The `saveFailed` -> banner wiring itself is not
// coverable: it is `private @State`, and a hosted in-memory context can't be made to
// fail — see the coverage notes at the bottom of this file.
@MainActor
@Suite struct SnippetEditorSaveFailureTests {

    private struct SaveBoom: Error {}

    /// The regression guard for the silent-data-loss defect: a throwing commit must
    /// be REPORTED, not swallowed. Reverting any site to `try? context.save()` drops
    /// the reporting this asserts.
    @Test func commitFailedReportsAThrowingSave() {
        #expect(SnippetEditorView.commitFailed { throw SaveBoom() })
    }

    /// The success path still commits and reports no failure — so the banner can't
    /// latch on a healthy store.
    @Test func commitFailedReportsSuccessForARealContextSave() throws {
        let container = try ModelContainer(
            for: Folder.self, Snippet.self, ClipRecord.self, ClipImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.insert(Folder(title: "folder", index: 0))

        #expect(SnippetEditorView.commitFailed(context.save) == false)
        #expect(try context.fetchCount(FetchDescriptor<Folder>()) == 1)
    }
}

// MARK: - SnippetRef (Transferable payload) round-trip

@MainActor
@Suite struct SnippetRefCodableTests {

    @Test func codableRoundTripPreservesPersistentID() throws {
        let container = try ModelContainer(
            for: Folder.self, Snippet.self, ClipRecord.self, ClipImage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let snippet = Snippet(title: "x", content: "y", index: 0)
        container.mainContext.insert(snippet)
        try container.mainContext.save()

        let ref = SnippetRef(id: snippet.persistentModelID)
        let encoded = try JSONEncoder().encode(ref)
        let decoded = try JSONDecoder().decode(SnippetRef.self, from: encoded)
        #expect(decoded.id == ref.id)
    }
}
