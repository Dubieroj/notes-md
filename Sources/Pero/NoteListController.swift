import AppKit
import ImageIO
import PeroKit

enum ListRow: Equatable {
    case header(String)
    case note(NoteRecord)

    var record: NoteRecord? { if case .note(let r) = self { return r } else { return nil } }
}

/// The notes list (Notes's middle column): sections, rows, swipe actions, drag and drop.
final class NoteListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                                NSCollectionViewDataSource, NSCollectionViewDelegate {
    var library: Library
    let table = NoteTableView()
    let gallery = GalleryCollectionView()
    private let scroll = NSScrollView()
    private let galleryScroll = NSScrollView()
    private var groups: [NoteGroup] = []
    private(set) var isGallery = false
    private let emptyLabel = NSTextField(labelWithString: String(localized: "Нет заметок"))
    private(set) var rows: [ListRow] = []
    private var suppressSelection = false
    /// Shows the folder of each note (All Notes, smart folders, tags, search).
    var showsFolders = false
    var scope: Scope = .folder("")

    var onSelectionChange: ([String]) -> Void = { _ in }
    var onActivate: () -> Void = {}
    /// Double-click or Return on a gallery card.
    var onOpenFromGallery: (String) -> Void = { _ in }
    weak var actions: LibraryWindowController?

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("note"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: false)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel(String(localized: "Заметки"))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.onReturn = { [weak self] in self?.onActivate() }
        table.onDelete = { [weak self] in self?.actions?.deleteNote(nil) }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 168, height: 206)
        layout.sectionInset = NSEdgeInsets(top: 8, left: 18, bottom: 18, right: 18)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.headerReferenceSize = NSSize(width: 100, height: 30)
        gallery.collectionViewLayout = layout
        gallery.dataSource = self
        gallery.delegate = self
        gallery.isSelectable = true
        gallery.allowsMultipleSelection = true
        gallery.backgroundColors = [.clear]
        gallery.register(GalleryItem.self, forItemWithIdentifier: GalleryItem.id)
        gallery.register(GalleryHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                         withIdentifier: GalleryHeader.id)
        gallery.registerForDraggedTypes([.fileURL])
        gallery.setDraggingSourceOperationMask([.move, .copy], forLocal: false)
        gallery.onOpen = { [weak self] in
            guard let self, let path = self.selectedPaths.first else { return }
            self.onOpenFromGallery(path)
        }
        gallery.onDelete = { [weak self] in self?.actions?.deleteNote(nil) }
        gallery.menu = table.menu
        gallery.setAccessibilityLabel(String(localized: "Галерея заметок"))
        galleryScroll.documentView = gallery
        galleryScroll.hasVerticalScroller = true
        galleryScroll.autohidesScrollers = true
        galleryScroll.drawsBackground = false
        galleryScroll.isHidden = true

        let root = NSView()
        for v in [scroll, galleryScroll, emptyLabel] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            galleryScroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            galleryScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            galleryScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            galleryScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    // MARK: Content

    /// Replaces the rows, keeping the selection on the same notes where possible.
    func setGroups(_ groups: [NoteGroup], select paths: [String]? = nil, empty: String = String(localized: "Нет заметок")) {
        let keep = paths ?? selectedPaths
        self.groups = groups
        rows = groups.flatMap { g -> [ListRow] in (g.title.isEmpty ? [] : [.header(g.title)]) + g.notes.map { .note($0) } }
        suppressSelection = true
        table.reloadData()
        var indexes = IndexSet()
        for (i, row) in rows.enumerated() { if let r = row.record, keep.contains(r.path) { indexes.insert(i) } }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        gallery.reloadData()
        gallery.selectionIndexPaths = galleryIndexPaths(for: keep)
        suppressSelection = false
        emptyLabel.stringValue = empty
        emptyLabel.isHidden = !rows.isEmpty
        // The window ignores repeats, so always tell it what is selected now.
        onSelectionChange(selectedPaths)
    }

    var selectedPaths: [String] {
        table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].record?.path : nil }
    }

    var allPaths: [String] { rows.compactMap { $0.record?.path } }

    func select(_ paths: [String], scroll: Bool = true) {
        var indexes = IndexSet()
        for (i, row) in rows.enumerated() { if let r = row.record, paths.contains(r.path) { indexes.insert(i) } }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        if scroll, let first = indexes.first { table.scrollRowToVisible(first) }
        suppressSelection = true
        gallery.selectionIndexPaths = galleryIndexPaths(for: paths)
        suppressSelection = false
        onSelectionChange(selectedPaths)
    }

    // MARK: Gallery

    func setGallery(_ on: Bool) {
        isGallery = on
        galleryScroll.isHidden = !on
        scroll.isHidden = on
        gallery.reloadData()
        suppressSelection = true
        gallery.selectionIndexPaths = galleryIndexPaths(for: selectedPaths)
        suppressSelection = false
    }

    private func galleryIndexPaths(for paths: [String]) -> Set<IndexPath> {
        var out = Set<IndexPath>()
        for (s, g) in groups.enumerated() {
            for (i, r) in g.notes.enumerated() where paths.contains(r.path) { out.insert(IndexPath(item: i, section: s)) }
        }
        return out
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        groups[section].notes.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GalleryItem.id, for: indexPath) as! GalleryItem
        item.configure(groups[indexPath.section].notes[indexPath.item], library: library)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GalleryHeader.id, for: indexPath) as! GalleryHeader
        header.label.stringValue = groups[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { gallerySelectionChanged() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { gallerySelectionChanged() }

    private func gallerySelectionChanged() {
        guard !suppressSelection else { return }
        let paths = gallery.selectionIndexPaths.sorted().map { groups[$0.section].notes[$0.item].path }
        suppressSelection = true
        var indexes = IndexSet()
        for (i, row) in rows.enumerated() { if let r = row.record, paths.contains(r.path) { indexes.insert(i) } }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        suppressSelection = false
        onSelectionChange(selectedPaths)
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let record = groups[indexPath.section].notes[indexPath.item]
        guard scope != .trash else { return nil }
        let item = NSPasteboardItem()
        let paths = selectedPaths.contains(record.path) ? selectedPaths : [record.path]
        item.setData((try? JSONEncoder().encode(paths)) ?? Data(), forType: .peroNotes)
        item.setString(library.url(record.path).absoluteString, forType: .fileURL)
        return item
    }

    func selectFirst() {
        if let i = rows.firstIndex(where: { $0.record != nil }), let path = rows[i].record?.path {
            select([path])
        }
    }

    /// Redraws rows whose record changed, without touching the selection.
    func refresh(_ paths: Set<String>) {
        if isGallery { gallery.reloadData() }
        for (i, row) in rows.enumerated() {
            guard let r = row.record, paths.contains(r.path), let fresh = library.record(r.path) else { continue }
            rows[i] = .note(fresh)
            if let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? NoteCell {
                cell.configure(fresh, showFolder: showsFolders, library: library)
            }
        }
    }

    func focus() { view.window?.makeFirstResponder(isGallery ? gallery : table) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 28
        case .note: return showsFolders ? 74 : 58
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].record != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: .init("header"), owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = .init("header")
                let t = NSTextField(labelWithString: "")
                t.font = .systemFont(ofSize: 13, weight: .bold)
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                                             t.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -4)])
                return c
            }()
            cell.textField?.stringValue = title
            return cell
        case .note(let record):
            let cell = tableView.makeView(withIdentifier: .init("note"), owner: self) as? NoteCell ?? NoteCell()
            cell.identifier = .init("note")
            cell.configure(record, showFolder: showsFolders, library: library)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        onSelectionChange(selectedPaths)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, let path = rows[row].record?.path else { return }
        actions?.openInNewWindow(path)
    }

    // Swipe with two fingers: right pins, left deletes or shares (as in Notes).
    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard let record = rows[row].record, scope != .trash else { return [] }
        if edge == .leading {
            let pinned = library.isPinned(record.path)
            let pin = NSTableViewRowAction(style: .regular, title: pinned ? String(localized: "Открепить") : String(localized: "Закрепить")) { [weak self] _, _ in
                self?.library.setPinned([record.path], !pinned)
                tableView.rowActionsVisible = false
            }
            pin.backgroundColor = .systemOrange
            pin.image = NSImage(systemSymbolName: pinned ? "pin.slash.fill" : "pin.fill", accessibilityDescription: nil)
            return [pin]
        }
        let delete = NSTableViewRowAction(style: .destructive, title: String(localized: "Удалить")) { [weak self] _, _ in
            self?.actions?.deleteNotes([record.path])
        }
        delete.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: nil)
        let share = NSTableViewRowAction(style: .regular, title: String(localized: "Поделиться")) { [weak self] _, row in
            guard let self, let view = tableView.rowView(atRow: row, makeIfNecessary: false) else { return }
            self.actions?.share([record.path], from: view)
        }
        share.backgroundColor = .systemBlue
        share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        return [delete, share]
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let record = rows[row].record, scope != .trash else { return nil }
        let item = NSPasteboardItem()
        let paths = selectedPaths.contains(record.path) ? selectedPaths : [record.path]
        item.setData((try? JSONEncoder().encode(paths)) ?? Data(), forType: .peroNotes)
        // Dragged to Finder or another app: the Markdown file itself.
        item.setString(library.url(record.path).absoluteString, forType: .fileURL)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView !== table else { return [] }
        guard info.draggingPasteboard.availableType(from: [.fileURL]) != nil, case .folder = scope else {
            if scope == .quick, info.draggingPasteboard.availableType(from: [.fileURL]) != nil {
                tableView.setDropRow(-1, dropOperation: .on)
                return .copy
            }
            return []
        }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        switch scope {
        case .folder(let f): actions?.importFiles(urls, into: f, library: library)
        case .quick: actions?.importFiles(urls, into: Library.quickFolder, library: library)
        default: return false
        }
        return true
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, let record = rows[row].record else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let paths = selectedPaths
        actions?.buildNoteMenu(menu, paths: paths, clicked: record, from: table.rowView(atRow: row, makeIfNecessary: false))
    }
}

