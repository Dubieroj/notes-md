import AppKit
import PeroKit

extension NSPasteboard.PasteboardType {
    static let peroNotes = NSPasteboard.PasteboardType("local.pero.notes")
    static let peroFolder = NSPasteboard.PasteboardType("local.pero.folder")
}

final class SidebarItem: NSObject {
    enum Kind: Equatable {
        case section(String)
        case quick, all, trash, allTags
        case folder(String)
        case smart(String)
        case tag(String)
    }

    let kind: Kind
    let title: String
    /// The library the item belongs to (the main one or a folder linked from the disk).
    let library: Library
    var children: [SidebarItem] = []

    init(_ kind: Kind, _ title: String, _ library: Library) {
        self.kind = kind
        self.title = title
        self.library = library
    }

    var scope: Scope? {
        switch kind {
        case .section: return nil
        case .quick: return .quick
        case .all: return .all
        case .trash: return .trash
        case .allTags: return .tags([])
        case .folder(let p): return .folder(p)
        case .smart(let id): return .smart(id)
        case .tag(let t): return .tags([t])
        }
    }

    var symbol: String {
        switch kind {
        case .section: return ""
        case .quick: return "note.text"
        case .all: return "tray.full"
        case .trash: return "trash"
        case .allTags: return "number.square"
        case .folder(let p): return p.isEmpty && isLinkedRoot ? "folder.fill" : "folder"
        case .smart: return "folder.badge.gearshape"
        case .tag: return "number"
        }
    }

    /// The top of a folder linked from the disk.
    var isLinkedRoot = false

    var folderPath: String? { if case .folder(let p) = kind { return p } else { return nil } }
    var isRenamable: Bool {
        switch kind {
        case .folder(let p): return !p.isEmpty
        case .smart: return true
        default: return false
        }
    }
}

