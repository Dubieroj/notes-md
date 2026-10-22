import AppKit
import PeroKit

/// The main window, as in Notes: folders, the notes list and the open note.
final class LibraryWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                      NSSearchFieldDelegate {
    let libraries: Libraries
    /// The library on screen: the main one or a folder linked from the disk.
    private(set) var library: Library
    let lock: LockManager
    let split = NSSplitViewController()
    let sidebar: SidebarController
    let list: NoteListController
    let editorPane = NoteEditorController()
    var editor: EditorViewController { editorPane.editor }
    private var sidebarItem: NSSplitViewItem!
    private var listItem: NSSplitViewItem!

    private(set) var session: NoteSession?
    private(set) var scope: Scope = .folder("")
    private(set) var searchText = ""
    private weak var searchField: NSSearchField?
    private var listWidthBeforeGallery: CGFloat = 300
    private var back: [String] = []
    private var forward: [String] = []
    private var navigating = false
    var lastSelection: [String] = []

    init(libraries: Libraries, lock: LockManager) {
        self.libraries = libraries
        library = libraries.main
        self.lock = lock
        sidebar = SidebarController(libraries: libraries)
        list = NoteListController(library: libraries.main)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Заметки.md")
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 640, height: 400)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        listItem = NSSplitViewItem(contentListWithViewController: list)
        listItem.minimumThickness = 230
        listItem.maximumThickness = 520
        let editorItem = NSSplitViewItem(viewController: editorPane)
        editorItem.minimumThickness = 320
        split.splitViewItems = [sidebarItem, listItem, editorItem]
        split.splitView.autosaveName = "PeroLibrarySplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.setFrameAutosaveName("PeroLibraryWindow")