/// The list's table: Return opens the note for typing, Delete moves it to the trash.
final class NoteTableView: NSTableView {
    var onReturn: () -> Void = {}
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn()  // Return, Enter
        case 51, 117: onDelete()  // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }
}

// MARK: Cell

final class NoteCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let lock = NSImageView()
    private let thumb = NSImageView()
    private var path = ""
    private var titleAfterLock: NSLayoutConstraint!
    private var titleAtEdge: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        for field in [title, detail, folder] {
            field.maximumNumberOfLines = 1
            field.cell?.wraps = false
            field.cell?.isScrollable = false
            field.cell?.lineBreakMode = .byTruncatingTail
        }
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .tertiaryLabelColor
        folder.lineBreakMode = .byTruncatingTail
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: String(localized: "Заблокирована"))
        lock.contentTintColor = .secondaryLabelColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 5
        thumb.layer?.masksToBounds = true
        for v in [title, detail, folder, lock, thumb] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for v in [title, detail, folder] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        titleAfterLock = title.leadingAnchor.constraint(equalTo: lock.trailingAnchor, constant: 3)
        titleAtEdge = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        titleAtEdge.isActive = true
        NSLayoutConstraint.activate([
            lock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            lock.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            lock.widthAnchor.constraint(equalToConstant: 11),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: thumb.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: thumb.leadingAnchor, constant: -8),
            folder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            folder.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 3),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: thumb.leadingAnchor, constant: -8),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 40),
            thumb.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: NoteRecord, showFolder: Bool, library: Library) {
        path = r.path
        title.stringValue = r.displayTitle
        lock.isHidden = !r.isLocked
        titleAtEdge.isActive = !r.isLocked
        titleAfterLock.isActive = r.isLocked
        let preview = r.isLocked ? String(localized: "Заблокировано") : (r.preview.isEmpty ? String(localized: "Нет дополнительного текста") : r.preview)
        let date = ListDates.string(r.modified)
        let truncate = NSMutableParagraphStyle()
        truncate.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: date + "  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: truncate])
        text.append(NSAttributedString(string: preview, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: truncate]))
        detail.attributedStringValue = text
        folder.isHidden = !showFolder
        let folderName = r.folder.isEmpty ? String(localized: "Заметки") : (r.folder as NSString).lastPathComponent
        folder.stringValue = "📁 " + folderName
        thumb.image = nil
        thumb.isHidden = r.firstImage == nil || r.isLocked
        if let image = r.firstImage, !r.isLocked {
            let url = library.fileURL(for: image)
            let key = r.path
            Thumbnails.shared.thumbnail(for: url, size: 80) { [weak self] img in
                guard let self, self.path == key else { return }
                self.thumb.image = img
                self.thumb.isHidden = img == nil
            }
        }
        setAccessibilityLabel([r.displayTitle, date, preview, showFolder ? folderName : nil].compactMap { $0 }.joined(separator: ", "))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        }
    }
}

