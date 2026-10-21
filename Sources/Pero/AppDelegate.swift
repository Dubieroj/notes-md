import AppKit
import CoreSpotlight
import PeroKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var libraries: Libraries?
    /// The main library (folders linked from the disk are in `libraries`).
    var library: Library? { libraries?.main }
    private(set) var lock: LockManager?
    private(set) var main: LibraryWindowController?
    private var hotKey: HotKey?
    private var spotlight: SpotlightIndexer?
    private var widgets: WidgetPublisher?
    private var inbox: InboxReader?
    private var openedFiles = false
    private var dailyTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        #if PERO_TEST_HOOKS
        TestHooks.startIfRequested()
        #endif
        openLibrary()
    }

    private func openLibrary() {
        let url = Settings.libraryURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            UILanguage.setUp(libraryRoot: url)
            let library = try Library(root: url)
            libraries = Libraries(main: library)
            let lock = LockManager(library: library)
            self.lock = lock
            main = LibraryWindowController(libraries: libraries!, lock: lock)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Не удалось открыть библиотеку заметок в \(url.path)")
            alert.runModal()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard library != nil else { return }
        // Opened to edit a Markdown file from Finder: only that window shows up.
        if !openedFiles { main?.showWindow(nil) }
        startServices()
        updateHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.libraries?.all.forEach { $0.purgeExpiredTrash() }
            if let library = self.library { Backup.runIfDue(library: library) }
        }
        if let library { Backup.runIfDue(library: library) }
        main?.updateDockBadge()
    }

    /// Spotlight, widgets and the «Поделиться» inbox work with the main library.
    private func startServices() {
        guard let library else { return }
        libraries?.all.forEach { $0.purgeExpiredTrash() }
        // Test libraries stay out of Spotlight.
        guard !Settings.isTesting else { return }
        spotlight = SpotlightIndexer(library: library)
        widgets = WidgetPublisher(library: library)
        inbox = InboxReader(library: library)
    }

    @objc private func settingsChanged() { updateHotKey() }

    private func updateHotKey() {
        if Settings.quickNoteShortcut, hotKey == nil {
            hotKey = HotKey { [weak self] in
                if let library = self?.library { QuickNotePanel.shared.show(library: library) }
            }
        } else if !Settings.quickNoteShortcut {
            hotKey = nil
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { main?.showWindow(nil) }
        return true
    }

    /// Markdown files from Finder: notes of the library or of a linked folder open in
    /// the main window, any other file in a window of its own, as before.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "pero" { handlePeroURL(url) }
        let urls = urls.filter(\.isFileURL)
        if !urls.isEmpty { openedFiles = true }
        for url in urls {
            if let main, let (library, path) = libraries?.locate(url) {
                main.showWindow(nil)
                main.reveal(path, in: library)
                continue
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.shared.saveAll()
        libraries?.all.forEach { $0.flush() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // A note picked in Spotlight.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let path = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let library else { return false }
        main?.showWindow(nil)
        main?.reveal(path, in: library)
        return true
    }

    // MARK: The library folder

    /// Settings ▸ «Выбрать папку для библиотеки…»: move the notes there, or open what is there.
    func chooseLibraryFolder() {
        guard let current = library else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Выбрать")
        panel.message = String(localized: "Папка, где будут храниться заметки. Можно перенести туда нынешние или открыть папку, где Markdown-файлы уже есть.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let picked = url.resolvingSymlinksInPath().path, root = current.root.resolvingSymlinksInPath().path
        if picked == root { return }
        if picked.hasPrefix(root + "/") || root.hasPrefix(picked + "/") {
            let alert = NSAlert()
            alert.messageText = String(localized: "Эта папка пересекается с библиотекой")
            alert.informativeText = String(localized: "Выберите папку вне нынешней библиотеки и не ту, в которой она лежит.")
            alert.runModal()
            return
        }
        let fm = FileManager.default
        let contents = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
        let alert = NSAlert()
        if contents.isEmpty {
            alert.messageText = String(localized: "Перенести заметки в «\(url.lastPathComponent)»?")
            alert.informativeText = String(localized: "Заметки, вложения и настройки библиотеки скопируются в новую папку. Прежняя папка останется на месте как есть.")
            alert.addButton(withTitle: String(localized: "Перенести заметки"))
            alert.addButton(withTitle: String(localized: "Начать с пустой"))
            alert.addButton(withTitle: String(localized: "Отменить"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: switchLibrary(to: url, copyNotes: true)
            case .alertSecondButtonReturn: switchLibrary(to: url, copyNotes: false)
            default: return
            }
        } else {
            alert.messageText = String(localized: "Открыть «\(url.lastPathComponent)» как библиотеку?")
            alert.informativeText = String(localized: "В папке уже есть файлы: Markdown-файлы из неё станут заметками, а подпапки — папками. Нынешние заметки останутся в прежней папке.")
            alert.addButton(withTitle: String(localized: "Открыть как библиотеку"))
            alert.addButton(withTitle: String(localized: "Отменить"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            switchLibrary(to: url, copyNotes: false)
        }
    }

    /// Switches the main library to another folder right away, no restart.
    func switchLibrary(to url: URL, copyNotes: Bool) {
        guard let libraries, let old = library else { return }
        SessionStore.shared.saveAll()
        old.flush()
        do {
            if copyNotes {
                let fm = FileManager.default
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                for name in try fm.contentsOfDirectory(atPath: old.root.path) where name != ".DS_Store" {
                    try fm.copyItem(at: old.root.appendingPathComponent(name), to: url.appendingPathComponent(name))
                }
            }
            UILanguage.setUp(libraryRoot: url)
            let new = try Library(root: url)
            main?.window?.close()
            SettingsWindowController.reset()
            libraries.replaceMain(new)
            Settings.setLibraryURL(url)
            lock = LockManager(library: new)
            main = LibraryWindowController(libraries: libraries, lock: lock!)
            main?.showWindow(nil)
            startServices()
            new.rescan { [weak self] in self?.main?.reloadList(selectFirst: true) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Menu actions without a window

    @objc func showMainWindow(_ sender: Any?) { main?.showWindow(nil) }

    @objc func showSettings(_ sender: Any?) {
        guard let library, let lock else { return }
        SettingsWindowController.show(library: library, lock: lock)
    }

    @objc func newQuickNote(_ sender: Any?) {
        guard let library else { return }
        QuickNotePanel.shared.show(library: library)
    }

    @objc func newNote(_ sender: Any?) {
        main?.showWindow(nil)
        main?.newNote(sender)
    }

    @objc func linkFolder(_ sender: Any?) {
        main?.showWindow(nil)
        main?.linkFolder(sender)
    }

    @objc func rebuildIndex(_ sender: Any?) {
        libraries?.all.forEach { $0.rescan() }
        spotlight?.reindexAll()
    }

    /// "Open Folder…" with no window open: start a blank document and ask there.
    @objc func openFolder(_ sender: Any?) {
        guard let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true),
              let controller = document.windowControllers.first as? EditorWindowController else { return }
        controller.openFolder(sender)
    }
}

/// Notes in Spotlight: title, text without markup, tags. Locked notes show only the title.
final class SpotlightIndexer {
    private let library: Library
    private var pending = Set<String>()
    private var removed = Set<String>()
    private var work: DispatchWorkItem?
    private let index = CSSearchableIndex(name: "Pero")

    init(library: Library) {
        self.library = library
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: Library.didChange, object: library)
        let key = "spotlightIndexed:" + library.root.path
        if !UserDefaults.standard.bool(forKey: key) {
            reindexAll()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    func reindexAll() {
        index.deleteAllSearchableItems { _ in
            DispatchQueue.main.async {
                self.pending = Set(self.library.notes.keys)
                self.flush()
            }
        }
    }

    @objc private func changed(_ note: Notification) {
        let info = note.userInfo ?? [:]
        pending.formUnion(info["changed"] as? [String] ?? [])
        removed.formUnion(info["removed"] as? [String] ?? [])
        for (from, to) in info["moved"] as? [String: String] ?? [:] { removed.insert(from); pending.insert(to) }
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func flush() {
        let gone = Array(removed.subtracting(pending))
        if !gone.isEmpty { index.deleteSearchableItems(withIdentifiers: gone) }
        let records = pending.compactMap { library.record($0) }
        pending.removeAll()
        removed.removeAll()
        let root = library.root
        DispatchQueue.global(qos: .utility).async { [index] in
            let items = records.map { r -> CSSearchableItem in
                let attrs = CSSearchableItemAttributeSet(contentType: .text)
                attrs.title = r.displayTitle
                attrs.contentModificationDate = r.modified
                attrs.contentCreationDate = r.created
                attrs.keywords = r.tags
                if !r.isLocked {
                    attrs.contentDescription = r.preview
                    if let data = try? Data(contentsOf: root.appendingPathComponent(r.path)),
                       let text = try? TextCodec.decode(data).text {
                        attrs.textContent = String(NoteParser.parse(text).plainText.prefix(50_000))
                    }
                }
                return CSSearchableItem(uniqueIdentifier: r.path, domainIdentifier: r.folder.isEmpty ? "Заметки" : r.folder, attributeSet: attrs)
            }
            if !items.isEmpty { index.indexSearchableItems(items) }
        }
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String.LocalizationValue, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, command: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = command
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Заметки.md"))
        menu.addItem(item("О программе «Заметки.md»", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Настройки…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Службы"))
        menu.addItem(submenu(services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Скрыть «Заметки.md»", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Скрыть остальные", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Показать все", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Завершить «Заметки.md»", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Файл"))
        menu.addItem(item("Новая заметка", #selector(AppDelegate.newNote(_:)), "n"))
        menu.addItem(item("Новая папка", #selector(LibraryWindowController.newFolder(_:)), "n", [.command, .shift]))
        menu.addItem(item("Новая смарт-папка…", #selector(LibraryWindowController.newSmartFolder(_:))))
        menu.addItem(item("Быстрая заметка", #selector(AppDelegate.newQuickNote(_:)), "n", [.command, .option, .control]))
        menu.addItem(item("Подключить папку с диска…", #selector(AppDelegate.linkFolder(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Открыть файл Markdown…", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: String(localized: "Открыть недавние"))
        recent.addItem(item("Очистить меню", #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(submenu(recent))
        menu.addItem(item("Открыть папку…", #selector(EditorWindowController.openFolder(_:)), "o", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Закрыть", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Сохранить", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Дублировать", #selector(LibraryWindowController.duplicateNote(_:)), "d"))
        menu.addItem(.separator())
        menu.addItem(item("Импортировать в Заметки.md…", #selector(LibraryWindowController.importDialog(_:))))
        menu.addItem(item("Импорт из «Заметок» Apple…", #selector(LibraryWindowController.importAppleNotes(_:))))
        let export = NSMenuItem(title: String(localized: "Экспортировать как"), action: nil, keyEquivalent: "")
        export.submenu = exportMenu()
        menu.addItem(export)
        menu.addItem(item("Экспортировать всю библиотеку…", #selector(LibraryWindowController.exportLibrary(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Закрепить заметку", #selector(LibraryWindowController.pinNote(_:))))
        menu.addItem(item("Заблокировать заметку", #selector(LibraryWindowController.lockNote(_:))))
        menu.addItem(item("Закрыть заблокированные заметки", #selector(LibraryWindowController.closeLockedNotes(_:))))
        menu.addItem(item("Открыть в новом окне", #selector(LibraryWindowController.openNoteInNewWindow(_:))))
        menu.addItem(item("Показать в Finder", #selector(LibraryWindowController.revealInFinder(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Прикрепить файл…", #selector(LibraryWindowController.attachFile(_:)), "a", [.command, .shift]))
        // AppKit fills this with Take Photo / Scan Documents / Add Sketch for a nearby iPhone or iPad.
        let device = NSMenuItem(title: String(localized: "Вставить с iPhone или iPad"), action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(device)
        menu.addItem(.separator())
        menu.addItem(item("Напечатать…", #selector(LibraryWindowController.printNote(_:)), "p"))
        return menu
    }

    static func exportMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Экспортировать как"))
        for (title, format): (String.LocalizationValue, String) in [("PDF…", "pdf"), ("Markdown…", "markdown"), ("HTML…", "html"), ("Текст…", "text")] {
            menu.addItem(item(title, #selector(LibraryWindowController.exportNotes(_:)), command: format))
        }
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Правка"))
        // «Отменить» is also Cancel on dialog buttons (and «Повторить» could be Retry): Undo and Redo have keys of their own.
        menu.addItem(NSMenuItem(title: String(localized: "menu.undo", defaultValue: "Отменить"),
                                action: #selector(LibraryWindowController.peroUndo(_:)), keyEquivalent: "z"))
        let redo = NSMenuItem(title: String(localized: "menu.redo", defaultValue: "Повторить"),
                              action: #selector(LibraryWindowController.peroRedo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(item("Вырезать", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Скопировать", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Скопировать как Markdown", #selector(LibraryWindowController.copyAsMarkdown(_:))))
        menu.addItem(item("Вставить", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Вставить и согласовать стиль", #selector(LibraryWindowController.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Выбрать всё", #selector(LibraryWindowController.peroSelectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Добавить ссылку…", #selector(LibraryWindowController.insertLink(_:)), "k"))
        menu.addItem(.separator())
        menu.addItem(item("Найти в заметке…", #selector(LibraryWindowController.peroFind(_:)), "f"))
        menu.addItem(item("Искать во всех заметках", #selector(LibraryWindowController.searchAllNotes(_:)), "f", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Удалить заметку", #selector(LibraryWindowController.deleteNote(_:)), "\u{8}"))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Формат"))
        for i in paragraphStyles() { menu.addItem(i) }
        menu.addItem(.separator())
        let action = #selector(LibraryWindowController.format(_:))
        menu.addItem(item("Чек-лист", action, "l", [.command, .shift], command: "checklist"))
        menu.addItem(item("Отметить пункт", action, "u", [.command, .shift], command: "toggleCheck"))
        let more = NSMenu(title: String(localized: "Ещё о чек-листах"))
        more.addItem(item("Отметить все", action, command: "checkAll"))
        more.addItem(item("Снять все отметки", action, command: "uncheckAll"))
        more.addItem(item("Переместить отмеченные вниз", action, command: "moveCheckedDown"))
        more.addItem(item("Удалить отмеченные", action, command: "deleteChecked"))
        menu.addItem(submenu(more))
        menu.addItem(.separator())
        menu.addItem(item("Таблица", action, "t", [.command, .option], command: "table"))
        menu.addItem(item("Разделитель", action, "l", command: "divider"))
        menu.addItem(.separator())
        let font = NSMenu(title: String(localized: "Шрифт"))
        font.addItem(item("Жирный", action, "b", command: "bold"))
        font.addItem(item("Курсив", action, "i", command: "italic"))
        font.addItem(item("Подчёркнутый", action, "u", command: "underline"))
        font.addItem(item("Зачёркнутый", action, "x", [.command, .shift], command: "strike"))
        font.addItem(item("Выделение", action, "e", [.command, .shift], command: "highlight"))
        font.addItem(item("Код в строке", action, command: "code"))
        menu.addItem(submenu(font))
        let headings = NSMenu(title: String(localized: "Заголовки Markdown"))
        for level in 1...6 {
            headings.addItem(item("Заголовок \(level)", action, "\(level)", [.command, .control], command: "heading\(level)"))
        }
        menu.addItem(submenu(headings))
        let indent = NSMenu(title: String(localized: "Отступы"))
        indent.addItem(item("Увеличить уровень", action, "]", command: "indent"))
        indent.addItem(item("Уменьшить уровень", action, "[", command: "outdent"))
        menu.addItem(submenu(indent))
        menu.addItem(item("Переместить пункт вверх", action, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command, .control], command: "moveUp"))
        menu.addItem(item("Переместить пункт вниз", action, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), [.command, .control], command: "moveDown"))
        return menu
    }

    private static func paragraphStyles() -> [NSMenuItem] {
        let action = #selector(LibraryWindowController.format(_:))
        return [
            item("Название", action, "t", [.command, .shift], command: "title"),
            item("Заголовок", action, "h", [.command, .shift], command: "heading"),
            item("Подзаголовок", action, "j", [.command, .shift], command: "subheading"),
            item("Основной текст", action, "b", [.command, .shift], command: "body"),
            item("Моноширинный", action, "m", [.command, .shift], command: "mono"),
            .separator(),
            item("Маркированный список", action, "7", [.command, .shift], command: "bullet"),
            item("Список с тире", action, "8", [.command, .shift], command: "dash"),
            item("Нумерованный список", action, "9", [.command, .shift], command: "number"),
            .separator(),
            item("Цитата", action, "'", command: "quote"),
        ]
    }

    /// The «Aa» toolbar menu.
    static func paragraphStylesMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Формат"))
        for i in paragraphStyles() {
            i.keyEquivalent = ""
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let action = #selector(LibraryWindowController.format(_:))
        for (title, command): (String.LocalizationValue, String) in [("Жирный", "bold"), ("Курсив", "italic"), ("Подчёркнутый", "underline"),
                                 ("Зачёркнутый", "strike"), ("Выделение", "highlight")] {
            menu.addItem(item(title, action, command: command))
        }
        return menu
    }

    static func attachMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Вложения"))
        menu.addItem(item("Прикрепить файл…", #selector(LibraryWindowController.attachFile(_:))))
        let device = NSMenuItem(title: String(localized: "Вставить с iPhone или iPad"), action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(device)
        menu.addItem(item("Добавить ссылку…", #selector(LibraryWindowController.insertLink(_:))))
        return menu
    }

    static func lockMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Блокировка"))
        menu.addItem(item("Заблокировать заметку", #selector(LibraryWindowController.lockNote(_:))))
        menu.addItem(item("Закрыть заблокированные заметки", #selector(LibraryWindowController.closeLockedNotes(_:))))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Вид"))
        menu.addItem(item("Списком", #selector(LibraryWindowController.showList(_:)), "1"))
        menu.addItem(item("Галереей", #selector(LibraryWindowController.showGallery(_:)), "2"))
        // «Вложения» is also the window and toolbar title (Attachments); here it is Show Attachments.
        menu.addItem(NSMenuItem(title: String(localized: "menu.showAttachments", defaultValue: "Вложения"),
                                action: #selector(LibraryWindowController.showAttachments(_:)), keyEquivalent: "3"))
        menu.addItem(.separator())
        let sort = NSMenu(title: String(localized: "Сортировать по"))
        for (title, key): (String.LocalizationValue, String) in [("Дате изменения", "modified"), ("Дате создания", "created"), ("Названию", "title")] {
            sort.addItem(item(title, #selector(LibraryWindowController.sortBy(_:)), command: key))
        }
        menu.addItem(submenu(sort))
        menu.addItem(item("Группировать по дате", #selector(LibraryWindowController.toggleGroupByDate(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Боковая панель", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(item("Файлы", #selector(EditorWindowController.showFiles(_:)), "1", [.command, .option]))
        menu.addItem(item("Оглавление", #selector(EditorWindowController.showOutline(_:)), "2", [.command, .option]))
        menu.addItem(item("Режим исходника", #selector(LibraryWindowController.toggleSourceMode(_:)), "/"))
        menu.addItem(.separator())
        menu.addItem(item("Увеличить", #selector(LibraryWindowController.zoomIn(_:)), ".", [.command, .shift]))
        menu.addItem(item("Уменьшить", #selector(LibraryWindowController.zoomOut(_:)), ",", [.command, .shift]))
        menu.addItem(item("Реальный размер", #selector(LibraryWindowController.zoomReset(_:)), "0", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Назад", #selector(LibraryWindowController.goBack(_:)), "[", [.command, .option]))
        menu.addItem(item("Вперёд", #selector(LibraryWindowController.goForward(_:)), "]", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Во весь экран", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Окно"))
        menu.addItem(item("Свернуть", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Изменить масштаб", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Заметки.md", #selector(AppDelegate.showMainWindow(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Все окна — на передний план", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Справка"))
        menu.addItem(item("Перестроить индекс поиска", #selector(AppDelegate.rebuildIndex(_:))))
        return menu
    }
}
