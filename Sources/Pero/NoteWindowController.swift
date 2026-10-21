import AppKit
import PeroKit

/// Open notes, shared by every window that shows them: a note open in the main window
/// and in its own window is one buffer, saved once.
final class SessionStore {
    static let shared = SessionStore()
    /// Posted with the session as object when its note disappeared; windows showing it close.
    static let sessionGone = Notification.Name("PeroSessionGone")
    private var entries: [(session: NoteSession, count: Int)] = []

    private init() {
        NotificationCenter.default.addObserver(forName: Library.didChange, object: nil, queue: nil) { [weak self] note in
            self?.libraryChanged(note)
        }
    }

    /// Every open note follows the disk, whichever windows show it: moves, edits made
    /// elsewhere (reloaded when there is nothing unsaved), and files that are gone.
    private func libraryChanged(_ note: Notification) {
        guard let library = note.object as? Library, let info = note.userInfo else { return }
        let moved = info["moved"] as? [String: String] ?? [:]
        let removed = Set(info["removed"] as? [String] ?? [])
        let changed = Set(info["changed"] as? [String] ?? [])
        for session in entries.map(\.session) where session.library === library && !session.isTrash && !session.isGone {
            session.applyMoves(moved)
            if removed.contains(session.path), library.record(session.path) == nil {
                session.abandon()
                NotificationCenter.default.post(name: Self.sessionGone, object: session)
            } else if changed.contains(session.path), !session.isLocked, session.reloadFromDisk() {
                NotificationCenter.default.post(name: EditorViewController.sourceEdited, object: session)
            }
        }
    }

    func acquire(library: Library, path: String, kind: NoteSession.Kind = .note) throws -> NoteSession {
        if case .trash = kind {} else if let i = entries.firstIndex(where: { $0.session.library === library && $0.session.path == path && !$0.session.isTrash }) {
            entries[i].count += 1
            return entries[i].session
        }
        let session = try NoteSession(library: library, path: path, kind: kind)
        entries.append((session, 1))
        return session
    }

    /// The last window let go of the note: it is finished (saved, renamed, dropped if empty).
    func release(_ session: NoteSession) {
        guard let i = entries.firstIndex(where: { $0.session === session }) else { return session.finish() }
        entries[i].count -= 1
        if entries[i].count <= 0 {
            entries.remove(at: i)
            session.finish()
        } else {
            session.saveNow()
        }
    }

    func saveAll() { entries.forEach { $0.session.saveNow() } }

    /// Locked notes close when the lock comes back.
    func sessions(where predicate: (NoteSession) -> Bool) -> [NoteSession] { entries.map(\.session).filter(predicate) }
}

/// A note in a window of its own (double-click in the list).
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static var open: [NoteWindowController] = []

    let library: Library
    let lock: LockManager
    let editor = EditorViewController(source: nil)
    private(set) var session: NoteSession

    static func open(path: String, library: Library, lock: LockManager) {
        if let existing = open.first(where: { $0.session.path == path }) {
            existing.showWindow(nil)
            return
        }
        guard let record = library.record(path) else { return }
        let kind: NoteSession.Kind = record.isLocked ? lock.master.map { .locked($0) } ?? .note : .note
        guard !record.isLocked || lock.isUnlocked,
              let session = try? SessionStore.shared.acquire(library: library, path: path, kind: kind) else { return NSSound.beep() }
        let controller = NoteWindowController(session: session, library: library, lock: lock)
        open.append(controller)
        controller.showWindow(nil)
    }

    init(session: NoteSession, library: Library, lock: LockManager) {
        self.session = session
        self.library = library
        self.lock = lock
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = session.exportTitle
        window.minSize = NSSize(width: 360, height: 300)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 620, height: 700))
        window.cascadeTopLeft(from: NSApp.mainWindow?.frame.origin ?? .zero)
        editor.fileAccessRoot = library.root
        editor.onReady = { [weak self] in
            self?.editor.configure(["notes": true, "zoom": Settings.zoom, "autoSortChecked": Settings.autoSortChecked])
        }
        editor.onAttachFile = { [weak self] data, name in self?.attach(data, name) }
        editor.show(session, focus: true)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: Library.didChange, object: library)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionGone), name: SessionStore.sessionGone, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(lockChanged), name: LockManager.didChange, object: lock)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func libraryChanged() {
        window?.title = session.exportTitle
        editor.setHeader(session.header)
    }

    @objc private func sessionGone() { window?.close() }

    @objc private func lockChanged() {
        if session.isLocked && !lock.isUnlocked { window?.close() }
    }

    func windowWillClose(_ notification: Notification) {
        SessionStore.shared.release(session)
        Self.open.removeAll { $0 === self }
    }

    func windowDidResignKey(_ notification: Notification) { session.saveNow() }

    private func attach(_ data: Data, _ name: String) -> String? {
        guard let path = try? library.addAttachment(data: data, name: name) else { return nil }
        let target = library.linkTarget(to: path, fromFolder: (session.path as NSString).deletingLastPathComponent)
        return FileTypes.isImage(path)
            ? "![](\(target))" : "[\(name)](\(target))"
    }

    // The editing menus work here as in the main window.
    @objc func format(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String { lock.touch(); editor.run(command) }
    }

    @objc func peroUndo(_ sender: Any?) { editor.run("undo") }
    @objc func peroRedo(_ sender: Any?) { editor.run("redo") }
    @objc func peroSelectAll(_ sender: Any?) { editor.run("selectAll") }
    @objc func peroFind(_ sender: Any?) { editor.run("find") }
    @objc func toggleSourceMode(_ sender: Any?) { editor.setSourceMode(!editor.isSourceMode) }

    @objc func printNote(_ sender: Any?) {
        session.saveNow()
        Exporter.print(session.buffer.text, title: session.exportTitle, baseDir: session.baseDirectory, editor: editor, window: window)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSourceMode(_:)) { item.state = editor.isSourceMode ? .on : .off }
        return true
    }
}
