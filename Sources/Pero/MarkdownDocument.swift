import AppKit
import PeroKit

/// A Markdown file opened from Finder (outside the library). The editor page sends
/// every edit here as it happens, so the document always holds the current text and
/// saves without asking the page.
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument, EditorSource {
    let buffer = NoteBuffer()
    var text: String { buffer.text }
    private let key = UUID().uuidString

    weak var editor: EditorViewController?

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    // MARK: EditorSource

    var baseDirectory: URL? { fileURL?.deletingLastPathComponent() }
    var editorKey: String { key }
    var exportTitle: String {
        FileTypes.markdownExtensions.contains((displayName as NSString).pathExtension.lowercased())
            ? (displayName as NSString).deletingPathExtension : displayName
    }
    func editorDidEdit() { updateChangeCount(.changeDone) }

    private var watcher: DispatchSourceFileSystemObject?

    override var fileURL: URL? {
        didSet {
            // Saving re-sets the same URL; only a real move or rename matters. The tree
            // is refreshed after the save finishes so it never lists temporary files.
            guard fileURL != oldValue else { return }
            watchFile()
            DispatchQueue.main.async {
                (self.windowControllers.first as? EditorWindowController)?.documentURLChanged()
            }
        }
    }

    var isBlank: Bool { fileURL == nil && !isDocumentEdited }

    override func close() {
        watcher?.cancel()
        super.close()
    }

    // MARK: Changes made by other programs

    /// Another program changed the file (say, a transcript being written live):
    /// if there are no unsaved edits here, show the new text in place.
    private func watchFile() {
        watcher?.cancel()
        watcher = nil
        guard let path = fileURL?.path else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.fileChangedOnDisk() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private func fileChangedOnDisk() {
        // A safe save (ours or another program's) replaces the file: follow the new one.
        if let events = watcher?.data, !events.isDisjoint(with: [.delete, .rename]) { watchFile() }
        guard !isDocumentEdited, let url = fileURL, let type = fileType,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              date != fileModificationDate else { return }
        try? revert(toContentsOf: url, ofType: type)
    }

    func replaceText(_ text: String) {
        buffer.setText(text)
    }

    // MARK: Reading and writing

    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try TextCodec.decode(data)
        buffer.setText(decoded.text)
        buffer.format = decoded.format
        editor?.sourceDidReload()
    }

    override func data(ofType typeName: String) throws -> Data {
        try buffer.data()
    }
}