enum ListDates {
    // In the interface language's own style: «9:41» and «21.10.2026», "9:41 AM" and "10/21/26".
    private static func formatter(_ setUp: (DateFormatter) -> Void) -> DateFormatter {
        let f = DateFormatter()
        f.locale = UILanguage.locale
        setUp(f)
        return f
    }
    private static let time = formatter { $0.timeStyle = .short }
    private static let weekday = formatter { $0.dateFormat = "EEEE" }
    private static let date = formatter { $0.dateStyle = .short }

    /// Notes's list dates: time today, «Вчера», the weekday this week, then the date.
    static func string(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return time.string(from: d) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return String(localized: "Вчера") }
        if let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)), d >= week { return weekday.string(from: d) }
        return date.string(from: d)
    }
}

/// Small pictures for the list and gallery, made in the background and cached.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "pero.thumbnails", qos: .userInitiated, attributes: .concurrent)

    func thumbnail(for url: URL, size: CGFloat, done: @escaping (NSImage?) -> Void) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)|\(size)" as NSString
        if let image = cache.object(forKey: key) { return done(image) }
        queue.async {
            var image: NSImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: size * 2,
               ] as CFDictionary) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            } else if url.pathExtension.lowercased() == "svg" {
                image = NSImage(contentsOf: url)
            }
            if let image { self.cache.setObject(image, forKey: key) }
            DispatchQueue.main.async { done(image) }
        }
    }
}

