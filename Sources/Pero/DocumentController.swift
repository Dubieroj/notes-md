import AppKit

final class DocumentController: NSDocumentController {
    /// Sidebar folder for the next window, set when a file is opened from a sidebar.
    var pendingRoot: URL?

    override init() {
        super.init()
        autosavingDelay = 3  // edits reach the file a few seconds after typing stops
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func takePendingRoot() -> URL? {
        defer { pendingRoot = nil }
        return pendingRoot
    }

    /// Any Markdown file opens, whichever app declared its extension.
    override func typeForContents(of url: URL) throws -> String {
        FileTypes.isMarkdown(url) ? FileTypes.markdownType : try super.typeForContents(of: url)
    }

    /// The empty untitled window shown at launch is replaced by the first file opened.
    override func openDocument(withContentsOf url: URL, display: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        let blank = documents.count == 1 ? documents.first as? MarkdownDocument : nil
        super.openDocument(withContentsOf: url, display: display) { document, alreadyOpen, error in
            if let blank, blank.isBlank, let document, document !== blank, !alreadyOpen {
                blank.close()
            }
            completionHandler(document, alreadyOpen, error)
        }
    }
}
