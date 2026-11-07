import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import DragonKit

// Snippet editor (issue #31). Three columns hosted in a plain NSWindow, each
// filling the window top-to-bottom (header pinned top, list expands, footer
// pinned bottom):
//   1. Folders — folder-sort menu in the header; New Folder / Delete footer.
//   2. Snippets of the selected folder — that folder's snippet-sort menu in the
//      header; New Snippet / Delete footer.
//   3. Editor — explicit Label and Content fields for the selected snippet;
//      Import… / Export… footer.
//
// Sorting is a VIEW TRANSFORM: `index` always stores the manual drag order, so a
// name sort never rewrites it and switching back to Manual restores it. The
// folder-list sort is a global preference (@AppStorage); each folder persists
// its own snippet-sort mode (`snippetSort`).

/// A draggable reference to a snippet, used to move snippets between folders
/// (drop a snippet onto a folder row in column 1).
struct SnippetRef: Codable, Transferable {
    let id: PersistentIdentifier
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct SnippetEditorView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Folder.index) private var folders: [Folder]

    /// Global folder-list sort, remembered across launches (raw `SnippetSort`).
    @AppStorage("snippetEditor.folderSort") private var folderSortRaw: Int = 0
    private var folderSort: SnippetSort { SnippetSort(rawValue: folderSortRaw) ?? .manual }

    @State private var selectedFolderID: PersistentIdentifier?
    @State private var selectedSnippetID: PersistentIdentifier?
    @State private var editingFolderID: PersistentIdentifier?
    /// Set while the last attempted store write failed; drives the banner at the
    /// bottom of the editor. Written only by `save()`.
    @State private var saveFailed = false

    private var orderedFolders: [Folder] {
        folderSort.ordered(folders, title: { $0.title }, index: { $0.index })
    }
    private var selectedFolder: Folder? {
        folders.first { $0.persistentModelID == selectedFolderID }
    }
    private func orderedSnippets(_ folder: Folder) -> [Snippet] {
        folder.snippetSort.ordered(folder.snippets ?? [], title: { $0.title }, index: { $0.index })
    }
    private var selectedSnippet: Snippet? {
        (selectedFolder?.snippets ?? []).first { $0.persistentModelID == selectedSnippetID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                foldersColumn.frame(minWidth: 170, idealWidth: 210, maxWidth: 300, maxHeight: .infinity)
                snippetsColumn.frame(minWidth: 200, idealWidth: 240, maxWidth: 360, maxHeight: .infinity)
                detailColumn.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
            // An unwritable store is the one failure the three columns cannot show
            // by themselves: they render the in-memory ModelContext, so the edit
            // still *looks* applied. One strip spanning the whole editor reports it
            // and it
            // stays up until a save succeeds. See `save()` for why not an alert.
            if saveFailed {
                Divider()
                Label(L("Couldn't save your snippets. Your last change isn't saved yet."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear {
            if selectedFolderID == nil { selectedFolderID = orderedFolders.first?.persistentModelID }
        }
        .onChange(of: selectedFolderID) { _, _ in selectedSnippetID = nil }
    }

    // MARK: Column 1 — Folders

    private var foldersColumn: some View {
        VStack(spacing: 0) {
            columnHeader(L("Folders")) {
                sortMenu(current: folderSort, help: L("Sort folders by")) { folderSortRaw = $0.rawValue }
            }
            Divider()
            List(selection: $selectedFolderID) {
                ForEach(orderedFolders) { folder in
                    folderRow(folder)
                        .tag(folder.persistentModelID)
                        .dropDestination(for: SnippetRef.self) { refs, _ in
                            _ = moveSnippets(refs, to: folder)
                        }
                }
                .onMove { offsets, dest in moveFolders(from: offsets, to: dest) }
            }
            Divider()
            footer {
                Button(L("New Folder"), action: addFolder)
                Button(L("Delete"), action: deleteFolder).disabled(selectedFolder == nil)
            }
        }
    }

    private func folderRow(_ folder: Folder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            FolderNameField(
                text: folderTitle(folder),
                isEditing: Binding(
                    get: { editingFolderID == folder.persistentModelID },
                    set: { editingFolderID = $0 ? folder.persistentModelID : nil }))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Single-click selection stays 100% NATIVE (List(selection:)) — instant,
        // exactly like the snippets column. Crucially there is NO SwiftUI tap
        // gesture here: a SwiftUI `onTapGesture(count: 2)` must hold the first
        // click for the double-click interval before selection can happen, which
        // is what caused the lag. Double-click-to-rename is detected in AppKit
        // (NSClickGestureRecognizer, delaysPrimaryMouseButtonEvents = false),
        // which never delays single clicks. Suppressed while editing so it
        // doesn't intercept clicks meant for the text field.
        .background {
            if editingFolderID != folder.persistentModelID {
                DoubleClickCatcher {
                    selectedFolderID = folder.persistentModelID
                    editingFolderID = folder.persistentModelID
                }
            }
        }
        .contextMenu {
            Button(L("Rename")) {
                selectedFolderID = folder.persistentModelID
                editingFolderID = folder.persistentModelID
            }
            Button(L("Delete"), role: .destructive) {
                selectedFolderID = folder.persistentModelID
                deleteFolder()
            }
        }
    }

    // MARK: Column 2 — Snippets of the selected folder

    private var snippetsColumn: some View {
        VStack(spacing: 0) {
            columnHeader(selectedFolder?.title ?? L("Snippets")) {
                if let folder = selectedFolder {
                    sortMenu(current: folder.snippetSort,
                             help: String(format: L("Sort snippets in \"%@\""), folder.title)) {
                        folder.snippetSort = $0
                        save()
                    }
                }
            }
            Divider()
            if let folder = selectedFolder {
                List(selection: $selectedSnippetID) {
                    ForEach(orderedSnippets(folder)) { snippet in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.plaintext").foregroundStyle(.secondary)
                            Text(snippet.title)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .tag(snippet.persistentModelID)
                        .draggable(SnippetRef(id: snippet.persistentModelID))
                    }
                    .onMove { offsets, dest in moveSnippets(in: folder, from: offsets, to: dest) }
                }
            } else {
                emptyColumn(L("No Folder Selected"), systemImage: "folder")
            }
            Divider()
            footer {
                Button(L("New Snippet"), action: addSnippet).disabled(selectedFolder == nil)
                Button(L("Delete"), action: deleteSnippet).disabled(selectedSnippet == nil)
            }
        }
    }

    // MARK: Column 3 — Editor

    private var detailColumn: some View {
        VStack(spacing: 0) {
            columnHeader(L("Snippet")) { EmptyView() }
            Divider()
            if let snippet = selectedSnippet {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Label")).font(.caption).foregroundStyle(.secondary)
                    TextField("", text: snippetTitle(snippet))
                        .textFieldStyle(.roundedBorder)
                    Text(L("Content")).font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 6)
                    TextEditor(text: snippetContent(snippet))
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                emptyColumn(L("No Snippet Selected"), systemImage: "doc.plaintext")
            }
            Divider()
            footer(alignTrailing: true) {
                Button(L("Import…"), action: importSnippets)
                Button(L("Export…"), action: exportSnippets)
            }
        }
    }

    // MARK: Shared column chrome

    private func columnHeader<Trailing: View>(_ title: String,
                                              @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(height: 30)
    }

    private func emptyColumn(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.0))
    }

    private func footer<Content: View>(alignTrailing: Bool = false,
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            if alignTrailing { Spacer(minLength: 0) }
            content()
            if !alignTrailing { Spacer(minLength: 0) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
    }

    // MARK: Sort menu

    private func sortLabel(_ s: SnippetSort) -> String {
        switch s {
        case .manual: return L("Manual (drag)")
        case .nameAscending: return L("Name (A → Z)")
        case .nameDescending: return L("Name (Z → A)")
        }
    }

    private func sortMenu(current: SnippetSort, help: String,
                          set: @escaping (SnippetSort) -> Void) -> some View {
        Menu {
            ForEach(SnippetSort.allCases, id: \.self) { option in
                Button { set(option) } label: {
                    if option == current { Label(sortLabel(option), systemImage: "checkmark") }
                    else { Text(sortLabel(option)) }
                }
            }
        } label: {
            Label(sortLabel(current), systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon).font(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize().help(help)
    }

    // MARK: Persistence

    /// Commit the editor's pending changes, surfacing a failed write instead of
    /// dropping it. Every mutation below goes through here rather than saving with
    /// `try?`: snippets are user-authored content with no retry — unlike clipboard
    /// capture, where a best-effort save is fine because the next copy writes again
    /// — so a store that cannot be written (disk full, revoked permissions,
    /// external-storage failure) would otherwise lose authored snippets silently,
    /// the views still reading the in-memory context.
    ///
    /// Failure raises the ONE banner in `body`, deliberately not an alert: a
    /// drag-reorder or a burst of typing in the content field commits many times
    /// in a row, and a modal per failure would stack dozens of dialogs over the
    /// editor. The banner clears on the next successful save — which is also when
    /// the changes SwiftData had kept pending finally reach the store.
    private func save() {
        let failed = Self.commitFailed(context.save)
        // Assigning @State unconditionally would invalidate the editor on every
        // keystroke in the content field; only a change of status needs a redraw.
        if failed != saveFailed { saveFailed = failed }
    }

    /// Whether committing `save` failed. Static + injectable `save` so the failure
    /// path is testable without an unwritable store — the same seam
    /// `BackupManager.applyWithRollback` uses.
    static func commitFailed(_ save: () throws -> Void) -> Bool {
        do { try save(); return false }
        catch { return true }
    }

    // MARK: Folder CRUD

    private func addFolder() {
        let folder = Folder(title: L("untitled folder"),
                            index: ManualReorder.nextIndex(in: folders, index: \.index))
        context.insert(folder)
        save()
        selectedFolderID = folder.persistentModelID
        editingFolderID = folder.persistentModelID   // rename immediately
    }

    private func deleteFolder() {
        guard let folder = selectedFolder else { return }
        context.delete(folder)
        let survivors = ManualReorder.afterRemoving(
            folder.persistentModelID, from: folders, id: \.persistentModelID, index: \.index)
        for (i, f) in survivors.enumerated() { f.index = i }
        save()
        selectedFolderID = orderedFolders.first?.persistentModelID
    }

    // MARK: Snippet CRUD

    private func addSnippet() {
        guard let folder = selectedFolder else { return }
        let snippet = Snippet(title: L("untitled snippet"),
                              index: ManualReorder.nextIndex(in: folder.snippets ?? [], index: \.index),
                              folder: folder)
        context.insert(snippet)
        save()
        selectedSnippetID = snippet.persistentModelID
    }

    private func deleteSnippet() {
        guard let snippet = selectedSnippet, let folder = snippet.folder else { return }
        let remaining = ManualReorder.afterRemoving(
            snippet.persistentModelID, from: folder.snippets ?? [], id: \.persistentModelID, index: \.index)
        context.delete(snippet)
        for (i, s) in remaining.enumerated() { s.index = i }
        save()
        selectedSnippetID = nil
    }

    // MARK: Bindings (empty-name prevention; content defaults to title)

    private func folderTitle(_ folder: Folder) -> Binding<String> {
        Binding(
            get: { folder.title },
            set: { if !$0.isEmpty { folder.title = $0; save() } })
    }
    private func snippetTitle(_ snippet: Snippet) -> Binding<String> {
        // Resolved outside the closure: DragonKit's L() is @MainActor and the
        // Binding setter is not isolated.
        let untitled = L("untitled snippet")
        return Binding(
            get: { snippet.title },
            set: { newTitle in
                guard !newTitle.isEmpty else { return }
                snippet.title = newTitle
                if snippet.content.isEmpty, newTitle != untitled {
                    snippet.content = newTitle
                }
                save()
            })
    }
    private func snippetContent(_ snippet: Snippet) -> Binding<String> {
        let untitled = L("untitled snippet")
        return Binding(
            get: { snippet.content },
            set: { newContent in
                // Auto-fill the label from the first line of content while the
                // label is still the untitled default or was itself auto-derived,
                // so a label the user typed is never clobbered.
                let labelIsAuto = snippet.title.isEmpty
                    || snippet.title == untitled
                    || snippet.title == Snippet.derivedTitle(fromContent: snippet.content)
                if labelIsAuto {
                    snippet.title = Snippet.derivedTitle(fromContent: newContent) ?? untitled
                }
                snippet.content = newContent
                save()
            })
    }

    // MARK: Reorder (manual sort only) + cross-folder move

    private func moveFolders(from source: IndexSet, to destination: Int) {
        guard folderSort == .manual else { return }
        let ordered = ManualReorder.moved(folders, from: source, to: destination, index: \.index)
        for (i, folder) in ordered.enumerated() { folder.index = i }
        save()
    }
    private func moveSnippets(in folder: Folder, from source: IndexSet, to destination: Int) {
        guard folder.snippetSort == .manual else { return }
        let ordered = ManualReorder.moved(folder.snippets ?? [], from: source, to: destination, index: \.index)
        for (i, s) in ordered.enumerated() { s.index = i }
        save()
    }
    private func moveSnippets(_ refs: [SnippetRef], to folder: Folder) -> Bool {
        var nextIndex = ManualReorder.nextIndex(in: folder.snippets ?? [], index: \.index)
        var moved = false
        for ref in refs {
            guard let snippet = context.model(for: ref.id) as? Snippet,
                  snippet.folder?.persistentModelID != folder.persistentModelID
            else { continue }
            snippet.folder = folder
            snippet.index = nextIndex
            nextIndex += 1
            moved = true
        }
        if moved { save() }
        return moved
    }

    // MARK: Import / Export

    /// Write the whole tree, folders and snippets sorted by index, to a .xml file.
    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.canSelectHiddenExtension = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.nameFieldStringValue = "\(SnippetXML.defaultExportName).\(SnippetXML.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let payload = folders.sorted { $0.index < $1.index }.map { folder in
            (title: folder.title,
             snippets: (folder.snippets ?? []).sorted { $0.index < $1.index }
                .map { (title: $0.title, content: $0.content) })
        }
        do {
            try SnippetXML.export(folders: payload).write(to: url, options: .atomic)
        } catch {
            NSSound.beep()
        }
    }

    /// Parse the chosen .xml and append its folders after the existing ones.
    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.xml]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        var folderIndex = folders.map(\.index).max() ?? -1
        for parsedFolder in SnippetXML.parse(data) {
            folderIndex += 1
            let newFolder = Folder(title: parsedFolder.title, index: folderIndex)
            context.insert(newFolder)
            for (i, parsedSnippet) in parsedFolder.snippets.enumerated() {
                context.insert(Snippet(
                    title: parsedSnippet.title, content: parsedSnippet.content,
                    index: i, folder: newFolder))
            }
        }
        save()
    }
}

// MARK: - Inline folder rename

/// A folder-name label that becomes an editable `TextField` when `isEditing` is
/// set (the row enters edit mode on a double-click). Commit on Return /
/// focus-loss; the binding rejects empty names. Single clicks pass through to
/// the enclosing `List` so they select the folder.
struct FolderNameField: View {
    @Binding var text: String
    @Binding var isEditing: Bool
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { DispatchQueue.main.async { focused = true } }
                .onSubmit { isEditing = false }
                .onChange(of: focused) { _, nowFocused in
                    if !nowFocused { isEditing = false }
                }
        } else {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - AppKit double-click (no single-click delay)

/// A transparent layer that fires `action` on a double-click using an AppKit
/// `NSClickGestureRecognizer`. Unlike SwiftUI's `onTapGesture(count: 2)`, AppKit
/// does NOT delay single clicks waiting to see if a second click follows
/// (`delaysPrimaryMouseButtonEvents = false`), so the enclosing `List` keeps its
/// instant native single-click selection. Used for double-click-to-rename in the
/// folders column.
private struct DoubleClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let recognizer = NSClickGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.fire))
        recognizer.numberOfClicksRequired = 2
        recognizer.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}
