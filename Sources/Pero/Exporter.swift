import AppKit
import PeroKit
import UniformTypeIdentifiers
import WebKit

enum Exporter {
    static func exportHTML(document: MarkdownDocument, editor: EditorViewController, window: NSWindow) {
        ask(for: .html, base: document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName ?? "",
            directory: document.fileURL?.deletingLastPathComponent(), window: window) { url in
            writeHTML(editor: editor, to: url) { error in
                if let error { document.presentError(error) }
            }
        }
    }

    static func exportPDF(document: MarkdownDocument, editor: EditorViewController, window: NSWindow) {
        ask(for: .pdf, base: document.fileURL?.deletingPathExtension().lastPathComponent ?? document.displayName ?? "",
            directory: document.fileURL?.deletingLastPathComponent(), window: window) { url in
            writePDF(editor: editor, to: url) { error in
                if let error { document.presentError(error) }
            }
        }
    }

    // Image paths stay relative, so the HTML works when saved next to the .md file.
    static func writeHTML(editor: EditorViewController, to url: URL, done: @escaping (Error?) -> Void) {
        editor.exportHTML(fileImages: false) { html in
            guard let html else { return done(CocoaError(.fileWriteUnknown)) }
            done(Result { try html.write(to: url, atomically: true, encoding: .utf8) }.error)
        }
    }

    static func writePDF(editor: EditorViewController, to url: URL, done: @escaping (Error?) -> Void) {
        editor.exportHTML(fileImages: true) { html in
            guard let html else { return done(CocoaError(.fileWriteUnknown)) }
            PDFRenderer(html: html, destination: url, done: done).start()
        }
    }

    static func writePDF(html: String, to url: URL, done: @escaping (Error?) -> Void) {
        PDFRenderer(html: html, destination: url, done: done).start()
    }

    /// Prints any Markdown text through the system print panel.
    static func print(_ text: String, title: String, baseDir: URL?, editor: EditorViewController, window: NSWindow?) {
        editor.renderHTML(text, title: title, baseDir: baseDir, fileImages: true) { html in
            guard let html else { return NSSound.beep() }
            PDFRenderer(html: html, destination: nil, parent: window) { _ in }.start()
        }
    }

    static func ask(for type: UTType, base: String, directory: URL?, window: NSWindow,
                    then save: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = base + "." + (type.preferredFilenameExtension ?? "")
        if let directory { panel.directoryURL = directory }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { save(url) }
        }
    }
}

private extension Result where Success == Void {
    var error: Error? { if case .failure(let e) = self { return e } else { return nil } }
}

/// Lays the exported HTML out in a hidden web view and prints it to a paginated PDF.
private final class PDFRenderer: NSObject, WKNavigationDelegate {
    private static var active = Set<PDFRenderer>()

    private let html: String
    private let destination: URL?
    private weak var parent: NSWindow?
    private let done: (Error?) -> Void
    private let webView: WKWebView
    private let window: NSWindow
    private let tempDir: URL

    init(html: String, destination: URL?, parent: NSWindow? = nil, done: @escaping (Error?) -> Void) {
        self.html = html
        self.destination = destination
        self.parent = parent
        self.done = done
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false  // the document may contain raw HTML
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: config)
        webView.appearance = NSAppearance(named: .aqua)  // paper is white even in dark mode
        // Printing needs the view to live in a window; this one is never shown.
        window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pero-pdf-" + UUID().uuidString)
        super.init()
        webView.navigationDelegate = self
    }

    private static let rules = #"""
        [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
         {"trigger": {"url-filter": "^file:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^data:", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^file:", "resource-type": ["document"], "load-context": ["top-frame"]},
          "action": {"type": "ignore-previous-rules"}}]
        """#

    func start() {
        Self.active.insert(self)
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "pero.export", encodedContentRuleList: Self.rules) { list, error in
            DispatchQueue.main.async {
                guard let list else { return self.finish(error) }
                self.webView.configuration.userContentController.add(list)
                self.load()
            }
        }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let page = tempDir.appendingPathComponent("export.html")
            try html.write(to: page, atomically: true, encoding: .utf8)
            webView.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } catch {
            finish(error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info: NSPrintInfo
        if let destination {
            info = NSPrintInfo(dictionary: [.jobSavingURL: destination])
            info.paperSize = NSSize(width: 595.28, height: 841.89)  // A4
        } else {
            info = NSPrintInfo.shared.copy() as! NSPrintInfo  // the user's printer and paper
        }
        info.topMargin = 50
        info.bottomMargin = 50
        info.leftMargin = 46
        info.rightMargin = 46
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if destination != nil { info.jobDisposition = .save }

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = destination == nil
        operation.showsProgressPanel = destination == nil
        operation.view?.frame = webView.bounds
        operation.runModal(for: parent ?? window, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        finish(success ? nil : CocoaError(.fileWriteUnknown))
    }

    private func finish(_ error: Error?) {
        try? FileManager.default.removeItem(at: tempDir)
        done(error)
        Self.active.remove(self)
    }
}
