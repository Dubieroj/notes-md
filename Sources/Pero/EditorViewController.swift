import AppKit
import PeroKit
import UniformTypeIdentifiers
import WebKit

struct Heading: Equatable {
    let level: Int
    let text: String
    let from: Int
}

/// Text the editor shows and edits: a library note or a Markdown file opened from Finder.
protocol EditorSource: AnyObject {
    var buffer: NoteBuffer { get }
    /// Folder that relative picture paths start from.
    var baseDirectory: URL? { get }
    /// Stable while the source lives; edits from the page carry it.
    var editorKey: String { get }
    var exportTitle: String { get }
    var isReadOnly: Bool { get }
    /// Shown above the text (the note's date, as in Notes).
    var header: String? { get }
    func editorDidEdit()
}

extension EditorSource {
    var isReadOnly: Bool { false }
    var header: String? { nil }
}

/// Hosts the CodeMirror page and talks to it through window.pero. One page per window:
/// switching notes swaps the text without reloading.
final class EditorViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    private(set) weak var source: EditorSource?
    private(set) var isReady = false
    private(set) var isSourceMode = false
    private var pendingFocus = false
    /// Pictures load only from inside this folder (the library); nil allows any.
    var fileAccessRoot: URL? {
        didSet { SchemeHandler.allowedRoots[ObjectIdentifier(webView)] = fileAccessRoot }
    }

    var onOutline: ([Heading]) -> Void = { _ in }
    var onCurrentHeading: (Int) -> Void = { _ in }
    var onOpenWiki: (_ target: String, _ section: String?, _ newWindow: Bool) -> Void = { _, _, _ in }
    var onOpenTag: (String) -> Void = { _ in }
    /// A file dropped or pasted into the text: save it and return the Markdown to insert.
    var onAttachFile: (_ data: Data, _ name: String) -> String? = { _, _ in nil }
    var onReady: () -> Void = {}

    init(source: EditorSource?) {
        self.source = source
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(), forURLScheme: SchemeHandler.scheme)
        // Writing Tools would hand back rich text; Перо takes plain text or nothing.
        config.writingToolsBehavior = Settings.writingTools ? .limited : .none
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
        config.userContentController.add(WeakMessageHandler(self), name: "pero")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")  // no white flash in dark mode
        #if PERO_TEST_HOOKS
        webView.isInspectable = true
        #endif
        blockRemoteLoads(config)
        NotificationCenter.default.addObserver(self, selector: #selector(otherEditorEdited(_:)), name: Self.sourceEdited, object: nil)
    }

    /// The same note edited in another window: show its new text here too.
    static let sourceEdited = Notification.Name("PeroEditorSourceEdited")

    @objc private func otherEditorEdited(_ note: Notification) {
        guard let source, note.object as AnyObject === source, (note.userInfo?["editor"] as AnyObject) !== self else { return }
        sourceDidReload()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pero")
        SchemeHandler.allowedRoots[ObjectIdentifier(webView)] = nil
    }

    /// Notes never reach the network: pictures by web address are not loaded.
    private func blockRemoteLoads(_ config: WKWebViewConfiguration) {
        // Content-blocker patterns have no alternation ("a|b"): one rule per scheme.
        let rules = ["^https?://", "^ftp://", "^wss?://"]
            .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }.joined(separator: ",")
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "pero.offline", encodedContentRuleList: "[\(rules)]") { list, error in
            if let list { config.userContentController.add(list) } else { NSLog("Pero: offline rules: \(String(describing: error))") }
        }
    }

    override func loadView() {
        let root = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        webView.load(URLRequest(url: SchemeHandler.pageURL))
    }

    // MARK: Calls into the page

    func call(_ body: String, _ args: [String: Any] = [:], done: ((Any?) -> Void)? = nil) {
        webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
            switch result {
            case .success(let value): done?(value)
            case .failure(let error):
                NSLog("Pero JS error in \(body): \(error)")
                done?(nil)
            }
        }
    }

    private var baseDir: Any { source?.baseDirectory?.path ?? NSNull() }

    /// Shows another source (or nothing). Its text, undo history and scroll come back
    /// as they were if it was shown before.
    func show(_ source: EditorSource?, focus: Bool = false) {
        self.source = source
        pendingFocus = focus
        load(keepView: false)
    }

    private func load(keepView: Bool) {
        guard isReady else { return }
        let options: [String: Any] = [
            "baseDir": baseDir, "keepView": keepView, "key": source?.editorKey ?? NSNull(),
            "header": source?.header ?? "", "readOnly": source?.isReadOnly ?? true, "focus": pendingFocus,
        ]
        pendingFocus = false
        call("pero.load(text, options)", ["text": source?.buffer.text ?? "", "options": options])
    }

    /// The source re-read its text (revert, or the file changed on disk).
    func sourceDidReload() { load(keepView: true) }

    func documentURLChanged() {
        guard isReady else { return }
        call("pero.setBaseDir(baseDir)", ["baseDir": baseDir])
    }

    func setHeader(_ text: String?) {
        guard isReady else { return }
        call("pero.setHeader(text)", ["text": text ?? ""])
    }

    func configure(_ options: [String: Any]) {
        guard isReady else { return }
        call("pero.configure(options)", ["options": options])
    }

    func fetchText(_ done: @escaping (String?) -> Void) {
        call("return pero.getText()") { done($0 as? String) }
    }

    func run(_ command: String, arg: Any? = nil, done: ((Any?) -> Void)? = nil) {
        view.window?.makeFirstResponder(webView)
        call("return pero.command(name, arg)", ["name": command, "arg": arg ?? NSNull()], done: done)
    }

    func insert(_ text: String) {
        view.window?.makeFirstResponder(webView)
        call("pero.insert(text)", ["text": text])
    }

    func reveal(_ pos: Int) {
        view.window?.makeFirstResponder(webView)
        call("pero.reveal(pos)", ["pos": pos])
    }

    func focusText() {
        view.window?.makeFirstResponder(webView)
        call("pero.focus()")
    }

    func setSourceMode(_ on: Bool) {
        isSourceMode = on
        call("pero.setMode(mode)", ["mode": on ? "source" : "live"])
    }

    func selectedText(_ done: @escaping (String) -> Void) {
        call("return pero.selection().text") { done($0 as? String ?? "") }
    }

    func linkContext(_ done: @escaping (String, String) -> Void) {
        call("return pero.linkContext()") { value in
            let dict = value as? [String: Any]
            done(dict?["text"] as? String ?? "", dict?["url"] as? String ?? "")
        }
    }

    func exportHTML(fileImages: Bool, _ done: @escaping (String?) -> Void) {
        let title = source?.exportTitle ?? ""
        call("return await pero.exportHTML({title, fileImages})", ["title": title, "fileImages": fileImages]) {
            done($0 as? String)
        }
    }

    /// HTML for any Markdown text, with its own folder for pictures.
    func renderHTML(_ text: String, title: String, baseDir: URL?, fileImages: Bool, _ done: @escaping (String?) -> Void) {
        call("return await pero.renderHTML(text, {title, fileImages, baseDir})",
             ["text": text, "title": title, "fileImages": fileImages, "baseDir": baseDir?.path ?? NSNull()]) {
            done($0 as? String)
        }
    }

    func htmlToMarkdown(_ html: String, _ done: @escaping (String, [String]) -> Void) {
        call("return pero.htmlToMarkdown(html)", ["html": html]) { value in
            let dict = value as? [String: Any]
            done(dict?["markdown"] as? String ?? "", dict?["images"] as? [String] ?? [])
        }
    }

    /// Runs a script in the page (used by the test hooks).
    func evaluate(_ body: String, _ done: @escaping (Any?) -> Void) {
        call(body, done: done)
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            configure(["home": NSHomeDirectory()])
            onReady()
            load(keepView: false)
            if isSourceMode { setSourceMode(true) }
        case "edit":
            guard let source, !source.isReadOnly, (body["key"] as? String) == source.editorKey else { return }
            let changes = body["changes"] as? [[Any]] ?? []
            if !source.buffer.applyEdits(changes, expectedLength: body["length"] as? Int) {
                NSLog("Pero: editor and document went out of step, resyncing")
                let key = source.editorKey
                fetchText { [weak source] text in
                    guard let source, let text, source.editorKey == key else { return }
                    source.buffer.setText(text)
                    source.editorDidEdit()
                }
            }
            source.editorDidEdit()
            NotificationCenter.default.post(name: Self.sourceEdited, object: source, userInfo: ["editor": self])
        case "outline":
            let items = (body["items"] as? [[String: Any]] ?? []).compactMap { item -> Heading? in
                guard let level = item["level"] as? Int, let text = item["text"] as? String,
                      let from = item["from"] as? Int else { return nil }
                return Heading(level: level, text: text, from: from)
            }
            onOutline(items)
        case "current":
            onCurrentHeading(body["index"] as? Int ?? -1)
        case "openLink":
            openLink(href: body["href"] as? String ?? "", path: body["path"] as? String)
        case "openWiki":
            onOpenWiki(body["target"] as? String ?? "", body["section"] as? String, body["newWindow"] as? Bool ?? false)
        case "openTag":
            onOpenTag(body["tag"] as? String ?? "")
        case "attachFile":
            guard let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else { return }
            let name = body["name"] as? String ?? ""
            if let markdown = onAttachFile(data, name.isEmpty ? "Вставка" : name) { insert(markdown) }
        case "pendingImages":
            // Pictures that came inside pasted HTML as data: URIs.
            for (i, uri) in (body["images"] as? [String] ?? []).enumerated() {
                guard let comma = uri.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { continue }
                let mime = uri.dropFirst("data:".count).prefix { $0 != ";" && $0 != "," }
                let ext = UTType(mimeType: String(mime))?.preferredFilenameExtension ?? "png"
                guard let markdown = onAttachFile(data, "Вставка.\(ext)"),
                      let target = markdown.range(of: #"\(([^)]*)\)"#, options: .regularExpression) else { continue }
                let path = String(markdown[target].dropFirst().dropLast())
                call("""
                    const t = pero.getText(), needle = "(pero-pending:" + i + ")", at = t.indexOf(needle)
                    if (at >= 0) pero.view.dispatch({changes: {from: at + 1, to: at + needle.length - 1, insert: path}})
                    """, ["i": i, "path": path])
            }
        default:
            break
        }
    }

    private func openLink(href: String, path: String?) {
        if let path {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return NSSound.beep() }
            if FileTypes.isMarkdown(url) {
                if let controller = view.window?.windowController as? EditorWindowController {
                    controller.openFromSidebar(url)
                } else if let library = view.window?.windowController as? LibraryWindowController {
                    library.openFileLink(url)
                } else {
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                }
            } else if Self.isRunnable(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
        } else if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
                  !["javascript", "data", "file", "pero"].contains(scheme) {
            if ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
                return
            }
            // Other schemes hand the link to some app (ssh:, smb:, any app's own scheme): ask first.
            guard let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = "Открыть ссылку?"
            alert.informativeText = href
            alert.addButton(withTitle: "Открыть")
            alert.addButton(withTitle: "Отменить")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// Programs, scripts and bundles never start from a click in a note: a note from someone
    /// else could hide one behind a link. They are shown in Finder instead.
    static func isRunnable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isPackageKey])
        if values?.isPackage == true { return true }
        if let type = values?.contentType, [.executable, .script, .applicationBundle].contains(where: type.conforms(to:)) {
            return true
        }
        return ["terminal", "webloc", "inetloc", "fileloc", "jar", "pkg", "mpkg"].contains(url.pathExtension.lowercased())
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        if url == SchemeHandler.pageURL { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        // A Markdown file dropped onto a Finder document's editor opens as a document.
        if let url, url.isFileURL, FileTypes.isMarkdown(url), view.window?.windowController is EditorWindowController {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        webView.load(URLRequest(url: SchemeHandler.pageURL))
    }
}

/// Breaks the retain cycle WKUserContentController would create with the controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