/// The sidebar: Quick Notes, the library's folders and smart folders, Recently Deleted,
/// folders linked from the disk, tags of the library on screen.
final class SidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
                               NSTextFieldDelegate {
    let libraries: Libraries
    /// The library whose notes are on screen; its tags are shown at the bottom.
    var current: Library
    let outline = SidebarOutlineView()
    private var roots: [SidebarItem] = []
    private var expanded: Set<String> = Set(Settings.defaults.stringArray(forKey: "expandedFolders") ?? [])
    private var reloading = false
    private(set) var selectedScope: Scope = .folder("")

    var onSelect: (Library, Scope) -> Void = { _, _ in }
    weak var actions: LibraryWindowController?

    init(libraries: Libraries) {
        self.libraries = libraries
        current = libraries.main
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.registerForDraggedTypes([.peroNotes, .peroFolder, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.setAccessibilityLabel(String(localized: "Папки"))
        scroll.documentView = outline

        let newFolder = NSButton(title: String(localized: "Новая папка"), image: NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)!,
                                 target: nil, action: #selector(LibraryWindowController.newFolder(_:)))
        let link = NSButton(title: String(localized: "Папка с диска"), image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)!,
                            target: nil, action: #selector(LibraryWindowController.linkFolder(_:)))
        link.toolTip = String(localized: "Показать здесь любую папку с Markdown-файлами")
        for button in [newFolder, link] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.contentTintColor = .secondaryLabelColor
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        let stack = NSView()
        for v in [scroll, newFolder, link] { v.translatesAutoresizingMaskIntoConstraints = false; stack.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: stack.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: newFolder.topAnchor, constant: -4),
            newFolder.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12),
            newFolder.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -10),
            link.leadingAnchor.constraint(equalTo: newFolder.trailingAnchor, constant: 10),
            link.centerYAnchor.constraint(equalTo: newFolder.centerYAnchor),
        ])
        view = stack
        reload()
    }

    // MARK: Tree

    /// Folders of a library as a tree; the top ones are returned.
    private func folderTree(_ library: Library) -> [SidebarItem] {
        var top: [SidebarItem] = []
        var byPath: [String: SidebarItem] = [:]
        let isMain = library === libraries.main
        for path in library.folders {
            if isMain && (path == Library.quickFolder || path.hasPrefix(Library.quickFolder + "/")) { continue }
            let item = SidebarItem(.folder(path), (path as NSString).lastPathComponent, library)
            byPath[path] = item
            let parent = (path as NSString).deletingLastPathComponent
            if let p = byPath[parent] { p.children.append(item) } else { top.append(item) }
        }
        return top
    }

    private func smartAndTrash(_ library: Library) -> [SidebarItem] {
        var out = library.state.smartFolders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { SidebarItem(.smart($0.id), $0.name, library) }
        if !library.trash.isEmpty { out.append(SidebarItem(.trash, String(localized: "Недавно удалённые"), library)) }
        return out
    }

    private func buildTree() -> [SidebarItem] {
        let main = libraries.main
        var out: [SidebarItem] = [SidebarItem(.quick, String(localized: "Быстрые заметки"), main)]
        let section = SidebarItem(.section("На Mac"), String(localized: "На Mac"), main)
        section.children.append(SidebarItem(.all, String(localized: "Все заметки"), main))
        section.children.append(SidebarItem(.folder(""), String(localized: "Заметки"), main))
        section.children += folderTree(main)
        section.children += smartAndTrash(main)
        out.append(section)
        if !libraries.linked.isEmpty {
            let disk = SidebarItem(.section("Папки на диске"), String(localized: "Папки на диске"), main)
            for library in libraries.linked {
                let root = SidebarItem(.folder(""), library.root.lastPathComponent, library)
                root.isLinkedRoot = true
                root.children = folderTree(library) + smartAndTrash(library)
                disk.children.append(root)
            }
            out.append(disk)
        }
        let tags = current.tagCounts()
        if !tags.isEmpty {
            let title = current === main ? String(localized: "Теги") : String(localized: "Теги · \(current.root.lastPathComponent)")
            let t = SidebarItem(.section(title), title, current)
            t.children.append(SidebarItem(.allTags, String(localized: "Все теги"), current))
            t.children += tags.map { SidebarItem(.tag($0.tag), "#" + $0.tag, current) }
            out.append(t)
        }
        return out
    }

    private func expansionKey(_ item: SidebarItem) -> String? {
        guard let p = item.folderPath else { return nil }
        return item.library === libraries.main ? p : item.library.root.path + "|" + p
    }

    func reload() {
        roots = buildTree()
        reloading = true
        outline.reloadData()
        for root in roots { outline.expandItem(root) }
        func restore(_ items: [SidebarItem]) {
            for item in items where !item.children.isEmpty {
                if let key = expansionKey(item), expanded.contains(key) { outline.expandItem(item) }
                restore(item.children)
            }
        }
        restore(roots)
        selectRow(for: selectedScope)
        reloading = false
    }

    private func allItems() -> [SidebarItem] {
        var out: [SidebarItem] = []
        func walk(_ items: [SidebarItem]) { for i in items { out.append(i); walk(i.children) } }
        walk(roots)
        return out
    }

    /// Selects a sidebar item without telling the delegate (it already knows).
    func select(_ scope: Scope, in library: Library) {
        selectedScope = scope
        if current !== library {
            current = library
            reload()
            return
        }
        reloading = true
        selectRow(for: scope)
        reloading = false
    }

    private func selectRow(for scope: Scope) {
        guard let item = allItems().first(where: { $0.scope == scope && $0.library === current }) else {
            outline.deselectAll(nil)
            return
        }
        var parent = outline.parent(forItem: item)
        while let p = parent { outline.expandItem(p); parent = outline.parent(forItem: p) }
        let row = outline.row(forItem: item)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
    }

    func reloadCounts() {
        outline.enumerateAvailableRowViews { row, index in
            guard let item = self.outline.item(atRow: index) as? SidebarItem,
                  let cell = row.view(atColumn: 0) as? SidebarCell else { return }
            cell.count.stringValue = self.countText(item)
        }
    }

    private func countText(_ item: SidebarItem) -> String {
        guard let scope = item.scope else { return "" }
        let n = item.library.count(in: scope)
        return n > 0 ? String(n) : ""
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .section = (item as? SidebarItem)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarItem)?.scope != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        if case .section = (item as? SidebarItem)?.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        if case .section = item.kind {
            let cell = outlineView.makeView(withIdentifier: .init("header"), owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = .init("header")
                let t = NSTextField(labelWithString: "")
                t.font = .systemFont(ofSize: 11, weight: .semibold)
                t.textColor = .secondaryLabelColor
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                             t.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
                return c
            }()
            cell.textField?.stringValue = item.title
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: .init("item"), owner: self) as? SidebarCell ?? SidebarCell()
        cell.identifier = .init("item")
        cell.textField?.stringValue = item.title
        cell.textField?.isEditable = false
        cell.textField?.delegate = self
        cell.imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        if case .tag(let t) = item.kind, let hex = item.library.state.tagColors[t.lowercased()], let color = NSColor(hex: hex) {
            cell.imageView?.contentTintColor = color
        } else {
            cell.imageView?.contentTintColor = .controlAccentColor
        }
        cell.count.stringValue = countText(item)
        cell.toolTip = item.isLinkedRoot ? item.library.root.path : nil
        cell.setAccessibilityLabel(item.title)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let item = outline.item(atRow: outline.selectedRow) as? SidebarItem, let scope = item.scope else { return }
        selectedScope = scope
        let switched = current !== item.library
        current = item.library
        if item.library === libraries.main { Settings.lastScope = scope.encoded }
        onSelect(item.library, scope)
        // Another library's tags go to the bottom of the sidebar.
        if switched { DispatchQueue.main.async { self.reload() } }
    }

    func outlineViewItemDidExpand(_ notification: Notification) { rememberExpansion(notification, true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { rememberExpansion(notification, false) }

    private func rememberExpansion(_ notification: Notification, _ open: Bool) {
        guard !reloading, let item = notification.userInfo?["NSObject"] as? SidebarItem, let key = expansionKey(item) else { return }
        if open { expanded.insert(key) } else { expanded.remove(key) }
        Settings.defaults.set(Array(expanded), forKey: "expandedFolders")
    }

    // MARK: Renaming

    @objc private func doubleClicked(_ sender: Any?) {
        beginRename(row: outline.clickedRow)
    }

    func beginRename(row: Int? = nil) {
        let r = row ?? outline.selectedRow
        guard r >= 0, let item = outline.item(atRow: r) as? SidebarItem, item.isRenamable,
              let cell = outline.view(atColumn: 0, row: r, makeIfNecessary: false) as? SidebarCell,
              let field = cell.textField else { return }
        field.isEditable = true
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.isEditable = false
        let row = outline.row(for: field)
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return }
        let library = item.library
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if name == item.title || name.isEmpty { field.stringValue = item.title; return }
        switch item.kind {
        case .folder(let path):
            guard Library.isValidFolderName(name) else {
                field.stringValue = item.title
                actions?.showMessage(String(localized: "Такое название не подходит для папки"),
                                     String(localized: "Название не может быть пустым, начинаться с точки или содержать «/» и «:»."))
                return
            }
            if let newPath = try? library.renameFolder(path, to: name), library === current, selectedScope == .folder(path) {
                selectedScope = .folder(newPath)
                onSelect(library, selectedScope)
            }
        case .smart(let id):
            if var smart = library.state.smartFolders.first(where: { $0.id == id }) {
                smart.name = name
                library.updateSmartFolder(smart)
            }
        default: break
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else { return }
        let library = item.library
        func add(_ title: String.LocalizationValue, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: String(localized: title), action: action))
        }
        switch item.kind {
        case .folder(let path):
            add("Новая папка") { [weak self] in self?.actions?.createFolder(in: path, library: library) }
            if !path.isEmpty {
                add("Переименовать папку") { [weak self] in self?.beginRename(row: row) }
                add("Преобразовать в смарт-папку…") { [weak self] in self?.actions?.convertToSmartFolder(path, library: library) }
            }
            menu.addItem(.separator())
            menu.addItem(sortMenu(for: path, in: library))
            menu.addItem(groupMenu(for: path, in: library))
            menu.addItem(.separator())
            add("Экспортировать папку…") { [weak self] in self?.actions?.exportFolder(path, library: library) }
            add("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.url(path)]) }
            if item.isLinkedRoot {
                menu.addItem(.separator())
                add("Отключить папку") { [weak self] in self?.actions?.unlinkFolder(library) }
            } else if !path.isEmpty {
                menu.addItem(.separator())
                add("Удалить папку") { [weak self] in self?.actions?.deleteFolder(path, library: library) }
            }
        case .smart(let id):
            add("Изменить смарт-папку…") { [weak self] in self?.actions?.editSmartFolder(id, library: library) }
            add("Переименовать") { [weak self] in self?.beginRename(row: row) }
            menu.addItem(.separator())
            add("Удалить смарт-папку") { library.removeSmartFolder(id) }
        case .tag(let tag):
            add("Переименовать тег…") { [weak self] in self?.actions?.renameTag(tag) }
            add("Удалить тег…") { [weak self] in self?.actions?.deleteTag(tag) }
            let colors = NSMenuItem(title: String(localized: "Цвет"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (name, hex) in TagColors.all {
                let i = ClosureMenuItem(title: name) { library.setTagColor(tag, hex) }
                if let hex, let c = NSColor(hex: hex) { i.image = NSImage.dot(c) }
                i.state = library.state.tagColors[tag.lowercased()] == hex ? .on : .off
                sub.addItem(i)
            }
            colors.submenu = sub
            menu.addItem(colors)
        case .trash:
            add("Удалить всё навсегда…") { [weak self] in self?.actions?.emptyTrash(library) }
        case .quick:
            add("Новая быстрая заметка") { [weak self] in self?.actions?.newQuickNote(nil) }
        case .section("Папки на диске"):
            add("Подключить папку с диска…") { [weak self] in self?.actions?.linkFolder(nil) }
        default: break
        }
    }

    private func sortMenu(for folder: String, in library: Library) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Сортировать по"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = library.settings(for: folder)
        let def = ClosureMenuItem(title: String(localized: "По умолчанию")) {
            var s = library.settings(for: folder)
            s.sort = nil; s.ascending = nil
            library.setSettings(s, for: folder)
        }
        def.state = current.sort == nil ? .on : .off
        sub.addItem(def)
        sub.addItem(.separator())
        for (key, title) in [(SortKey.modified, String(localized: "Дата изменения")), (.created, String(localized: "Дата создания")), (.title, String(localized: "Название"))] {
            let i = ClosureMenuItem(title: title) {
                var s = library.settings(for: folder)
                s.sort = key
                s.ascending = key == .title
                library.setSettings(s, for: folder)
            }
            i.state = current.sort == key ? .on : .off
            sub.addItem(i)
        }
        if current.sort != nil {
            sub.addItem(.separator())
            let asc = current.ascending ?? false
            for (value, title) in [(false, current.sort == .title ? String(localized: "От Я до А") : String(localized: "Сначала новые")),
                                  (true, current.sort == .title ? String(localized: "От А до Я") : String(localized: "Сначала старые"))] {
                let i = ClosureMenuItem(title: title) {
                    var s = library.settings(for: folder)
                    s.ascending = value
                    library.setSettings(s, for: folder)
                }
                i.state = asc == value ? .on : .off
                sub.addItem(i)
            }
        }
        item.submenu = sub
        return item
    }

    private func groupMenu(for folder: String, in library: Library) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Группировать по дате"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = library.settings(for: folder).groupByDate
        for (value, title) in [(nil as Bool?, String(localized: "По умолчанию")), (true, String(localized: "Вкл.")), (false, String(localized: "Выкл."))] {
            let i = ClosureMenuItem(title: title) {
                var s = library.settings(for: folder)
                s.groupByDate = value
                library.setSettings(s, for: folder)
            }
            i.state = current == value ? .on : .off
            sub.addItem(i)
        }
        item.submenu = sub
        return item
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarItem, case .folder(let path) = item.kind, !path.isEmpty else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(item.library.root.path + "\u{1F}" + path, forType: .peroFolder)
        return pb
    }

    private func draggedFolder(_ pb: NSPasteboard) -> (root: String, path: String)? {
        guard let s = pb.string(forType: .peroFolder) else { return nil }
        let parts = s.components(separatedBy: "\u{1F}")
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let target = item as? SidebarItem else { return [] }
        let pb = info.draggingPasteboard
        if let (root, dragged) = draggedFolder(pb) {
            // Folders move inside their own library only.
            guard target.library.root.path == root, case .folder(let dest) = target.kind, dest != dragged,
                  !dest.hasPrefix(dragged + "/"), (dragged as NSString).deletingLastPathComponent != dest else { return [] }
            outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        if pb.availableType(from: [.peroNotes]) != nil {
            switch target.kind {
            case .folder, .quick:
                outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            case .trash where target.library === current:
                outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .move
            default: return []
            }
        }
        if pb.availableType(from: [.fileURL]) != nil {
            switch target.kind {
            case .folder, .quick:
                outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return .copy
            default: return []
            }
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let target = item as? SidebarItem else { return false }
        let pb = info.draggingPasteboard
        if let (_, dragged) = draggedFolder(pb), case .folder(let dest) = target.kind {
            actions?.moveFolder(dragged, into: dest, library: target.library)
            return true
        }
        if let data = pb.data(forType: .peroNotes), let paths = try? JSONDecoder().decode([String].self, from: data) {
            switch target.kind {
            case .folder(let dest): actions?.moveNotes(paths, to: dest, library: target.library)
            case .quick: actions?.moveNotes(paths, to: Library.quickFolder, library: target.library)
            case .trash: actions?.deleteNotes(paths)
            default: return false
            }
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            switch target.kind {
            case .folder(let dest): actions?.importFiles(urls, into: dest, library: target.library)
            case .quick: actions?.importFiles(urls, into: Library.quickFolder, library: target.library)
            default: return false
            }
            return true
        }
        return false
    }
}

final class SidebarOutlineView: NSOutlineView {
    override func keyDown(with event: NSEvent) {
        // Return renames the selected folder, as in Finder and Notes.
        if event.keyCode == 36, let controller = delegate as? SidebarController {
            controller.beginRename()
            return
        }
        super.keyDown(with: event)
    }
}

final class SidebarCell: NSTableCellView {
    let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.cell?.isScrollable = false
        text.focusRingType = .none
        count.textColor = .secondaryLabelColor
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.alignment = .right
        for v in [image, text, count] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        imageView = image
        textField = text
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String = "", action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

enum TagColors {
    static let all: [(String, String?)] = [
        (String(localized: "Без цвета"), nil), (String(localized: "Красный"), "#E5484D"),
        (String(localized: "Оранжевый"), "#F76B15"), (String(localized: "Жёлтый"), "#E2A336"),
        (String(localized: "Зелёный"), "#30A46C"), (String(localized: "Голубой"), "#0090FF"),
        (String(localized: "Фиолетовый"), "#8E4EC6"), (String(localized: "Серый"), "#8B8D98"),
    ]
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension NSImage {
    static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
