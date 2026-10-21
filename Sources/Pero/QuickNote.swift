import AppKit
import Carbon.HIToolbox
import PeroKit

/// Быстрая заметка: a small window above everything, on every desktop and over
/// full-screen apps. Fn‑Q belongs to Apple Notes, so Перо has its own shortcut (⌃⌥⌘N).
final class QuickNotePanel: NSObject, NSWindowDelegate {
    static let shared = QuickNotePanel()

    private var panel: NSPanel?
    private var editor: EditorViewController?
    private var session: NoteSession?
    private weak var library: Library?

    func show(library: Library) {
        self.library = library
        let panel = self.panel ?? makePanel(library: library)
        if session == nil { startNote(library) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        editor?.focusText()
    }

    private func makePanel(library: Library) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = String(localized: "Быстрая заметка")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let editor = EditorViewController(source: nil)
        editor.fileAccessRoot = library.root
        editor.onReady = { [weak editor] in editor?.configure(["notes": true, "zoom": Settings.zoom]) }
        editor.onAttachFile = { [weak self] data, name in
            guard let self, let library = self.library, let path = try? library.addAttachment(data: data, name: name) else { return nil }
            let target = library.linkTarget(to: path, fromFolder: Library.quickFolder)
            return FileTypes.isImage(path) ? "![](\(target))" : "[\(name)](\(target))"
        }
        panel.contentViewController = editor
        panel.setContentSize(NSSize(width: 420, height: 360))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 440, y: screen.minY + 20))
        }
        panel.setFrameAutosaveName("PeroQuickNote")
        self.panel = panel
        self.editor = editor
        return panel
    }

    private func startNote(_ library: Library) {
        // «Всегда продолжать последнюю быструю заметку».
        var path: String?
        if Settings.resumeLastQuickNote {
            path = library.notes(in: .quick).filter { !$0.isLocked }.max { $0.modified < $1.modified }?.path
        }
        if path == nil { path = try? library.createNote(in: Library.quickFolder, text: Settings.newNotePrefix) }
        guard let path, let session = try? SessionStore.shared.acquire(library: library, path: path) else { return }
        session.discardIfEmpty = true
        self.session = session
        // Trashed, locked or deleted elsewhere: the panel lets go of it.
        NotificationCenter.default.addObserver(self, selector: #selector(sessionGone), name: SessionStore.sessionGone, object: session)
        editor?.show(session, focus: true)
        let end = (session.buffer.text as NSString).length
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.editor?.reveal(end) }
    }

    @objc private func sessionGone() { panel?.close() }

    func windowWillClose(_ notification: Notification) {
        if let session {
            NotificationCenter.default.removeObserver(self, name: SessionStore.sessionGone, object: session)
            SessionStore.shared.release(session)
        }
        session = nil
        editor?.show(nil)
    }

    func windowDidResignKey(_ notification: Notification) { session?.saveNow() }
}

/// A system-wide shortcut through Carbon: works in every app, needs no accessibility rights.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var current: HotKey?

    init?(keyCode: UInt32 = UInt32(kVK_ANSI_N), modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey), action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.current?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x5045_524F), id: 1)  // "PERO"
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        HotKey.current = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        if HotKey.current === self { HotKey.current = nil }
    }
}
