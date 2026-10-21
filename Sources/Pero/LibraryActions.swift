import AppKit
import PeroKit
import UniformTypeIdentifiers

/// Menu and toolbar commands of the main window.
extension LibraryWindowController: NSServicesMenuRequestor {
    // MARK: New

    /// The folder new notes go to: the selected folder, or «Заметки».
    var targetFolder: String {
        switch scope {
        case .folder(let f): return f
        case .quick: return Library.quickFolder
        default: return ""
        }
    }

    @objc func newNote(_ sender: Any?) {
        createNote(text: Settings.newNotePrefix, focus: true)
    }

    func createNote(text: String, in folder: String? = nil, focus: Bool) {
        session?.saveNow()
        do {
            let path = try library.createNote(in: folder ?? targetFolder, text: text)
            if Settings.galleryView { openFromGallery(path) }
            reveal(path)
            if session?.path == path { session?.discardIfEmpty = true }
            if focus {
                editor.focusText()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.editor.reveal((text as NSString).length) }
            }
        } catch { showError(error) }
    }

    @objc func newQuickNote(_ sender: Any?) {
        QuickNotePanel.shared.show(library: libraries.main)
    }

    @objc func newFolder(_ sender: Any?) {
        createFolder(in: "")
    }

    func createFolder(in parent: String, library other: Library? = nil) {
        if let other { switchLibrary(to: other) }
        guard let path = try? library.createFolder(named: "Новая папка", in: parent) else { return NSSound.beep() }
        showScope(.folder(path))
        DispatchQueue.main.async { self.sidebar.beginRename() }
    }

    @objc func newSmartFolder(_ sender: Any?) {
        guard let window else { return }
        SmartFolderEditor.present(on: window, library: library, folder: nil) { [weak self] smart in
            self?.library.addSmartFolder(smart)
            self?.showScope(.smart(smart.id))
        }
    }

    func editSmartFolder(_ id: String, library other: Library? = nil) {
        if let other { switchLibrary(to: other) }
        guard let window, let smart = library.state.smartFolders.first(where: { $0.id == id }) else { return }
        SmartFolderEditor.present(on: window, library: library, folder: smart) { [weak self] edited in
            self?.library.updateSmartFolder(edited)
        }
    }

    // MARK: Delete, move, pin

    @objc func deleteNote(_ sender: Any?) {
        let paths = list.selectedPaths
        guard !paths.isEmpty else { return NSSound.beep() }
        if scope == .trash { return deleteForever(paths) }
        deleteNotes(paths)
    }

    func deleteNotes(_ paths: [String]) {
        let next = nextSelection(after: paths)
        if let s = session, paths.contains(s.path) { s.saveNow() }
        do {
            let ids = try library.trash(paths)
            window?.undoManager?.registerUndo(withTarget: self) { target in
                _ = try? target.library.restore(ids)
                target.reloadList(select: paths)
            }
            window?.undoManager?.setActionName(paths.count == 1 ? "удаление заметки" : "удаление заметок")
            if let next { list.select([next]) }
        } catch { showError(error) }
    }

    private func nextSelection(after paths: [String]) -> String? {
        let all = list.allPaths
        guard let last = paths.compactMap({ all.firstIndex(of: $0) }).max() else { return nil }
        let after = all[(last + 1)...].first { !paths.contains($0) }
        return after ?? all[..<last].last { !paths.contains($0) }
    }

    private func deleteForever(_ paths: [String]) {
        let ids = paths.compactMap { p in library.trash.first { library.trashRecords[$0.id]?.path == p }?.id }
        guard !ids.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Удалить заметку навсегда?" : "Удалить \(ids.count) \(Plural.notesGenitive(ids.count)) навсегда?"
        alert.informativeText = "Это действие нельзя отменить."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отменить")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.library.deleteForever(ids)
        }
    }

    func emptyTrash(_ other: Library? = nil) {
        let library = other ?? self.library
        guard let window, !library.trash.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить все заметки из «Недавно удалённых» навсегда?"
        alert.informativeText = "Это действие нельзя отменить."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отменить")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            library.deleteForever(library.trash.map(\.id))
        }
    }

    @objc func restoreNote(_ sender: Any?) {
        let ids = list.selectedPaths.compactMap { p in library.trash.first { library.trashRecords[$0.id]?.path == p }?.id }
        let folder = (sender as? NSMenuItem)?.representedObject as? String
        do {
            let restored = try library.restore(ids, to: folder)
            if let first = restored.first { reveal(first) }
        } catch { showError(error) }
    }

    @objc func moveToFolder(_ sender: NSMenuItem) {
        // A folder of this library, or ["root": …, "folder": …] for another one.
        if let target = sender.representedObject as? [String: String], let root = target["root"],
           let other = libraries.library(withRoot: root) {
            return moveNotes(list.selectedPaths, to: target["folder"] ?? "", library: other)
        }
        guard let folder = sender.representedObject as? String else { return }
        if scope == .trash { return restoreNote(sender) }
        moveNotes(list.selectedPaths, to: folder)
    }

    func moveNotes(_ paths: [String], to folder: String, library target: Library? = nil) {
        if let s = session, paths.contains(s.path) { s.saveNow() }
        if let target, target !== library {
            // Into another library: the files (and their pictures) are copied over and the
            // originals go to «Недавно удалённые» here.
            closeSession()
            lastSelection = []
            do { _ = try library.transfer(paths, to: target, folder: folder) } catch { showError(error) }
            return
        }
        do {
            let moves = try library.move(paths, to: folder)
            guard !moves.isEmpty else { return }
            let back = Dictionary(grouping: moves, by: { ($0.key as NSString).deletingLastPathComponent })
            window?.undoManager?.registerUndo(withTarget: self) { target in
                for (origin, pairs) in back { _ = try? target.library.move(pairs.map(\.value), to: origin) }
            }
            window?.undoManager?.setActionName("перемещение")
        } catch { showError(error) }
    }

    func moveFolder(_ path: String, into parent: String, library other: Library? = nil) {
        let target = other ?? library
        do {
            let new = try target.moveFolder(path, into: parent)
            if target === library, scope == .folder(path) { showScope(.folder(new)) }
        } catch { showError(error) }
    }

    func deleteFolder(_ path: String, library other: Library? = nil) {
        if let other { switchLibrary(to: other) }
        guard let window else { return }
        let count = library.notes.values.filter { $0.folder == path || $0.folder.hasPrefix(path + "/") }.count
        let alert = NSAlert()
        alert.messageText = "Удалить папку «\((path as NSString).lastPathComponent)»?"
        alert.informativeText = count == 0 ? "Папка пуста." : "\(count) \(Plural.notes(count)) из неё и вложенных папок переместятся в «Недавно удалённые»."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отменить")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if let s = self.session, s.path.hasPrefix(path + "/") { s.saveNow() }
            do {
                try self.library.deleteFolder(path)
                if self.scope == .folder(path) { self.showScope(.folder("")) }
            } catch { self.showError(error) }
        }
    }

    func convertToSmartFolder(_ path: String, library other: Library? = nil) {
        if let other { switchLibrary(to: other) }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Преобразовать «\((path as NSString).lastPathComponent)» в смарт-папку?"
        alert.informativeText = "Заметки переместятся в папку «Заметки» и получат тег с названием этой папки. Это действие нельзя отменить."
        alert.addButton(withTitle: "Преобразовать")
        alert.addButton(withTitle: "Отменить")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                let smart = try self.library.convertToSmartFolder(path)
                self.showScope(.smart(smart.id))
            } catch {
                self.showMessage("Эту папку нельзя преобразовать",
                                 "Нельзя преобразовать папку с вложенными папками или заблокированными заметками.")
            }
        }
    }

    @objc func pinNote(_ sender: Any?) {
        let paths = list.selectedPaths
        guard !paths.isEmpty else { return }
        let pin = !paths.allSatisfy { library.isPinned($0) }
        library.setPinned(paths, pin)
        window?.undoManager?.registerUndo(withTarget: self) { $0.library.setPinned(paths, !pin) }
    }

    @objc func duplicateNote(_ sender: Any?) {
        guard let path = list.selectedPaths.first else { return }
        session?.saveNow()
        do { reveal(try library.duplicate(path)) } catch { showError(error) }
    }

    // MARK: Tags

    func renameTag(_ tag: String) {
        guard let window else { return }
        TextPrompt.ask(on: window, title: "Переименовать тег #\(tag)", message: "Тег изменится во всех заметках.",
                       value: tag, confirm: "Переименовать") { [weak self] name in
            guard let self else { return }
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).replacingOccurrences(of: " ", with: "_")
            guard !clean.isEmpty, clean != tag else { return }
            self.session?.saveNow()
            do {
                try self.library.replaceTag(tag, with: clean)
                if self.scope == .tags([tag]) { self.showScope(.tags([clean])) }
            } catch { self.showError(error) }
        }
    }

    func deleteTag(_ tag: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить тег #\(tag)?"
        alert.informativeText = "Тег уберётся из текста всех заметок. Сами заметки останутся."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отменить")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.session?.saveNow()
            do {
                try self.library.replaceTag(tag, with: nil)
                if case .tags = self.scope { self.showScope(.folder("")) }
            } catch { self.showError(error) }
        }
    }

    // MARK: Locking

    @objc func lockNote(_ sender: Any?) {
        guard let path = list.selectedPaths.first, let record = library.record(path), let window else { return }
        if record.isLocked {
            guard let master = lock.master else { return showMessage("Сначала откройте заметку", "Введите пароль для заметок, чтобы снять с неё защиту.") }
            closeSession(for: path)
            do { reveal(try library.removeLock(path, master: master)) } catch { showError(error) }
            return
        }
        // The same limits as in Notes.
        if record.isQuickNote { return showMessage("Быструю заметку нельзя заблокировать", "Переместите её в другую папку, а потом заблокируйте.") }
        if !record.tags.isEmpty { return showMessage("Заметку с тегами нельзя заблокировать", "Уберите теги из заметки, а потом заблокируйте её.") }
        if !record.flags.isDisjoint(with: [.pdfs, .documents, .audio, .scans, .images, .sketches]) {
            return showMessage("Заметку с вложениями пока нельзя заблокировать",
                               "Шифруется только текст заметки. Уберите из неё картинки и файлы, а потом заблокируйте.")
        }
        let proceed = { [weak self] in
            guard let self, let master = self.lock.master else { return }
            let open = self.session?.path == path ? self.session : nil
            self.closeSession(for: path)
            let current = open?.path ?? path  // finishing may have renamed the file after its title
            guard self.library.record(current) != nil else { return self.showError(CocoaError(.fileNoSuchFile)) }
            do { self.reveal(try self.library.lock(current, master: master)) } catch { self.showError(error) }
        }
        if !lock.hasPassword {
            PasswordSheet.create(on: window) { [weak self] password, hint in
                do { try self?.lock.setPassword(password, hint: hint); proceed() } catch { self?.showError(error) }
            }
        } else if !lock.isUnlocked {
            PasswordSheet.enter(on: window, hint: lock.hint) { [weak self] password in
                guard let self else { return false }
                guard self.lock.unlock(password: password) else { return false }
                proceed()
                return true
            }
        } else {
            proceed()
        }
    }

    // MARK: Attachments

    /// Saves a file into the library and returns the Markdown that shows it in the current note.
    func attach(data: Data, name: String) -> String? {
        guard let folder = session.map({ ($0.path as NSString).deletingLastPathComponent }) else { return nil }
        do {
            let path = try library.addAttachment(data: data, name: name)
            let target = library.linkTarget(to: path, fromFolder: folder)
            let label = (name as NSString).deletingPathExtension.replacingOccurrences(of: "]", with: "")
            if FileTypes.isImage(path) {
                return "![\(label)](\(target))"
            }
            return "[\(name.replacingOccurrences(of: "]", with: ""))](\(target))"
        } catch {
            showError(error)
            return nil
        }
    }

    @objc func attachFile(_ sender: Any?) {
        guard editorActiveForCommands, let window else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Прикрепить"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let parts = panel.urls.compactMap { url in (try? Data(contentsOf: url)).flatMap { self.attach(data: $0, name: url.lastPathComponent) } }
            if !parts.isEmpty { self.editor.insert(parts.joined(separator: "\n") + "\n") }
        }
    }

    var editorActiveForCommands: Bool { session != nil && !(session?.isTrash ?? true) }

    @objc func insertFromDevice(_ sender: Any?) {}

    // Continuity Camera: photos, scans and sketches from an iPhone or iPad.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, editorActiveForCommands,
           [.tiff, .png, .pdf, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")].contains(returnType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let stamp = Self.stampFormatter.string(from: Date())
        if let pdf = pasteboard.data(forType: .pdf), let md = attach(data: pdf, name: "Скан \(stamp).pdf") {
            editor.insert(md + "\n")
            return true
        }
        for (type, ext) in [(NSPasteboard.PasteboardType("public.jpeg"), "jpg"), (.png, "png"), (NSPasteboard.PasteboardType("public.heic"), "heic")] {
            if let data = pasteboard.data(forType: type), let md = attach(data: data, name: "Фото \(stamp).\(ext)") {
                editor.insert(md + "\n")
                return true
            }
        }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]), let md = attach(data: png, name: "Рисунок \(stamp).png") {
            editor.insert(md + "\n")
            return true
        }
        return false
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy HH-mm-ss"
        return f
    }()

    // MARK: Links and clipboard

    @objc func insertLink(_ sender: Any?) {
        guard editorActiveForCommands, let window else { return NSSound.beep() }
        editor.linkContext { text, url in
            LinkSheet.present(on: window, text: text, url: url) { [weak self] text, url in
                self?.editor.run("applyLink", arg: ["text": text, "url": url])
            }
        }
    }

    @objc func copyAsMarkdown(_ sender: Any?) {
        editor.selectedText { text in
            guard !text.isEmpty else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        guard editorActiveForCommands, let text = NSPasteboard.general.string(forType: .string) else { return NSSound.beep() }
        editor.insert(text)
    }

    // MARK: Windows and sharing

    @objc func openNoteInNewWindow(_ sender: Any?) {
        guard let path = list.selectedPaths.first else { return }
        openInNewWindow(path)
    }

    func openInNewWindow(_ path: String) {
        guard let record = library.record(path), !record.isLocked || lock.isUnlocked else { return NSSound.beep() }
        session?.saveNow()
        NoteWindowController.open(path: path, library: library, lock: lock)
    }

    func openFromGallery(_ path: String) {
        list.select([path])
        galleryNoteOpen(true)
    }

    func share(_ paths: [String], from view: NSView) {
        session?.saveNow()
        let urls = paths.compactMap { library.record($0) }.filter { !$0.isLocked }.map { library.url($0.path) }
        guard !urls.isEmpty else { return NSSound.beep() }
        NSSharingServicePicker(items: urls).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    // MARK: Export and print

    @objc func printNote(_ sender: Any?) {
        guard let s = session else { return NSSound.beep() }
        s.saveNow()
        Exporter.print(s.buffer.text, title: s.exportTitle, baseDir: s.baseDirectory, editor: editor, window: window)
    }

    @objc func exportNotes(_ sender: NSMenuItem) {
        guard let format = (sender.representedObject as? String).flatMap(ExportFormat.init(rawValue:)), let window else { return }
        session?.saveNow()
        let records = list.selectedPaths.compactMap { library.record($0) }.filter { !$0.isLocked }
        guard !records.isEmpty else { return showMessage("Нечего экспортировать", "Заблокированные заметки не экспортируются.") }
        if records.count == 1 {
            let r = records[0]
            Exporter.ask(for: format.type, base: FileNames.baseName(forTitle: r.displayTitle), directory: nil, window: window) { url in
                LibraryExport(library: self.library, editor: self.editor).export(r, as: format, to: url) { error in
                    if let error { self.showError(error) }
                }
            }
        } else {
            chooseFolder(prompt: "Экспортировать") { dir in
                LibraryExport(library: self.library, editor: self.editor).exportMany(records, as: format, into: dir) { error in
                    if let error { self.showError(error) } else { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                }
            }
        }
    }

    func exportFolder(_ path: String, library other: Library? = nil) {
        if let other { switchLibrary(to: other) }
        session?.saveNow()
        let records = library.notes.values.filter { !$0.isLocked && ($0.folder == path || path.isEmpty || $0.folder.hasPrefix(path + "/")) }
        chooseFolder(prompt: "Экспортировать") { dir in
            let name = path.isEmpty ? "Заметки" : (path as NSString).lastPathComponent
            let target = FileNames.unique(name, ext: "", in: dir)
            LibraryExport(library: self.library, editor: self.editor)
                .exportTree(Array(records), base: path, into: target) { error in
                    if let error { self.showError(error) } else { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                }
        }
    }

    @objc func exportLibrary(_ sender: Any?) { exportFolder("") }

    private func chooseFolder(prompt: String, then: @escaping (URL) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { then(url) }
        }
    }

    // MARK: Menus

    /// Folders to move notes to: this library's, then (unless restoring from the trash)
    /// the other libraries' under their names.
    func folderMenu(action: Selector, otherLibraries: Bool = true) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ represented: Any, symbol: String = "folder", depth: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = represented
            item.indentationLevel = depth
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        func folders(of lib: Library, represent: (String) -> Any, depthOffset: Int) {
            let isMain = lib === libraries.main
            for folder in lib.folders where !isMain || (folder != Library.quickFolder && !folder.hasPrefix(Library.quickFolder + "/")) {
                add((folder as NSString).lastPathComponent, represent(folder), depth: folder.components(separatedBy: "/").count - 1 + depthOffset)
            }
        }
        let isMain = library === libraries.main
        add(isMain ? "Заметки" : library.root.lastPathComponent, "", symbol: isMain ? "folder" : "folder.fill")
        if isMain { add("Быстрые заметки", Library.quickFolder, symbol: "note.text") }
        folders(of: library, represent: { $0 }, depthOffset: 0)
        guard otherLibraries else { return menu }
        for other in libraries.all where other !== library {
            menu.addItem(.separator())
            let root = other.root.path
            let otherIsMain = other === libraries.main
            add(otherIsMain ? "Заметки (На Mac)" : other.root.lastPathComponent, ["root": root, "folder": ""],
                symbol: otherIsMain ? "folder" : "folder.fill")
            folders(of: other, represent: { ["root": root, "folder": $0] }, depthOffset: 1)
        }
        return menu
    }

    func buildNoteMenu(_ menu: NSMenu, paths: [String], clicked: NoteRecord, from view: NSView?) {
        func item(_ title: String, _ action: Selector, _ represented: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = represented
            return i
        }
        if scope == .trash {
            let restore = NSMenuItem(title: "Восстановить", action: #selector(restoreNote(_:)), keyEquivalent: "")
            restore.target = self
            menu.addItem(restore)
            let move = NSMenuItem(title: "Переместить в", action: nil, keyEquivalent: "")
            move.submenu = folderMenu(action: #selector(moveToFolder(_:)), otherLibraries: false)
            move.submenu?.items.forEach { $0.target = self }
            menu.addItem(move)
            menu.addItem(.separator())
            menu.addItem(item("Удалить навсегда…", #selector(deleteNote(_:))))
            return
        }
        let pinned = paths.allSatisfy { library.isPinned($0) }
        menu.addItem(item(pinned ? "Открепить заметку" : "Закрепить заметку", #selector(pinNote(_:))))
        if paths.count == 1 {
            menu.addItem(item(clicked.isLocked ? "Снять защиту" : "Заблокировать заметку", #selector(lockNote(_:))))
        }
        let move = NSMenuItem(title: "Переместить в", action: nil, keyEquivalent: "")
        move.submenu = folderMenu(action: #selector(moveToFolder(_:)))
        move.submenu?.items.forEach { $0.target = self }
        menu.addItem(move)
        menu.addItem(.separator())
        if paths.count == 1 {
            menu.addItem(item("Дублировать", #selector(duplicateNote(_:))))
            menu.addItem(item("Открыть в новом окне", #selector(openNoteInNewWindow(_:))))
        }
        let shareItem = ClosureMenuItem(title: "Поделиться…") { [weak self] in
            guard let self, let view = view ?? self.window?.contentView else { return }
            self.share(paths, from: view)
        }
        menu.addItem(shareItem)
        let export = NSMenuItem(title: "Экспортировать как", action: nil, keyEquivalent: "")
        export.submenu = MainMenu.exportMenu()
        export.submenu?.items.forEach { $0.target = self }
        menu.addItem(export)
        menu.addItem(item("Показать в Finder", #selector(revealInFinder(_:))))
        menu.addItem(.separator())
        menu.addItem(item(paths.count == 1 ? "Удалить заметку" : "Удалить заметки", #selector(deleteNote(_:))))
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(list.selectedPaths.map { library.url($0) })
    }

    @objc func moveMenuPlaceholder(_ sender: Any?) {}

    // MARK: Gallery

    func galleryNoteOpen(_ open: Bool) {
        guard Settings.galleryView else { return }
        let items = split.splitViewItems
        NSAnimationContext.runAnimationGroup { _ in
            items[1].animator().isCollapsed = open
            items[2].animator().isCollapsed = !open
        }
        if open { editor.focusText() } else { list.focus() }
    }
}

enum ExportFormat: String {
    case pdf, markdown, html, text

    var type: UTType {
        switch self {
        case .pdf: return .pdf
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .html: return .html
        case .text: return .plainText
        }
    }

    var ext: String {
        switch self {
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .html: return "html"
        case .text: return "txt"
        }
    }
}

// MARK: Folders from the disk

extension LibraryWindowController {
    /// «Подключить папку с диска»: any folder with Markdown files shows up in the sidebar;
    /// its files are read and edited where they are.
    @objc func linkFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Подключить"
        panel.message = "Папка с Markdown-файлами. Они появятся как заметки и будут правиться на месте; служебные файлы в неё не попадут."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.link(url)
        }
    }

    func link(_ url: URL) {
        do {
            let library = try libraries.link(url)
            library.rescan { [weak self] in self?.showScope(.folder(""), in: library) }
        } catch { showError(error) }
    }

    func unlinkFolder(_ library: Library) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Отключить папку «\(library.root.lastPathComponent)»?"
        alert.informativeText = "Файлы в ней останутся на месте, папка просто пропадёт из боковой панели. Подключить её снова можно в любой момент."
        alert.addButton(withTitle: "Отключить")
        alert.addButton(withTitle: "Отменить")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.unlink(library)
        }
    }

    func unlink(_ library: Library) {
        if library === self.library { closeSession() }
        SessionStore.shared.saveAll()
        libraries.unlink(library)
        // Перо's index for it is a cache; notes deleted from it stay until the trash is emptied.
        if library.trash.isEmpty { try? FileManager.default.removeItem(at: library.meta) }
    }
}
