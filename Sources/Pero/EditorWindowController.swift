import AppKit
import PeroKit
import SwiftUI

/// A document window: sidebar (folder tree / outline) on the left, editor on the right.
final class EditorWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    let editor: EditorViewController
    let sidebar = SidebarModel()
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!

    private static let modeItem = NSToolbarItem.Identifier("pero.mode")
    private static let lastFolderKey = "lastFolder"

    init(document: MarkdownDocument) {
        editor = EditorViewController(source: document)
        document.editor = editor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 360)
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        super.init(window: window)

        let host = NSHostingController(rootView: SidebarView(model: sidebar))
        if #available(macOS 13.0, *) { host.sizingOptions = [] }
        sidebarItem = NSSplitViewItem(sidebarWithViewController: host)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 360
        split.splitViewItems = [sidebarItem, editorItem]
        split.splitView.autosaveName = "PeroSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1120, height: 780))
        window.center()
        window.setFrameAutosaveName("PeroWindow")

        let toolbar = NSToolbar(identifier: "PeroToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        wireSidebar(document: document)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    private func wireSidebar(document: MarkdownDocument) {
        let controller = NSDocumentController.shared as? DocumentController
        let root = controller?.takePendingRoot()
            ?? document.fileURL?.deletingLastPathComponent()
            ?? UserDefaults.standard.url(forKey: Self.lastFolderKey)
        sidebar.setRoot(root)
        sidebar.showFile(document.fileURL)
        sidebar.openFile = { [weak self] url in self?.openFromSidebar(url) }
        sidebar.revealHeading = { [weak self] heading in self?.editor.reveal(heading.from) }
        sidebar.chooseFolder = { [weak self] in self?.openFolder(nil) }
        editor.onOutline = { [weak self] items in self?.sidebar.headings = items }
        editor.onCurrentHeading = { [weak self] index in self?.sidebar.currentHeading = index }
    }

    /// Opens a file in its own tab; its sidebar keeps showing this window's folder.
    func openFromSidebar(_ url: URL) {
        guard url != markdownDocument?.fileURL else { return }
        (NSDocumentController.shared as? DocumentController)?.pendingRoot = sidebar.root
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
            if let error { self?.presentError(error) }
            // The clicked file may already be open in another tab: keep the tree on our file.
            self?.sidebar.showFile(self?.markdownDocument?.fileURL)
        }
    }

    func documentURLChanged() {
        editor.documentURLChanged()
        if sidebar.root == nil, let dir = markdownDocument?.fileURL?.deletingLastPathComponent() { sidebar.setRoot(dir) }
        sidebar.showFile(markdownDocument?.fileURL)
        sidebar.reload()
    }

    @objc private func appDidBecomeActive() { sidebar.reload() }

    // MARK: Menu actions

    @objc func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Открыть"
        panel.message = "Выберите папку с Markdown-файлами"
        panel.directoryURL = sidebar.root
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            UserDefaults.standard.set(url, forKey: Self.lastFolderKey)
            self.sidebar.setRoot(url)
            self.sidebar.tab = .files
            if self.sidebarItem.isCollapsed { self.split.toggleSidebar(nil) }
        }
    }

    @objc func toggleSourceMode(_ sender: Any?) {
        editor.setSourceMode(!editor.isSourceMode)
        window?.toolbar?.items.first { $0.itemIdentifier == Self.modeItem }.map(updateModeItem)
    }

    @objc func showFiles(_ sender: Any?) { showSidebarTab(.files) }
    @objc func showOutline(_ sender: Any?) { showSidebarTab(.outline) }

    private func showSidebarTab(_ tab: SidebarModel.Tab) {
        sidebar.tab = tab
        if sidebarItem.isCollapsed { split.toggleSidebar(nil) }
    }

    @objc func format(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String { editor.run(command) }
    }

    @objc func peroUndo(_ sender: Any?) { editor.run("undo") }
    @objc func peroRedo(_ sender: Any?) { editor.run("redo") }
    @objc func peroSelectAll(_ sender: Any?) { editor.run("selectAll") }
    @objc func peroFind(_ sender: Any?) { editor.run("find") }

    @objc func exportHTML(_ sender: Any?) {
        guard let window, let document = markdownDocument else { return }
        Exporter.exportHTML(document: document, editor: editor, window: window)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window, let document = markdownDocument else { return }
        Exporter.exportPDF(document: document, editor: editor, window: window)
    }

    /// «Экспортировать как» for a Markdown file opened from Finder.
    @objc func exportNotes(_ sender: NSMenuItem) {
        guard let window, let document = markdownDocument else { return }
        switch sender.representedObject as? String {
        case "pdf": exportPDF(sender)
        case "html": exportHTML(sender)
        case "text":
            Exporter.ask(for: .plainText, base: document.exportTitle, directory: document.fileURL?.deletingLastPathComponent(), window: window) { url in
                do { try Data(PlainText.from(document.text).utf8).write(to: url, options: .atomic) } catch { document.presentError(error) }
            }
        default: document.saveAs(sender)
        }
    }

    @objc func printNote(_ sender: Any?) {
        guard let document = markdownDocument else { return }
        Exporter.print(document.text, title: document.exportTitle, baseDir: document.baseDirectory, editor: editor, window: window)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSourceMode(_:)): item.state = editor.isSourceMode ? .on : .off
        case #selector(showFiles(_:)): item.state = sidebar.tab == .files && !sidebarItem.isCollapsed ? .on : .off
        case #selector(showOutline(_:)): item.state = sidebar.tab == .outline && !sidebarItem.isCollapsed ? .on : .off
        default: break
        }
        return true
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.modeItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Self.modeItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Исходник"
        item.target = self
        item.action = #selector(toggleSourceMode(_:))
        item.isBordered = true
        updateModeItem(item)
        return item
    }

    private func updateModeItem(_ item: NSToolbarItem) {
        let source = editor.isSourceMode
        item.image = NSImage(systemSymbolName: source ? "text.alignleft" : "chevron.left.forwardslash.chevron.right",
                             accessibilityDescription: nil)
        item.toolTip = source ? "Вернуться к оформленному тексту (⌘/)" : "Показать исходник Markdown (⌘/)"
    }
}
