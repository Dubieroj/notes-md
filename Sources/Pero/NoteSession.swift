import CryptoKit
import Foundation
import PeroKit

/// A note open in the editor. Saves on its own half a second after typing stops, renames
/// its file after the title once typing pauses, and cleans up when the user leaves it.
final class NoteSession: EditorSource {
    enum Kind {
        case note
        case locked(SymmetricKey)
        case trash(TrashItem)
    }

    let library: Library
    private(set) var path: String
    let kind: Kind
    let buffer: NoteBuffer
    let editorKey = UUID().uuidString
    private(set) var titleAtOpen: String
    private(set) var isDirty = false
    /// Edited at least once in this session: only then is the file renamed after its title.
    private(set) var wasEdited = false
    /// A note just made with ⌘N or a Quick Note: dropped if left empty, as in Notes.
    var discardIfEmpty = false
    /// The file is gone (deleted, trashed, locked): nothing is written to its path again.
    private(set) var isGone = false
    private var saveWork: DispatchWorkItem?
    private var renameWork: DispatchWorkItem?

    /// The file was renamed after its title: old path → new path.
    var onRename: (String, String) -> Void = { _, _ in }
    var onSaveError: (Error) -> Void = { _ in }

    init(library: Library, path: String, kind: Kind = .note) throws {
        self.library = library
        self.path = path
        self.kind = kind
        switch kind {
        case .note:
            buffer = try library.loadBuffer(path)
        case .locked(let master):
            buffer = NoteBuffer(text: try library.readLocked(path, master: master))
        case .trash(let item):
            let url = library.trashURL(item)
            if url.pathExtension.lowercased() == Library.lockedExtension {
                buffer = NoteBuffer(text: "")
            } else {
                buffer = try NoteBuffer(data: Data(contentsOf: url))
            }
        }
        titleAtOpen = NoteParser.parse(buffer.text).title
    }

    var record: NoteRecord? {
        if case .trash(let item) = kind { return library.trashRecords[item.id] }
        return library.record(path)
    }

    var isLocked: Bool { if case .locked = kind { return true } else { return false } }
    var isTrash: Bool { if case .trash = kind { return true } else { return false } }

    // MARK: EditorSource

    var baseDirectory: URL? { library.url((path as NSString).deletingLastPathComponent) }
    var exportTitle: String { record?.displayTitle ?? FileNames.untitled }
    var isReadOnly: Bool { isTrash }

    var header: String? {
        if case .trash(let item) = kind {
            let days = item.daysLeft()
            return String(localized: "Недавно удалённая заметка. Её нельзя изменить, пока она здесь. Удалится через \(days) \(Plural.days(days)).")
        }
        guard let record else { return nil }
        return Self.dateFormatter.string(from: record.modified)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = UILanguage.locale
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    func editorDidEdit() {
        guard !isTrash, !isGone else { return }
        isDirty = true
        wasEdited = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        renameWork?.cancel()
        let rename = DispatchWorkItem { [weak self] in self?.renameToTitle() }
        renameWork = rename
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: rename)
    }

    /// Writes pending edits now (switching notes, quitting, sleep).
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard isDirty, !isGone else { return }
        do {
            switch kind {
            case .note:
                // Never write plain text over an encrypted note.
                guard (path as NSString).pathExtension.lowercased() != Library.lockedExtension else { return }
                try library.save(path, buffer: buffer)
            case .locked(let master): try library.saveLocked(path, text: buffer.text, master: master)
            case .trash: return
            }
            isDirty = false
        } catch {
            NSLog("Pero: cannot save \(path): \(error)")
            onSaveError(error)
        }
    }

    private func renameToTitle() {
        guard case .note = kind, !isGone else { return }
        saveNow()
        let old = path
        guard let new = try? library.renameToMatchTitle(path), new != old else { return }
        path = new
        onRename(old, new)
    }

    /// The user leaves the note: save, rename after the title, fix links to the old title,
    /// and drop the note if it was left empty (as Notes does).
    func finish() {
        renameWork?.cancel()
        guard !isTrash, !isGone else { return }
        saveNow()
        guard case .note = kind else { return }
        if (wasEdited || discardIfEmpty) && Library.isEmptyNote(buffer.text) {
            library.discardEmpty(path, keepInTrash: !discardIfEmpty)
            return
        }
        guard wasEdited else { return }
        renameToTitle()
        let title = NoteParser.parse(buffer.text).title
        if !titleAtOpen.isEmpty, !title.isEmpty, title != titleAtOpen {
            library.renameWikiLinks(from: titleAtOpen, to: title, except: path)
            titleAtOpen = title
        }
    }

    /// The note's file disappeared: whatever is still in the editor is not written back.
    func abandon() {
        isGone = true
        isDirty = false
        saveWork?.cancel()
        renameWork?.cancel()
    }

    /// Paths changed under the session (moves by Перо or renames of folders).
    func applyMoves(_ moves: [String: String]) {
        if let new = moves[path] { path = new }
    }

    /// The file changed on disk. Without unsaved edits the new text replaces the old one.
    func reloadFromDisk() -> Bool {
        guard case .note = kind, !isDirty, let fresh = try? library.loadBuffer(path), fresh.text != buffer.text else { return false }
        buffer.setText(fresh.text)
        buffer.format = fresh.format
        return true
    }
}

enum Plural {
    static func form(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }

    static func days(_ n: Int) -> String { UILanguage.isRussian ? form(n, "день", "дня", "дней") : n == 1 ? "day" : "days" }
    static func notes(_ n: Int) -> String { UILanguage.isRussian ? form(n, "заметка", "заметки", "заметок") : n == 1 ? "note" : "notes" }
    static func notesGenitive(_ n: Int) -> String { UILanguage.isRussian ? form(n, "заметку", "заметки", "заметок") : n == 1 ? "note" : "notes" }
}