// MARK: Gallery views

final class GalleryCollectionView: NSCollectionView {
    var onOpen: () -> Void = {}
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onOpen()
        case 51, 117: onDelete()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onOpen() }
    }
}

final class GalleryHeader: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("galleryHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                                     label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class GalleryItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("galleryItem")
    private let card = NSView()
    private let picture = NSImageView()
    private let snippet = NSTextField(wrappingLabelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private var path = ""

    override func loadView() {
        view = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        snippet.font = .systemFont(ofSize: 9)
        snippet.textColor = .secondaryLabelColor
        snippet.maximumNumberOfLines = 14
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        date.font = .systemFont(ofSize: 11)
        date.textColor = .secondaryLabelColor
        date.alignment = .center
        for v in [picture, snippet] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }
        for v in [card, nameLabel, date] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.heightAnchor.constraint(equalToConstant: 160),
            picture.topAnchor.constraint(equalTo: card.topAnchor),
            picture.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            snippet.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            snippet.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            snippet.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            snippet.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            date.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            date.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            date.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        updateSelection()
    }

    func configure(_ r: NoteRecord, library: Library) {
        _ = view
        path = r.path
        nameLabel.stringValue = r.displayTitle
        date.stringValue = ListDates.string(r.modified)
        snippet.stringValue = r.isLocked ? "🔒 " + String(localized: "Заблокировано") : r.title + "\n" + r.preview
        snippet.isHidden = false
        picture.image = nil
        picture.isHidden = true
        if let image = r.firstImage, !r.isLocked {
            let key = r.path
            Thumbnails.shared.thumbnail(for: library.fileURL(for: image), size: 320) { [weak self] img in
                guard let self, self.path == key, let img else { return }
                self.picture.image = img
                self.picture.isHidden = false
                self.snippet.isHidden = true
            }
        }
        view.setAccessibilityLabel(r.displayTitle + ", " + date.stringValue)
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        card.layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        card.layer?.borderWidth = isSelected ? 3 : 1
    }
}
