import AppKit
import CryptoKit
import PeroKit
import UniformTypeIdentifiers

/// Import into the library: Markdown and text files (with their pictures), RTF, RTFD,
/// HTML, Evernote ENEX, and Apple Notes through AppleScript.
final class Importer {
    struct Report {
        var notes = 0
        var skipped: [String] = []
        var losses: Set<String> = []

        var summary: String {
            var lines = ["Импортировано: \(notes) \(Plural.notes(notes))."]
            if !skipped.isEmpty { lines.append("Пропущено: " + skipped.prefix(10).joined(separator: ", ") + (skipped.count > 10 ? "…" : "")) }
            if !losses.isEmpty { lines.append("Не перенеслось: " + losses.sorted().joined(separator: ", ") + ".") }
            return lines.joined(separator: "\n")
        }
    }

    let library: Library
    let editor: EditorViewController
    private(set) var report = Report()

    init(library: Library, editor: EditorViewController) {
        self.library = library
        self.editor = editor
    }

    static let markdownExtensions = Library.markdownExtensions
    static let richExtensions: Set<String> = ["rtf", "rtfd", "html", "htm", "webarchive"]

    /// Imports files and folders into `folder`. With `keepStructure`, subfolders of
    /// imported folders become folders in the library.
    func importItems(_ urls: [URL], into folder: String, keepStructure: Bool, done: @escaping (Report) -> Void) {
        var jobs: [(URL, String)] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue && url.pathExtension.lowercased() != "rtfd" {
                let top = keepStructure ? (folder.isEmpty ? url.lastPathComponent : folder + "/" + url.lastPathComponent) : folder
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = e?.nextObject() as? URL {
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, file.pathExtension.lowercased() != "rtfd" { continue }
                    let sub = Library.relative(file.deletingLastPathComponent(), to: url) ?? ""
                    let target = keepStructure && !sub.isEmpty ? top + "/" + sub : top
                    if Self.isImportable(file) { jobs.append((file, target)) }
                }
            } else if Self.isImportable(url) {
                jobs.append((url, folder))
            } else {
                report.skipped.append(url.lastPathComponent)
            }
        }
        run(jobs, done: done)
    }

    static func isImportable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return markdownExtensions.contains(ext) || richExtensions.contains(ext) || ext == "txt" || ext == "enex" || ext == Library.lockedExtension
    }

    private func run(_ jobs: [(URL, String)], done: @escaping (Report) -> Void) {
        var queue = jobs
        func next() {
            guard !queue.isEmpty else { return done(report) }
            let (url, folder) = queue.removeFirst()
            importFile(url, into: folder) { next() }
        }
        next()
    }

    private func importFile(_ url: URL, into folder: String, then: @escaping () -> Void) {
        let ext = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let created = values?.creationDate, modified = values?.contentModificationDate
        let name = url.deletingPathExtension().lastPathComponent
        if Self.markdownExtensions.contains(ext) || ext == "txt" {
            do {
                let text = try TextCodec.decode(Data(contentsOf: url)).text
                let rewritten = copyPictures(in: text, from: url.deletingLastPathComponent(), noteFolder: folder)
                try library.createNote(in: folder, text: rewritten, fileName: name, created: created, modified: modified)
                report.notes += 1
            } catch { report.skipped.append(url.lastPathComponent) }
            return then()
        }
        if ext == Library.lockedExtension {
            let dir = library.url(folder)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? FileManager.default.copyItem(at: url, to: FileNames.unique(name, ext: ext, in: dir))) != nil { report.notes += 1 }
            library.rescan()
            return then()
        }
        if ext == "enex" { return importENEX(url, into: folder, then: then) }
        // RTF, RTFD, HTML, web archives: through HTML into Markdown.
        guard let html = Self.html(of: url) else { report.skipped.append(url.lastPathComponent); return then() }
        report.losses.insert("шрифты и цвета текста")
        convert(html, into: folder, name: name, created: created, modified: modified, extraTags: []) { then() }
    }

    static func html(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "html" || ext == "htm" { return (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .windowsCP1251) } }
        guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil),
              let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// HTML → Markdown in the editor page; pictures that came as data: URIs become attachments.
    private func convert(_ html: String, into folder: String, name: String?, created: Date?, modified: Date?,
                         extraTags: [String], resources: [String: (Data, String)] = [:], then: @escaping () -> Void) {
        editor.htmlToMarkdown(html) { [self] markdown, images in
            var text = markdown
            for (i, uri) in images.enumerated() {
                guard let comma = uri.firstIndex(of: ","), let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { continue }
                let ext = uri.contains("image/png") ? "png" : uri.contains("image/gif") ? "gif" : "jpg"
                if let path = try? library.addAttachment(data: data, name: "Картинка.\(ext)") {
                    text = text.replacingOccurrences(of: "(pero-pending:\(i))", with: "(\(library.linkTarget(to: path, fromFolder: folder)))")
                }
            }
            for (hash, (data, fileName)) in resources {
                guard text.contains("pero-res:\(hash)"), let path = try? library.addAttachment(data: data, name: fileName) else { continue }
                text = text.replacingOccurrences(of: "pero-res:\(hash)", with: library.linkTarget(to: path, fromFolder: folder))
            }
            if let name, !name.isEmpty, NoteParser.parse(text).title != name.trimmingCharacters(in: .whitespaces) {
                text = "# " + name + "\n\n" + text
            }
            if !extraTags.isEmpty {
                text += "\n\n" + extraTags.map { "#" + $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: " ") + "\n"
            }
            if (try? library.createNote(in: folder, text: text, fileName: name, created: created, modified: modified)) != nil {
                report.notes += 1
            }
            then()
        }
    }

    /// Pictures next to an imported Markdown file are copied into Attachments.
    private func copyPictures(in text: String, from dir: URL, noteFolder: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(!\[[^\]\n]*\]\(\s*)(<[^>\n]*>|[^)\s]+)|(<img\s[^>]*?src=")([^"]+)(")"#, options: [.caseInsensitive])
        let ns = text as NSString
        var out = text
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let group = m.range(at: 2).location != NSNotFound ? 2 : 4
            var target = ns.substring(with: m.range(at: group))
            let wrapped = target.hasPrefix("<") && target.hasSuffix(">")
            if wrapped { target = String(target.dropFirst().dropLast()) }
            if target.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil { continue }
            let file = target.hasPrefix("/") ? URL(fileURLWithPath: target) : dir.appendingPathComponent(target.removingPercentEncoding ?? target)
            // Only pictures: a link in an imported note must not pull other local files in.
            guard UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true,
                  let data = try? Data(contentsOf: file), let path = try? library.addAttachment(data: data, name: file.lastPathComponent),
                  let range = Range(m.range(at: group), in: out) else { continue }
            let link = library.linkTarget(to: path, fromFolder: noteFolder)
            out.replaceSubrange(range, with: group == 4 ? LinkRewriter.relative(from: noteFolder, to: path) : link)
        }
        return out
    }

    // MARK: Evernote

    private func importENEX(_ url: URL, into folder: String, then: @escaping () -> Void) {
        guard let doc = try? XMLDocument(contentsOf: url, options: [.nodeLoadExternalEntitiesNever]), let notes = try? doc.nodes(forXPath: "//note") else {
            report.skipped.append(url.lastPathComponent)
            return then()
        }
        let dates = DateFormatter()
        dates.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dates.timeZone = TimeZone(identifier: "UTC")
        var queue = notes.compactMap { $0 as? XMLElement }
        report.losses.insert("шрифты и цвета текста")
        func next() {
            guard !queue.isEmpty else { return then() }
            let note = queue.removeFirst()
            let title = note.elements(forName: "title").first?.stringValue ?? ""
            var content = note.elements(forName: "content").first?.stringValue ?? ""
            let tags = note.elements(forName: "tag").compactMap(\.stringValue)
            let created = note.elements(forName: "created").first?.stringValue.flatMap(dates.date(from:))
            let updated = note.elements(forName: "updated").first?.stringValue.flatMap(dates.date(from:))
            var resources: [String: (Data, String)] = [:]
            for res in note.elements(forName: "resource") {
                guard let b64 = res.elements(forName: "data").first?.stringValue,
                      let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { continue }
                let mime = res.elements(forName: "mime").first?.stringValue ?? ""
                let fileName = res.elements(forName: "resource-attributes").first?.elements(forName: "file-name").first?.stringValue
                    ?? "Вложение." + (mime.components(separatedBy: "/").last ?? "bin")
                resources[ENEXHash.md5Hex(data)] = (data, fileName)
            }
            // <en-media hash="…"> → a picture or a link the converter understands.
            content = content.replacingOccurrences(of: #"<en-media[^>]*type="image/[^"]*"[^>]*hash="([0-9a-f]+)"[^>]*/?>"#,
                                                   with: #"<img src="pero-res:$1">"#, options: .regularExpression)
            content = content.replacingOccurrences(of: #"<en-media[^>]*hash="([0-9a-f]+)"[^>]*type="image/[^"]*"[^>]*/?>"#,
                                                   with: #"<img src="pero-res:$1">"#, options: .regularExpression)
            content = content.replacingOccurrences(of: #"<en-media[^>]*hash="([0-9a-f]+)"[^>]*/?>"#,
                                                   with: #"<a href="pero-res:$1">Вложение</a>"#, options: .regularExpression)
            content = content.replacingOccurrences(of: #"<en-todo\s+checked="true"\s*/?>"#, with: "<input type=\"checkbox\" checked>", options: .regularExpression)
            content = content.replacingOccurrences(of: #"<en-todo[^>]*/?>"#, with: "<input type=\"checkbox\">", options: .regularExpression)
            convert(content, into: folder, name: title, created: created, modified: updated, extraTags: tags, resources: resources) { next() }
        }
        next()
    }

    // MARK: Apple Notes

    /// Every unlocked note of Apple Notes, with its folder and dates, through AppleScript.
    /// The first run asks for permission to control Notes.
    func importAppleNotes(into folder: String, progress: @escaping (Int, Int) -> Void, done: @escaping (Report?, String?) -> Void) {
        let script = """
            set out to {}
            tell application "Notes"
                repeat with f in folders
                    set fname to name of f
                    set fid to id of f
                    repeat with n in notes of f
                        if password protected of n then
                            set end of out to {fname, name of n, "", creation date of n, modification date of n, true}
                        else
                            set end of out to {fname, name of n, body of n, creation date of n, modification date of n, false}
                        end if
                    end repeat
                end repeat
            end tell
            return out
            """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                guard let result else {
                    let message = (error?[NSAppleScript.errorMessage] as? String) ?? "Не удалось обратиться к «Заметкам»."
                    return done(nil, message)
                }
                var items: [(String, String, String, Date?, Date?, Bool)] = []
                for i in stride(from: 1, through: result.numberOfItems, by: 1) {
                    guard let rec = result.atIndex(i), rec.numberOfItems >= 6 else { continue }
                    items.append((rec.atIndex(1)?.stringValue ?? "", rec.atIndex(2)?.stringValue ?? "",
                                  rec.atIndex(3)?.stringValue ?? "", rec.atIndex(4)?.dateValue, rec.atIndex(5)?.dateValue,
                                  rec.atIndex(6)?.booleanValue ?? false))
                }
                self.importNotesItems(items, into: folder, progress: progress) { done(self.report, nil) }
            }
        }
    }

    private func importNotesItems(_ items: [(String, String, String, Date?, Date?, Bool)], into folder: String,
                                  progress: @escaping (Int, Int) -> Void, done: @escaping () -> Void) {
        var queue = items
        let total = items.count
        let deleted: Set<String> = ["Recently Deleted", "Недавно удаленные", "Недавно удалённые"]
        func next() {
            progress(total - queue.count, total)
            guard !queue.isEmpty else { return done() }
            let (folderName, title, body, created, modified, locked) = queue.removeFirst()
            if deleted.contains(folderName) { return next() }
            if locked {
                report.skipped.append("«\(title)» (заблокирована)")
                return next()
            }
            let target = folderName.isEmpty || folderName == "Notes" || folderName == "Заметки" ? folder
                : folder + "/" + FileNames.baseName(forTitle: folderName)
            report.losses.insert("шрифты и цвета текста")
            if body.contains("<object") { report.losses.insert("вложения, которые «Заметки» не отдают через AppleScript") }
            convert(body, into: target, name: title, created: created, modified: modified, extraTags: []) { next() }
        }
        next()
    }
}

enum ENEXHash {
    /// Evernote names resources by their MD5.
    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension LibraryWindowController {
    func importFiles(_ urls: [URL], into folder: String, library target: Library? = nil) {
        session?.saveNow()
        let lib = target ?? library
        let importer = Importer(library: lib, editor: editor)
        importer.importItems(urls, into: folder, keepStructure: true) { [weak self] report in
            if lib !== self?.library { self?.switchLibrary(to: lib) }
            self?.importFinished(report, folder: folder)
        }
    }

    /// «Файл ▸ Импортировать в Заметки.md…»: as in Notes, into «Импортированные заметки».
    @objc func importDialog(_ sender: Any?) {
        guard let window else { return }
        switchLibrary(to: libraries.main)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Импортировать"
        panel.message = "Markdown, текст, RTF, RTFD, HTML или экспорт Evernote (ENEX). Можно выбрать папку."
        let keep = NSButton(checkboxWithTitle: "Сохранять структуру папок", target: nil, action: nil)
        keep.state = .on
        panel.accessoryView = keep
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            self.session?.saveNow()
            Importer(library: self.library, editor: self.editor)
                .importItems(panel.urls, into: Library.importedFolder, keepStructure: keep.state == .on) { [weak self] report in
                    self?.importFinished(report, folder: Library.importedFolder)
                }
        }
    }

    @objc func importAppleNotes(_ sender: Any?) {
        guard let window else { return }
        switchLibrary(to: libraries.main)
        let alert = NSAlert()
        alert.messageText = "Импортировать заметки из «Заметок» Apple?"
        alert.informativeText = """
            Все незаблокированные заметки будут прочитаны через AppleScript и сложены в «Импортированные заметки» \
            с папками и датами. macOS попросит разрешить управлять «Заметками» Apple. \
            Шрифты и цвета не переносятся: в Markdown их нет.
            """
        alert.addButton(withTitle: "Импортировать")
        alert.addButton(withTitle: "Отменить")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let progress = ProgressSheet.show(on: window, title: "Импорт из «Заметок»…")
            let importer = Importer(library: self.library, editor: self.editor)
            importer.importAppleNotes(into: Library.importedFolder, progress: { done, total in
                progress.update(done, total)
            }, done: { report, error in
                progress.close()
                if let error { return self.showMessage("Импорт не удался", error) }
                if let report { self.importFinished(report, folder: Library.importedFolder) }
            })
        }
    }

    private func importFinished(_ report: Importer.Report, folder: String) {
        library.rescan { [weak self] in
            guard let self else { return }
            if report.notes > 0 { self.showScope(folder == Library.quickFolder ? .quick : .folder(folder)) }
            self.showMessage(report.notes > 0 ? "Импорт завершён" : "Ничего не импортировано", report.summary)
        }
    }
}