        let toolbar = NSToolbar(identifier: "PeroLibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        // Toolbars saved before the Back button existed get it too.
        if !toolbar.items.contains(where: { $0.itemIdentifier == Self.backToGalleryID }) {
            let after = toolbar.items.firstIndex { $0.itemIdentifier == .sidebarTrackingSeparator }
            toolbar.insertItem(withItemIdentifier: Self.backToGalleryID, at: after.map { $0 + 1 } ?? 0)
        }

        wire()
        if let saved = Settings.lastScope.flatMap(Scope.init(encoded:)), exists(saved) { scope = saved }
        sidebar.select(scope, in: library)
        reloadList(selectFirst: true)
        // A layout saved while the gallery was open has no editor column: bring it back.
        DispatchQueue.main.async { self.setGallery(Settings.galleryView) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        sidebar.actions = self
        list.actions = self
        sidebar.onSelect = { [weak self] library, scope in
            guard let self else { return }
            self.switchLibrary(to: library)
            self.clearSearch()
            self.scope = scope
            self.reloadList(selectFirst: true)
        }
        list.onSelectionChange = { [weak self] paths in self?.selectionChanged(paths) }
        list.onActivate = { [weak self] in self?.editor.focusText() }
        list.onOpenFromGallery = { [weak self] path in self?.openFromGallery(path) }
        // Pictures load from any folder on the Mac, not only the library.
        editor.fileAccessRoot = nil
        editor.onReady = { [weak self] in self?.configureEditor() }
        editor.onOpenWiki = { [weak self] target, section, newWindow in self?.openWiki(target, section: section, newWindow: newWindow) }
        editor.onOpenTag = { [weak self] tag in self?.showScope(.tags([tag])) }
        editor.onAttachFile = { [weak self] data, name in self?.attach(data: data, name: name) }
        editorPane.lockView.onPassword = { [weak self] password in self?.unlock(password: password) }
        editorPane.lockView.onTouchID = { [weak self] in self?.unlockWithTouchID() }
        editorPane.lockView.hintText = { [weak self] in self?.lock.hint }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(libraryChanged(_:)), name: Library.didChange, object: nil)
        center.addObserver(self, selector: #selector(librariesChanged), name: Libraries.didChange, object: libraries)
        center.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        center.addObserver(self, selector: #selector(lockChanged), name: LockManager.didChange, object: lock)
        center.addObserver(self, selector: #selector(appWillResign), name: NSApplication.willResignActiveNotification, object: nil)
    }

    private func configureEditor() {
        editor.configure(["notes": true, "zoom": Settings.zoom, "autoSortChecked": Settings.autoSortChecked,
                          "showStats": Settings.showWordCount])
        sendSuggestions()
    }

    /// Note titles and tags for suggestions after [[, >> and #.
    private func sendSuggestions() {
        let titles = library.notes.values.filter { !$0.title.isEmpty }.map(\.title)
        let unique = Array(Set(titles)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        editor.configure(["titles": unique, "tags": library.tagCounts().map(\.tag)])
    }

    private func exists(_ scope: Scope) -> Bool {
        switch scope {
        case .folder(let f): return f.isEmpty || library.folders.contains(f)
        case .smart(let id): return library.state.smartFolders.contains { $0.id == id }
        case .trash: return !library.trash.isEmpty
        default: return true
        }
    }

    // MARK: List

    private var sortKey: SortKey {
        if case .folder(let f) = scope, let s = library.settings(for: f).sort { return s }
        return Settings.sortKey
    }

    private var ascending: Bool {
        if case .folder(let f) = scope, library.settings(for: f).sort != nil { return library.settings(for: f).ascending ?? false }
        return Settings.sortAscending
    }

    private var groupByDate: Bool {
        if case .folder(let f) = scope, let g = library.settings(for: f).groupByDate { return g }
        return Settings.groupByDate
    }

    func reloadList(selectFirst: Bool = false, select: [String]? = nil) {
        let groups: [NoteGroup]
        var empty = String(localized: "Нет заметок")
        if !searchText.isEmpty {
            let found = library.search(searchText)
            groups = found.isEmpty ? [] : [NoteGroup(title: String(localized: "Найдено: \(found.count)"), notes: found)]
            list.showsFolders = true
            empty = String(localized: "Ничего не найдено")
        } else {
            let notes = library.notes(in: scope)
            switch scope {
            case .trash:
                groups = NoteSorting.groups(notes, by: .modified, ascending: false, groupByDate: false, isPinned: { _ in false })
                empty = String(localized: "Здесь появятся удалённые заметки")
            default:
                groups = NoteSorting.groups(notes, by: sortKey, ascending: ascending, groupByDate: groupByDate,
                                            isPinned: { self.library.isPinned($0) })
            }
            switch scope {
            case .all, .smart, .tags: list.showsFolders = true
            default: list.showsFolders = false
            }
        }
        list.scope = searchText.isEmpty ? scope : .all
        list.setGroups(groups, select: select, empty: empty)
        // As in Notes, a list with notes always has one open.
        if list.selectedPaths.isEmpty { list.selectFirst() }
        if list.selectedPaths.isEmpty { selectionChanged([]) }
        window?.subtitle = ""
    }

    /// Shows another library (a folder from the disk, or back to the main one).
    func switchLibrary(to other: Library) {
        guard other !== library else { return }
        closeSession()
        lastSelection = []
        back.removeAll()
        forward.removeAll()
        library = other
        list.library = other
        sendSuggestions()
    }

    @objc private func librariesChanged() {
        if !libraries.all.contains(where: { $0 === library }) {
            switchLibrary(to: libraries.main)
            scope = .folder("")
        }
        sidebar.current = library
        sidebar.select(scope, in: library)
        sidebar.reload()
        reloadList(selectFirst: true)
    }

    @objc private func libraryChanged(_ note: Notification) {
        // Another library changed (a linked folder, the main one): its counts only.
        guard let changedLibrary = note.object as? Library, changedLibrary === library else {
            if let other = note.object as? Library, libraries.all.contains(where: { $0 === other }) { sidebar.reload() }
            return
        }
        let info = note.userInfo ?? [:]
        let moved = info["moved"] as? [String: String] ?? [:]
        let removed = Set(info["removed"] as? [String] ?? [])
        if !moved.isEmpty {
            session?.applyMoves(moved)
            back = back.map { moved[$0] ?? $0 }
            forward = forward.map { moved[$0] ?? $0 }
            if case .folder(let f) = scope, !exists(.folder(f)) { scope = .folder("") }
        }
        // Edits made elsewhere reach the editor through SessionStore (sourceEdited).
        if let session, !session.isTrash, removed.contains(session.path), library.record(session.path) == nil {
            session.abandon()
            closeSession()
        }
        if !exists(scope) { scope = .folder(""); sidebar.select(scope, in: library) }
        sidebar.reload()
        sendSuggestions()
        let keep = list.selectedPaths.map { moved[$0] ?? $0 }
        reloadList(select: keep)
        if let session { editor.setHeader(session.header) }
        updateDockBadge()
    }

    @objc private func settingsChanged() {
        configureEditor()
        reloadList()
        updateDockBadge()
    }

    @objc private func lockChanged() {
        // Closing locked notes: the open one goes back to its lock screen.
        if session?.isLocked == true, !lock.isUnlocked {
            closeSession()
            lastSelection = []
            selectionChanged(list.selectedPaths)
        } else if lock.isUnlocked, session == nil {
            selectionChanged(list.selectedPaths)
        }
    }

    @objc private func appWillResign() { session?.saveNow() }

    func updateDockBadge() {
        let quick = libraries.main.count(in: .quick)
        NSApp.dockTile.badgeLabel = Settings.showDockBadge && quick > 0 ? String(quick) : nil
    }

    // MARK: Selection and sessions

    private func selectionChanged(_ paths: [String]) {
        if paths == lastSelection, session != nil || paths.count != 1 {
            return
        }
        let previous = lastSelection
        lastSelection = paths
        guard paths.count == 1, let path = paths.first else {
            closeSession()
            let n = paths.count
            editorPane.display(.nothing(n > 1 ? String(localized: "Выбрано: \(n) \(Plural.notes(n))") : (list.rows.isEmpty ? "" : String(localized: "Нет выбранной заметки"))))
            return
        }
        if !navigating, previous.count == 1, let p = previous.first, p != path {
            back.append(p)
            forward.removeAll()
        }
        open(path)
    }

    /// Saves and lets go of the open note if it is `path` (before locking or unlocking it).
    func closeSession(for path: String) {
        guard session?.path == path else { return }
        closeSession()
        lastSelection = []
    }

    func closeSession() {
        guard let old = session else { return }
        session = nil
        SessionStore.shared.release(old)
        editor.call("pero.forget(key)", ["key": old.editorKey])
    }

    private func open(_ path: String, focus: Bool = false) {
        if session?.library === library, session?.path == path, scope != .trash || session?.isTrash == true { return }
        closeSession()
        if scope == .trash && searchText.isEmpty, let item = library.trash.first(where: { library.trashRecords[$0.id]?.path == path }) {
            if let s = try? SessionStore.shared.acquire(library: library, path: path, kind: .trash(item)) {
                session = s
                editorPane.display(.session(s))
            }
            return
        }
        guard let record = library.record(path) else { return editorPane.display(.nothing("")) }
        if record.isLocked {
            guard let master = lock.master else { return editorPane.display(.locked(record)) }
            guard let s = try? SessionStore.shared.acquire(library: library, path: path, kind: .locked(master)) else {
                return editorPane.display(.locked(record))
            }
            attach(s)
            editorPane.display(.session(s), focus: focus)
            return
        }
        guard let s = try? SessionStore.shared.acquire(library: library, path: path) else {
            return editorPane.display(.nothing(String(localized: "Не удалось открыть заметку")))
        }
        attach(s)
        editorPane.display(.session(s), focus: focus)
    }

    private func attach(_ s: NoteSession) {
        session = s
        s.onRename = { [weak self] _, new in
            guard let self else { return }
            self.lastSelection = [new]
        }
        s.onSaveError = { [weak self] error in self?.window.map { NSAlert(error: error).beginSheetModal(for: $0) } }
    }

    /// Shows a note of another library (a folder from the disk).
    func reveal(_ path: String, in other: Library, focus: Bool = false) {
        if other !== library {
            switchLibrary(to: other)
            scope = .folder((path as NSString).deletingLastPathComponent)
            sidebar.select(scope, in: library)
            reloadList(select: [path])
        }
        reveal(path, focus: focus)
    }

    /// Shows a note: selects it in its folder (or stays in the current list if it's there).
    func reveal(_ path: String, focus: Bool = false) {
        if !list.allPaths.contains(path) {
            clearSearch()
            let folder = (path as NSString).deletingLastPathComponent
            scope = folder == Library.quickFolder && library === libraries.main ? .quick : .folder(folder)
            sidebar.select(scope, in: library)
            reloadList(select: [path])
        }
        list.select([path])
        if focus { editor.focusText() }
    }

    func showScope(_ s: Scope, in other: Library? = nil) {
        if let other { switchLibrary(to: other) }
        clearSearch()
        scope = s
        sidebar.select(s, in: library)
        reloadList(selectFirst: true)
    }

    // MARK: Search

    func searchFieldDidStartSearching(_ sender: NSSearchField) {}

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        searchText = ""
        reloadList(selectFirst: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        searchText = field.stringValue.trimmingCharacters(in: .whitespaces)
        reloadList(selectFirst: true)
    }

    /// The search field, typed into by the test hooks.
    func testSearch(_ text: String) {
        searchField?.stringValue = text
        searchText = text
        reloadList(selectFirst: true)
    }

    private func clearSearch() {
        guard !searchText.isEmpty else { return }
        searchText = ""
        searchField?.stringValue = ""
    }

    @objc func searchAllNotes(_ sender: Any?) {
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.searchID }) as? NSSearchToolbarItem {
            item.beginSearchInteraction()
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) { closeSession() }

    func windowDidResignKey(_ notification: Notification) { session?.saveNow() }

    func saveAll() { SessionStore.shared.saveAll() }

    // MARK: Toolbar

    static let viewModeID = NSToolbarItem.Identifier("pero.viewMode")
    static let backToGalleryID = NSToolbarItem.Identifier("pero.backToGallery")
    static let deleteID = NSToolbarItem.Identifier("pero.delete")
    static let listSeparatorID = NSToolbarItem.Identifier("pero.listSeparator")
    static let composeID = NSToolbarItem.Identifier("pero.compose")
    static let formatID = NSToolbarItem.Identifier("pero.format")
    static let checklistID = NSToolbarItem.Identifier("pero.checklist")
    static let tableID = NSToolbarItem.Identifier("pero.table")
    static let attachID = NSToolbarItem.Identifier("pero.attach")
    static let lockID = NSToolbarItem.Identifier("pero.lock")
    static let shareID = NSToolbarItem.Identifier("pero.share")
    static let sourceID = NSToolbarItem.Identifier("pero.source")
    static let searchID = NSToolbarItem.Identifier("pero.search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.backToGalleryID, Self.viewModeID, .flexibleSpace, Self.deleteID, Self.listSeparatorID,
         Self.composeID, .space, Self.formatID, Self.checklistID, Self.tableID, Self.attachID, .flexibleSpace,
         Self.sourceID, Self.lockID, Self.shareID, Self.searchID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.action = action
            item.target = self
            item.isBordered = true
            return item
        }
        func menuItem(_ symbol: String, _ label: String, _ menu: NSMenu) -> NSToolbarItem {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.menu = menu
            item.showsIndicator = true
            return item
        }
        switch id {
        case Self.viewModeID:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "list.bullet", accessibilityDescription: String(localized: "Список"))!,
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: String(localized: "Галерея"))!,
            ], selectionMode: .selectOne, labels: [String(localized: "Список"), String(localized: "Галерея")], target: self, action: #selector(viewModeChanged(_:)))
            group.label = String(localized: "Вид")
            group.selectedIndex = Settings.galleryView ? 1 : 0
            return group
        case Self.backToGalleryID:
            let item = button("chevron.left", String(localized: "Назад"), #selector(backToGallery(_:)))
            item.toolTip = String(localized: "Вернуться к галерее")
            item.isHidden = !isGalleryNoteOpen
            return item
        case Self.deleteID: return button("trash", String(localized: "Удалить"), #selector(deleteNote(_:)))
        case Self.listSeparatorID:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 1)
        case Self.composeID: return button("square.and.pencil", String(localized: "Новая заметка"), #selector(newNote(_:)))
        case Self.formatID: return menuItem("textformat", String(localized: "Формат"), MainMenu.paragraphStylesMenu())
        case Self.checklistID: return button("checklist", String(localized: "Чек-лист"), #selector(toolbarChecklist(_:)))
        case Self.tableID: return button("tablecells", String(localized: "Таблица"), #selector(toolbarTable(_:)))
        case Self.attachID: return menuItem("paperclip", String(localized: "Вложения"), MainMenu.attachMenu())
        case Self.sourceID: return button("chevron.left.forwardslash.chevron.right", String(localized: "Исходник"), #selector(toggleSourceMode(_:)))
        case Self.lockID: return menuItem("lock", String(localized: "Блокировка"), MainMenu.lockMenu())
        case Self.shareID:
            return button("square.and.arrow.up", String(localized: "Поделиться"), #selector(shareFromToolbar(_:)))
        case Self.searchID:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = String(localized: "Поиск")
            item.searchField.delegate = self
            item.label = String(localized: "Поиск")
            searchField = item.searchField
            return item
        default: return nil
        }
    }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        setGallery(sender.selectedIndex == 1)
    }

    @objc private func toolbarChecklist(_ sender: Any?) { formatCommand("checklist") }
    @objc private func toolbarTable(_ sender: Any?) { formatCommand("table") }

    @objc private func shareFromToolbar(_ sender: Any?) {
        guard let view = (sender as? NSToolbarItem)?.view ?? window?.contentView else { return }
        share(list.selectedPaths, from: view)
    }

    // MARK: Menu validation

    private var editorActive: Bool { session != nil && !(session?.isTrash ?? true) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let selected = list.selectedPaths
        switch item.action {
        case #selector(format(_:)), #selector(insertLink(_:)), #selector(attachFile(_:)), #selector(insertFromDevice(_:)):
            return editorActive
        case #selector(toggleSourceMode(_:)):
            item.state = editor.isSourceMode ? .on : .off
            return session != nil
        case #selector(deleteNote(_:)), #selector(pinNote(_:)), #selector(duplicateNote(_:)), #selector(exportNotes(_:)),
             #selector(printNote(_:)), #selector(openNoteInNewWindow(_:)), #selector(moveToFolder(_:)), #selector(copyAsMarkdown(_:)):
            if item.action == #selector(pinNote(_:)) {
                let pinned = !selected.isEmpty && selected.allSatisfy { library.isPinned($0) }
                item.title = pinned ? String(localized: "Открепить заметку") : String(localized: "Закрепить заметку")
            }
            if scope == .trash && item.action != #selector(deleteNote(_:)) && item.action != #selector(moveToFolder(_:)) { return false }
            return !selected.isEmpty
        case #selector(lockNote(_:)):
            let record = selected.count == 1 ? library.record(selected[0]) : nil
            item.title = record?.isLocked == true ? String(localized: "Снять защиту") : String(localized: "Заблокировать заметку")
            return record != nil && scope != .trash
        case #selector(closeLockedNotes(_:)):
            return lock.isUnlocked
        case #selector(showList(_:)): item.state = Settings.galleryView ? .off : .on; return true
        case #selector(showGallery(_:)): item.state = Settings.galleryView ? .on : .off; return true
        case #selector(sortBy(_:)):
            item.state = (item.representedObject as? String) == Settings.sortKey.rawValue ? .on : .off
            return true
        case #selector(toggleGroupByDate(_:)): item.state = Settings.groupByDate ? .on : .off; return true
        case #selector(goBack(_:)): return !back.isEmpty
        case #selector(goForward(_:)): return !forward.isEmpty
        case #selector(restoreNote(_:)): return scope == .trash && !selected.isEmpty
        default: return true
        }
    }

    // MARK: Editing commands

    @objc func format(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String { formatCommand(command) }
    }

    func formatCommand(_ command: String) {
        guard editorActive else { return NSSound.beep() }
        lock.touch()
        editor.run(command)
    }

    @objc func peroUndo(_ sender: Any?) { editor.run("undo") }
    @objc func peroRedo(_ sender: Any?) { editor.run("redo") }
    @objc func peroSelectAll(_ sender: Any?) {
        if window?.firstResponder === list.table { list.table.selectAll(nil) } else { editor.run("selectAll") }
    }
    @objc func peroFind(_ sender: Any?) { editor.run("find") }

    @objc func toggleSourceMode(_ sender: Any?) { editor.setSourceMode(!editor.isSourceMode) }

    @objc func zoomIn(_ sender: Any?) { Settings.zoom += 0.1 }
    @objc func zoomOut(_ sender: Any?) { Settings.zoom -= 0.1 }
    @objc func zoomReset(_ sender: Any?) { Settings.zoom = 1 }

    @objc func showList(_ sender: Any?) { setGallery(false) }

    @objc func showAttachments(_ sender: Any?) {
        session?.saveNow()
        AttachmentsWindowController.show(library: library) { [weak self] path in
            guard let self else { return }
            self.showWindow(nil)
            self.reveal(path)
        }
    }
    @objc func showGallery(_ sender: Any?) { setGallery(true) }

    /// A note opened from the gallery covers the cards; the Back button brings them back.
    var isGalleryNoteOpen: Bool { Settings.galleryView && listItem.isCollapsed }

    @objc func backToGallery(_ sender: Any?) { galleryNoteOpen(false) }

    /// `visible` while a collapse animation hasn't finished yet; otherwise read from the layout.
    func updateBackButton(visible: Bool? = nil) {
        window?.toolbar?.items.first { $0.itemIdentifier == Self.backToGalleryID }?.isHidden = !(visible ?? isGalleryNoteOpen)
    }

    /// Gallery: as in Notes, the cards take the whole content area; opening a card shows
    /// the note in their place, and ⌘2 or the toolbar goes back to the cards.
    func setGallery(_ on: Bool) {
        let wasGallery = list.isGallery
        Settings.galleryView = on
        (window?.toolbar?.items.first { $0.itemIdentifier == Self.viewModeID } as? NSToolbarItemGroup)?.selectedIndex = on ? 1 : 0
        if on && !wasGallery { listWidthBeforeGallery = list.view.frame.width }
        list.setGallery(on)
        let items = split.splitViewItems
        items[1].canCollapse = true
        items[2].canCollapse = true
        listItem.maximumThickness = on ? NSSplitViewItem.unspecifiedDimension : 520
        items[1].isCollapsed = false
        items[2].isCollapsed = on
        // Only the gallery hides a column (the cards or the open note). In the list view neither
        // can be dragged shut: there would be no way to bring it back.
        items[1].canCollapse = on
        items[2].canCollapse = on
        updateBackButton()
        if !on {
            // Back to three columns with the list as wide as it was before the gallery.
            let width = min(max(listWidthBeforeGallery, 260), 400)
            let left = sidebarItem.isCollapsed ? 0 : sidebar.view.frame.width + split.splitView.dividerThickness
            split.splitView.setPosition(left + width, ofDividerAt: 1)
        }
        list.focus()
    }

    @objc func sortBy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        Settings.sortKey = key
        Settings.sortAscending = key == .title
    }

    @objc func toggleGroupByDate(_ sender: Any?) { Settings.groupByDate.toggle() }

    @objc func goBack(_ sender: Any?) {
        guard let path = back.popLast(), let current = session?.path else { return }
        forward.append(current)
        navigate(to: path)
    }

    @objc func goForward(_ sender: Any?) {
        guard let path = forward.popLast(), let current = session?.path else { return }
        back.append(current)
        navigate(to: path)
    }

    private func navigate(to path: String) {
        navigating = true
        reveal(path)
        navigating = false
    }

    func openWiki(_ target: String, section: String?, newWindow: Bool) {
        if let record = library.resolveWikiLink(target) {
            if newWindow { return openInNewWindow(record.path) }
            if let current = session?.path, current != record.path { back.append(current); forward.removeAll() }
            navigating = true
            reveal(record.path)
            navigating = false
            if let section, let heading = NoteParser.parse((try? library.loadBuffer(record.path).text) ?? "").headings
                .first(where: { $0.text.lowercased() == section.lowercased() }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.editor.reveal(heading.offset) }
            }
            return
        }
        // A link to a note that does not exist yet: offer to create it.
        let alert = NSAlert()
        alert.messageText = String(localized: "Заметки «\(target)» нет")
        alert.informativeText = String(localized: "Создать её в этой папке?")
        alert.addButton(withTitle: String(localized: "Создать"))
        alert.addButton(withTitle: String(localized: "Отменить"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.createNote(text: "# \(target)\n\n", focus: true)
        }
    }

    func openFileLink(_ url: URL) {
        let rel = url.resolvingSymlinksInPath().path
        let root = library.root.resolvingSymlinksInPath().path + "/"
        if rel.hasPrefix(root), library.record(String(rel.dropFirst(root.count))) != nil {
            reveal(String(rel.dropFirst(root.count)))
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    // MARK: Locking

    private func unlock(password: String) {
        if lock.unlock(password: password) {
            lastSelection = []
            selectionChanged(list.selectedPaths)
        } else {
            editorPane.lockView.shake()
        }
    }

    private func unlockWithTouchID() {
        lock.unlockWithTouchID { [weak self] ok in
            guard let self, ok else { return }
            self.lastSelection = []
            self.selectionChanged(self.list.selectedPaths)
        }
    }

    @objc func closeLockedNotes(_ sender: Any?) { lock.lockNow() }

    // MARK: Messages

    func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func showError(_ error: Error) {
        if let window { NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
    }
}
