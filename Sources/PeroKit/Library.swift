import CryptoKit
import Foundation

/// The notes library: a folder of Markdown files. Folders are directories, notes are
/// `.md` files, everything else Перо needs lives in `.pero/`. Use from the main thread.
public final class Library {
    public static let didChange = Notification.Name("PeroLibraryDidChange")
    public static let quickFolder = "Быстрые заметки"
    public static let importedFolder = "Импортированные заметки"
    public static let attachmentsFolder = "Attachments"
    public static let metaFolder = ".pero"
    public static let noteExtension = "md"
    public static let lockedExtension = "pero-locked"
    public static let trashDays = 30
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"]

    public let root: URL
    /// Перо's own data for this library (index, trash, state). Inside the folder as
    /// `.pero/` for the main library; elsewhere for a folder linked from the disk, so
    /// Перо never leaves files of its own there.
    public let meta: URL
    /// Notes's way: the file is named after the first line. Off for folders linked from
    /// the disk, where file names belong to the user (and to other apps writing them).
    public var renamesFilesAfterTitle = true
    public private(set) var notes: [String: NoteRecord] = [:]
    /// Folders relative to the root, sorted; the root itself («Заметки») is "".
    public private(set) var folders: [String] = []
    public private(set) var state: LibraryState
    /// Records of notes in «Недавно удалённые», by trash item id.
    public private(set) var trashRecords: [String: NoteRecord] = [:]

    private let index: LibraryIndex
    private var watcher: DirectoryWatcher?
    private let scanQueue = DispatchQueue(label: "pero.library.scan", qos: .utility)
    private var scanning = false
    private var scanAgain = false
    private var scanWaiters: [() -> Void] = []

    // MARK: Opening

    public init(root: URL, meta: URL? = nil) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { throw CocoaError(.fileNoSuchFile) }
        let metaDir = meta ?? root.appendingPathComponent(Self.metaFolder)
        let isNew = meta == nil && !fm.fileExists(atPath: metaDir.path)
        try fm.createDirectory(at: metaDir.appendingPathComponent("trash"), withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath()
        self.meta = metaDir
        if isNew {
            let ignore = self.root.appendingPathComponent(".gitignore")
            if !fm.fileExists(atPath: ignore.path) {
                try? "# Кэш заметок пересоздаётся сам\n.pero/cache/\n".write(to: ignore, atomically: true, encoding: .utf8)
            }
        }
        state = LibraryState.load(from: metaDir.appendingPathComponent("state.json"))
        index = try LibraryIndex(url: metaDir.appendingPathComponent("cache/index.sqlite"))
        for record in index.loadAll() { notes[record.path] = record }
        // Folders known from the index right away; the scan below adds empty ones.
        // (Walking every file here would make launch slow on big libraries.)
        folders = Self.folders(of: notes.keys)
        loadTrashRecords()
        watcher = DirectoryWatcher(url: self.root) { [weak self] paths in self?.filesChanged(paths) }
        rescan()
    }

    deinit { watcher?.stop() }

    public func url(_ path: String) -> URL { path.isEmpty ? root : root.appendingPathComponent(path) }
    private var stateURL: URL { meta.appendingPathComponent("state.json") }
    private var trashDir: URL { meta.appendingPathComponent("trash") }

    /// A file a note links to: library-relative, absolute ("/…", "file://…") or in the
    /// home folder ("~/…").
    public func fileURL(for target: String) -> URL {
        if target.hasPrefix("/") { return URL(fileURLWithPath: target) }
        if target.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(target.dropFirst(2))) }
        if let url = URL(string: target), url.isFileURL { return url }
        return url(target)
    }

    private func saveState() {
        do { try state.save(to: stateURL) } catch { NSLog("Pero: cannot save state: \(error)") }
    }

    private func post(changed: [String] = [], removed: [String] = [], moved: [String: String] = [:], structure: Bool = false) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [
            "changed": changed, "removed": removed, "moved": moved, "structure": structure,
        ])
    }

    /// Waits until queued index writes are done (tests, quitting).
    public func flush() { index.flush() }

    // MARK: Scanning

    private struct FileStat {
        var path: String
        var modified: Date
        var size: Int
        var created: Date
    }

    private func filesChanged(_ paths: [String]) {
        // Writes to Перо's own data (index, state) are not changes to the notes.
        if paths.allSatisfy({ Self.relative(URL(fileURLWithPath: $0), to: meta) != nil }) { return }
        rescan()
    }

    /// Compares the files on disk with the records and re-reads what changed.
    /// Runs in the background; `done` is called on the main queue.
    public func rescan(_ done: (() -> Void)? = nil) {
        if let done { scanWaiters.append(done) }
        if scanning { scanAgain = true; return }
        scanning = true
        let known = notes
        let root = self.root
        scanQueue.async {
            let (stats, folders) = Self.enumerate(root)
            let seen = Set(stats.map(\.path))
            let stale = stats.filter { stat in
                guard let old = known[stat.path] else { return true }
                return !Self.sameTime(old.modified, stat.modified) || old.size != stat.size
            }
            // Parsing is the slow part of a first scan: spread it over the cores.
            var results = [(NoteRecord, String)?](repeating: nil, count: stale.count)
            results.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: stale.count) { i in
                    autoreleasepool { out[i] = Self.read(root: root, path: stale[i].path, stat: stale[i]) }
                }
            }
            let changed = results.compactMap { $0 }
            let removed = known.keys.filter { !seen.contains($0) }
            DispatchQueue.main.async { self.applyScan(changed: changed, removed: removed, folders: folders) }
        }
    }

    private func applyScan(changed: [(NoteRecord, String)], removed: [String], folders: [String]) {
        let fm = FileManager.default
        var applied: [(NoteRecord, String)] = []
        for (record, body) in changed {
            // A save made while the scan ran is newer than what the scan read.
            if let current = notes[record.path], current.modified > record.modified,
               !Self.sameTime(current.modified, record.modified) { continue }
            notes[record.path] = record
            applied.append((record, body))
        }
        let gone = removed.filter { !fm.fileExists(atPath: url($0).path) }
        for path in gone { notes[path] = nil }
        let structure = folders != self.folders
        self.folders = folders
        index.upsert(applied)
        index.remove(gone)
        if !applied.isEmpty || !gone.isEmpty || structure {
            post(changed: applied.map(\.0.path), removed: gone, structure: structure)
        }
        scanning = false
        if scanAgain {
            scanAgain = false
            rescan()
        } else {
            let waiters = scanWaiters
            scanWaiters = []
            waiters.forEach { $0() }
        }
    }

    /// The index keeps dates to the microsecond; the file system has nanoseconds.
    static func sameTime(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }

    private static func isNoteFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return markdownExtensions.contains(ext) || ext == lockedExtension
    }

    private static func enumerate(_ root: URL) -> ([FileStat], [String]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey, .creationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        var files: [FileStat] = []
        var folders: [String] = []
        for case let url as URL in e {
            guard let path = relative(url, to: root) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true {
                if path == attachmentsFolder { e.skipDescendants(); continue }
                folders.append(path)
            } else if isNoteFile(url) {
                files.append(FileStat(path: path, modified: values?.contentModificationDate ?? Date(),
                                      size: values?.fileSize ?? 0, created: values?.creationDate ?? Date()))
            }
        }
        return (files, folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    private static func listFolders(_ root: URL) -> [String] { enumerate(root).1 }

    /// Every folder that holds a note, with its parents.
    static func folders<S: Sequence>(of paths: S) -> [String] where S.Element == String {
        var out = Set<String>()
        for path in paths {
            var dir = (path as NSString).deletingLastPathComponent
            while !dir.isEmpty, out.insert(dir).inserted { dir = (dir as NSString).deletingLastPathComponent }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func stat(_ url: URL, path: String) -> FileStat? {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .creationDateKey]) else { return nil }
        return FileStat(path: path, modified: v.contentModificationDate ?? Date(), size: v.fileSize ?? 0,
                        created: v.creationDate ?? Date())
    }

    /// Parses one note file into a record and its plain text for the search index.
    private static func read(root: URL, path: String, stat: FileStat) -> (NoteRecord, String)? {
        let url = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == lockedExtension {
            let title = LockedEnvelope.title(of: data) ?? (path as NSString).deletingPathExtension
            let record = NoteRecord(path: path, title: title, preview: "", created: stat.created, modified: stat.modified,
                                    size: stat.size, isLocked: true)
            return (record, "")
        }
        guard let text = try? TextCodec.decode(data).text else { return nil }
        let parsed = NoteParser.parse(text)
        return (record(path: path, parsed: parsed, stat: stat), parsed.plainText)
    }

    private static func record(path: String, text: String, stat: FileStat) -> NoteRecord {
        record(path: path, parsed: NoteParser.parse(text), stat: stat)
    }

    private static func record(path: String, parsed: ParsedNote, stat: FileStat) -> NoteRecord {
        let folder = (path as NSString).deletingLastPathComponent
        // Pictures inside the library are kept relative to it; others by absolute path.
        let image = parsed.firstImage.flatMap { LinkRewriter.resolve($0, from: folder) ?? Self.absolutePicture($0) }
        return NoteRecord(path: path, title: parsed.title, preview: parsed.preview, created: stat.created,
                          modified: stat.modified, size: stat.size, tags: parsed.tags,
                          wikiLinks: parsed.wikiLinks.map(\.target), tasksTotal: parsed.tasksTotal,
                          tasksDone: parsed.tasksDone, flags: parsed.flags, firstImage: image, words: parsed.words)
    }

    /// A note file replaced by another (locking or unlocking): pins follow it.
    func replaceAfterConversion(from old: String, to new: String) {
        let wasPinned = state.pinned.contains(old)
        notes[old] = nil
        index.remove([old])
        state.pinned.removeAll { $0 == old }
        if wasPinned { state.pinned.append(new) }
        refresh(new)
        saveState()
        // Not a move: the open note must not follow into the new (encrypted or plain) file.
        post(changed: [new], removed: [old])
    }

    func rescanOne(_ path: String) {
        refresh(path)
        post(changed: [path])
    }

    /// "/…", "file://…" or "~/…" as an absolute path; nil for web addresses and relative ones.
    public static func absolutePicture(_ target: String) -> String? {
        var t = target.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<") && t.hasSuffix(">") { t = String(t.dropFirst().dropLast()) }
        t = t.removingPercentEncoding ?? t
        if t.hasPrefix("/") { return t }
        if t.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(t.dropFirst(2))).path }
        if let url = URL(string: target), url.isFileURL { return url.path }
        return nil
    }

    /// Re-reads one note from disk right away (after a write by Перо itself).
    @discardableResult
    private func refresh(_ path: String) -> NoteRecord? {
        guard let stat = Self.stat(url(path), path: path), let (record, body) = Self.read(root: root, path: path, stat: stat) else { return nil }
        notes[path] = record
        index.upsert([(record, body)])
        return record
    }

    // MARK: Reading

    public func record(_ path: String) -> NoteRecord? { notes[path] }

    public func loadBuffer(_ path: String) throws -> NoteBuffer {
        try NoteBuffer(data: Data(contentsOf: url(path)))
    }

    public func isPinned(_ path: String) -> Bool { state.pinned.contains(path) }

    /// Tags with the number of notes, by name.
    public func tagCounts() -> [(tag: String, count: Int)] {
        var counts: [String: (String, Int)] = [:]
        for r in notes.values {
            for t in r.tags {
                let key = t.lowercased()
                counts[key] = (counts[key]?.0 ?? t, (counts[key]?.1 ?? 0) + 1)
            }
        }
        return counts.values.map { (tag: $0.0, count: $0.1) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    /// Notes whose text matches every word of `query` as a word prefix, best first.
    public func search(_ query: String) -> [NoteRecord] {
        index.search(query).compactMap { notes[$0] }
    }

    /// The note a `[[target]]` link points to: by title, then file name, then path.
    public func resolveWikiLink(_ target: String) -> NoteRecord? {
        let t = target.trimmingCharacters(in: .whitespaces)
        let key = t.lowercased()
        let candidates = notes.values.sorted { $0.path < $1.path }
        if t.contains("/") {
            let withExt = t.hasSuffix(".md") ? t : t + ".md"
            if let r = candidates.first(where: { $0.path.lowercased() == withExt.lowercased() }) { return r }
        }
        if let r = candidates.first(where: { $0.title.lowercased() == key }) { return r }
        return candidates.first { ($0.fileName as NSString).deletingPathExtension.lowercased() == key }
    }

    /// Notes with a wiki link to `record`.
    public func backlinks(to record: NoteRecord) -> [NoteRecord] {
        let names = Set([record.title.lowercased(), (record.fileName as NSString).deletingPathExtension.lowercased()])
        return notes.values.filter { r in r.path != record.path && r.wikiLinks.contains { names.contains($0.lowercased()) } }
    }

    // MARK: Notes

    /// Creates a note file named after the first line of `text` (or `fileName` when
    /// importing), with the given dates if known.
    @discardableResult
    public func createNote(in folder: String, text: String = "", fileName: String? = nil,
                           created: Date? = nil, modified: Date? = nil) throws -> String {
        guard Self.isInsideFolder(folder) else { throw CocoaError(.fileWriteInvalidFileName) }
        let dir = url(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = fileName.map { FileNames.baseName(forTitle: $0) } ?? FileNames.baseName(forTitle: NoteParser.parse(text).title)
        let file = FileNames.unique(base, ext: Self.noteExtension, in: dir)
        try Data(text.utf8).write(to: file, options: .withoutOverwriting)
        var attributes: [FileAttributeKey: Any] = [:]
        if let created { attributes[.creationDate] = created }
        if let modified { attributes[.modificationDate] = modified }
        if !attributes.isEmpty { try? FileManager.default.setAttributes(attributes, ofItemAtPath: file.path) }
        let path = relativePath(file)
        refresh(path)
        if !folders.contains(folder), !folder.isEmpty { folders = Self.listFolders(root); post(structure: true) }
        post(changed: [path])
        return path
    }

    private func relativePath(_ url: URL) -> String {
        Self.relative(url, to: root) ?? url.lastPathComponent
    }

    /// Path inside the library for a file URL. Copes with /var vs /private/var: the file
    /// system may hand back either spelling of the same folder.
    public static func relative(_ url: URL, to root: URL) -> String? {
        // "a//b" and "a/b" are the same folder; the file system hands back the second.
        let clean = { (p: String) in p.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression) }
        let base = clean(root.path)
        let roots = [base, "/private" + base, base.hasPrefix("/private/") ? String(base.dropFirst(8)) : base]
        for candidate in [clean(url.path), clean(url.resolvingSymlinksInPath().path)] {
            for r in roots where candidate.hasPrefix(r + "/") { return String(candidate.dropFirst(r.count + 1)) }
        }
        return nil
    }

    /// Writes the buffer to the note file and updates its record.
    @discardableResult
    public func save(_ path: String, buffer: NoteBuffer) throws -> NoteRecord? {
        try SafeWrite.write(try buffer.data(), to: url(path))
        let record = refresh(path)
        post(changed: [path])
        return record
    }

    /// Where the note should live for its current title, or nil if the name already fits.
    public func pathMatchingTitle(_ path: String) -> String? {
        guard renamesFilesAfterTitle, let record = notes[path], !record.isLocked else { return nil }
        let base = FileNames.baseName(forTitle: record.title)
        let current = (record.fileName as NSString).deletingPathExtension
        if FileNames.matches(current, base: base) { return nil }
        let ext = (record.fileName as NSString).pathExtension
        let dir = url(record.folder)
        if current.caseInsensitiveCompare(base) == .orderedSame {
            return relativePath(dir.appendingPathComponent(base).appendingPathExtension(ext))
        }
        return relativePath(FileNames.unique(base, ext: ext, in: dir))
    }

    /// A rename that may change only the letter case: on a case-insensitive disk it goes
    /// through a temporary name.
    private static func rename(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        guard from.lastPathComponent != to.lastPathComponent,
              from.lastPathComponent.caseInsensitiveCompare(to.lastPathComponent) == .orderedSame else {
            return try fm.moveItem(at: from, to: to)
        }
        let temp = from.deletingLastPathComponent().appendingPathComponent(".pero-rename-" + UUID().uuidString)
        try fm.moveItem(at: from, to: temp)
        try fm.moveItem(at: temp, to: to)
    }

    /// Renames the file after its title (Notes shows the first line as the name).
    @discardableResult
    public func renameToMatchTitle(_ path: String) throws -> String {
        guard let target = pathMatchingTitle(path) else { return path }
        try Self.rename(url(path), to: url(target))
        applyMoves([path: target])
        return target
    }

    /// Updates records, pins and the index after files moved (Перо moved them).
    private func applyMoves(_ moves: [String: String]) {
        guard !moves.isEmpty else { return }
        for (from, to) in moves {
            if var r = notes.removeValue(forKey: from) {
                r.path = to
                notes[to] = r
            }
            if let i = state.pinned.firstIndex(of: from) { state.pinned[i] = to }
        }
        index.rename(moves)
        for (_, to) in moves { refresh(to) }
        saveState()
        post(changed: Array(moves.values), moved: moves)
    }

    /// Rewrites `[[old]]` links in every other note after a note was renamed.
    @discardableResult
    public func renameWikiLinks(from old: String, to new: String, except path: String? = nil) -> Int {
        guard !old.isEmpty, old.lowercased() != new.lowercased() else { return 0 }
        var changed: [String] = []
        for r in notes.values where r.path != path && !r.isLocked && r.wikiLinks.contains(where: { $0.lowercased() == old.lowercased() }) {
            guard let buffer = try? loadBuffer(r.path),
                  let text = LinkRewriter.renameWikiLinks(buffer.text, from: old, to: new) else { continue }
            buffer.setText(text)
            if (try? SafeWrite.write(buffer.data(), to: url(r.path))) != nil {
                refresh(r.path)
                changed.append(r.path)
            }
        }
        if !changed.isEmpty { post(changed: changed) }
        return changed.count
    }

    /// Moves notes into `folder`, keeping their relative links working. Returns old → new paths.
    @discardableResult
    public func move(_ paths: [String], to folder: String) throws -> [String: String] {
        let fm = FileManager.default
        let dir = url(folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var moves: [String: String] = [:]
        var moved: [NoteRecord] = []
        var failure: Error?
        for path in paths {
            guard let record = notes[path], record.folder != folder else { continue }
            let target = FileNames.unique((record.fileName as NSString).deletingPathExtension,
                                          ext: (record.fileName as NSString).pathExtension, in: dir)
            do { try fm.moveItem(at: url(path), to: target) } catch { failure = error; break }
            moves[path] = relativePath(target)
            moved.append(record)
        }
        // Relative links now start from the new folder; links between the moved notes follow them.
        for record in moved where !record.isLocked {
            guard let new = moves[record.path], let buffer = try? loadBuffer(new),
                  let text = LinkRewriter.rebase(buffer.text, from: record.folder, to: folder, moving: { moves[$0] }) else { continue }
            buffer.setText(text)
            try? SafeWrite.write(buffer.data(), to: url(new))
        }
        applyMoves(moves)
        if let failure { throw failure }
        return moves
    }

    /// A copy next to the original, named «Название 2».
    @discardableResult
    public func duplicate(_ path: String) throws -> String {
        guard let record = notes[path] else { throw CocoaError(.fileNoSuchFile) }
        let base = (record.fileName as NSString).deletingPathExtension
        let target = FileNames.unique(base, ext: (record.fileName as NSString).pathExtension, in: url(record.folder))
        try FileManager.default.copyItem(at: url(path), to: target)
        let newPath = relativePath(target)
        refresh(newPath)
        post(changed: [newPath])
        return newPath
    }

    /// True for a note with nothing in it: no text, pictures, tasks or tables
    /// (a lone "# " from «Новые заметки начинаются с» counts as empty).
    public static func isEmptyNote(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let p = NoteParser.parse(text)
        return p.title.isEmpty && p.localTargets.isEmpty && p.tasksTotal == 0 && p.flags.isDisjoint(with: [.tables, .code, .links])
            && text.range(of: #"[^#\s>*+\-]"#, options: .regularExpression) == nil
    }

    /// Drops an empty note: a new note left blank vanishes (as in Notes), a note the user
    /// emptied goes to «Недавно удалённые».
    public func discardEmpty(_ path: String, keepInTrash: Bool = false) {
        guard let r = notes[path], !r.isLocked,
              let text = try? loadBuffer(path).text, Self.isEmptyNote(text) else { return }
        if keepInTrash {
            _ = try? trash([path])
            return
        }
        try? FileManager.default.removeItem(at: url(path))
        notes[path] = nil
        state.pinned.removeAll { $0 == path }
        index.remove([path])
        saveState()
        post(removed: [path])
    }

    // MARK: Pinning

    public func setPinned(_ paths: [String], _ pinned: Bool) {
        for path in paths where notes[path] != nil {
            state.pinned.removeAll { $0 == path }
            if pinned { state.pinned.append(path) }
        }
        saveState()
        post(changed: paths)
    }

    // MARK: Recently Deleted

    public var trash: [TrashItem] { state.trash }

    private func loadTrashRecords() {
        trashRecords = [:]
        for item in state.trash {
            let url = trashDir.appendingPathComponent(item.file)
            guard let stat = Self.stat(url, path: item.originalPath),
                  let data = try? Data(contentsOf: url) else { continue }
            if url.pathExtension.lowercased() == Self.lockedExtension {
                trashRecords[item.id] = NoteRecord(path: item.originalPath, title: LockedEnvelope.title(of: data) ?? "",
                                                   preview: "", created: stat.created, modified: stat.modified,
                                                   size: stat.size, isLocked: true)
            } else if let text = try? TextCodec.decode(data).text {
                trashRecords[item.id] = Self.record(path: item.originalPath, text: text, stat: stat)
            }
        }
    }

    public func trashURL(_ item: TrashItem) -> URL { trashDir.appendingPathComponent(item.file) }

    /// Moves notes to «Недавно удалённые». Returns the trash item ids.
    @discardableResult
    public func trash(_ paths: [String], now: Date = Date()) throws -> [String] {
        let fm = FileManager.default
        var ids: [String] = []
        var removed: [String] = []
        for path in paths {
            guard let record = notes[path] else { continue }
            let id = UUID().uuidString
            let dir = trashDir.appendingPathComponent(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: url(path), to: dir.appendingPathComponent(record.fileName))
            let item = TrashItem(id: id, originalPath: path, deletedAt: now, file: id + "/" + record.fileName)
            state.trash.append(item)
            trashRecords[id] = record
            notes[path] = nil
            state.pinned.removeAll { $0 == path }
            ids.append(id)
            removed.append(path)
        }
        index.remove(removed)
        saveState()
        post(removed: removed)
        return ids
    }

    /// Puts deleted notes back, into `folder` or where they came from. Returns new paths.
    @discardableResult
    public func restore(_ ids: [String], to folder: String? = nil) throws -> [String] {
        let fm = FileManager.default
        var restored: [String] = []
        for id in ids {
            guard let i = state.trash.firstIndex(where: { $0.id == id }) else { continue }
            let item = state.trash[i]
            let original = (item.originalPath as NSString).deletingLastPathComponent
            var dest = folder ?? original
            if !fm.fileExists(atPath: url(dest).path) && folder == nil { dest = "" }
            try fm.createDirectory(at: url(dest), withIntermediateDirectories: true)
            let name = (item.originalPath as NSString).lastPathComponent
            let target = FileNames.unique((name as NSString).deletingPathExtension, ext: (name as NSString).pathExtension, in: url(dest))
            let source = trashURL(item)
            if dest != original, source.pathExtension.lowercased() != Self.lockedExtension,
               let buffer = try? NoteBuffer(data: Data(contentsOf: source)),
               let text = LinkRewriter.rebase(buffer.text, from: original, to: dest) {
                buffer.setText(text)
                try SafeWrite.write(buffer.data(), to: source)
            }
            try fm.moveItem(at: source, to: target)
            try? fm.removeItem(at: source.deletingLastPathComponent())
            state.trash.remove(at: i)
            trashRecords[id] = nil
            let path = relativePath(target)
            refresh(path)
            restored.append(path)
        }
        saveState()
        if restored.contains(where: { !folders.contains(($0 as NSString).deletingLastPathComponent) }) {
            folders = Self.listFolders(root)
        }
        post(changed: restored, structure: true)
        return restored
    }

    public func deleteForever(_ ids: [String]) {
        let fm = FileManager.default
        for id in ids {
            guard let i = state.trash.firstIndex(where: { $0.id == id }) else { continue }
            try? fm.removeItem(at: trashDir.appendingPathComponent(id))
            state.trash.remove(at: i)
            trashRecords[id] = nil
        }
        saveState()
        post(structure: true)
    }

    /// Deletes for good what stayed in «Недавно удалённые» for 30 days.
    public func purgeExpiredTrash(now: Date = Date()) {
        let expired = state.trash.filter { $0.daysLeft(now: now) == 0 }.map(\.id)
        if !expired.isEmpty { deleteForever(expired) }
    }

    // MARK: Folders

    /// A library-relative folder path that cannot leave the library ("../", "/…").
    public static func isInsideFolder(_ folder: String) -> Bool {
        !folder.hasPrefix("/") && !folder.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    public static func isValidFolderName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !n.contains("/") && !n.contains(":") && !n.hasPrefix(".") && n != attachmentsFolder
    }

    @discardableResult
    public func createFolder(named name: String, in parent: String = "") throws -> String {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard Self.isValidFolderName(clean), Self.isInsideFolder(parent) else { throw CocoaError(.fileWriteInvalidFileName) }
        let dir = FileNames.unique(clean, ext: "", in: url(parent))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folders = Self.listFolders(root)
        post(structure: true)
        return relativePath(dir)
    }

    private func notes(under folder: String) -> [NoteRecord] {
        notes.values.filter { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }
    }

    /// Path mapping for everything inside a folder that moves from `old` to `new`.
    private func remapPrefix(_ old: String, _ new: String) {
        var moves: [String: String] = [:]
        for r in notes(under: old) { moves[r.path] = new + r.path.dropFirst(old.count) }
        var settings: [String: FolderSettings] = [:]
        for (k, v) in state.folders {
            if k == old || k.hasPrefix(old + "/") { settings[new + k.dropFirst(old.count)] = v } else { settings[k] = v }
        }
        state.folders = settings
        for i in state.smartFolders.indices {
            state.smartFolders[i].filters = state.smartFolders[i].filters.map { f in
                guard case .folders(let include, let list) = f else { return f }
                return .folders(include: include, list.map { $0 == old || $0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0 })
            }
        }
        folders = Self.listFolders(root)
        applyMoves(moves)
        post(structure: true)
    }

    @discardableResult
    public func renameFolder(_ path: String, to name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard Self.isValidFolderName(clean), !path.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let parent = (path as NSString).deletingLastPathComponent
        let old = (path as NSString).lastPathComponent
        let target = old.caseInsensitiveCompare(clean) == .orderedSame
            ? url(parent).appendingPathComponent(clean) : FileNames.unique(clean, ext: "", in: url(parent))
        try Self.rename(url(path), to: target)
        let newPath = relativePath(target)
        remapPrefix(path, newPath)
        return newPath
    }

    /// Moves a folder into another one (or to the top with ""), fixing relative links.
    @discardableResult
    public func moveFolder(_ path: String, into parent: String) throws -> String {
        guard !path.isEmpty, parent != path, !parent.hasPrefix(path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        let name = (path as NSString).lastPathComponent
        let target = FileNames.unique(name, ext: "", in: url(parent))
        let newPath = parent.isEmpty ? target.lastPathComponent : parent + "/" + target.lastPathComponent
        if newPath == path { return path }
        // Links to anything inside the folder (notes, pictures) move with it.
        let inside = { (target: String) in target.hasPrefix(path + "/") ? newPath + target.dropFirst(path.count) : nil }
        for r in notes(under: path) where !r.isLocked {
            let newFolder = newPath + r.folder.dropFirst(path.count)
            if let buffer = try? loadBuffer(r.path), let text = LinkRewriter.rebase(buffer.text, from: r.folder, to: newFolder, moving: inside) {
                buffer.setText(text)
                try SafeWrite.write(buffer.data(), to: url(r.path))
            }
        }
        try FileManager.default.moveItem(at: url(path), to: target)
        remapPrefix(path, newPath)
        return newPath
    }

    /// Notes go to «Недавно удалённые»; whatever else was in the folder goes to the system Trash.
    public func deleteFolder(_ path: String) throws {
        guard !path.isEmpty else { return }
        try trash(notes(under: path).map(\.path))
        try FileManager.default.trashItem(at: url(path), resultingItemURL: nil)
        state.folders = state.folders.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        saveState()
        folders = Self.listFolders(root)
        post(structure: true)
    }

    public func settings(for folder: String) -> FolderSettings { state.folders[folder] ?? FolderSettings() }

    public func setSettings(_ settings: FolderSettings, for folder: String) {
        state.folders[folder] = settings.isEmpty ? nil : settings
        saveState()
        post(structure: true)
    }

    // MARK: Smart folders and tags

    public func addSmartFolder(_ folder: SmartFolder) {
        state.smartFolders.append(folder)
        saveState()
        post(structure: true)
    }

    public func updateSmartFolder(_ folder: SmartFolder) {
        guard let i = state.smartFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        state.smartFolders[i] = folder
        saveState()
        post(structure: true)
    }

    public func removeSmartFolder(_ id: String) {
        state.smartFolders.removeAll { $0.id == id }
        saveState()
        post(structure: true)
    }

    /// Notes's «Convert to Smart Folder»: the notes move to «Заметки» and get the folder's
    /// name as a tag; the folder becomes a smart folder for that tag.
    @discardableResult
    public func convertToSmartFolder(_ path: String) throws -> SmartFolder {
        let name = (path as NSString).lastPathComponent
        let tag = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "_")
        guard !tag.isEmpty, !folders.contains(where: { $0.hasPrefix(path + "/") }) else { throw CocoaError(.fileWriteNoPermission) }
        let inside = notes.values.filter { $0.folder == path }
        guard !inside.contains(where: \.isLocked) else { throw CocoaError(.fileWriteNoPermission) }
        for r in inside where !r.hasTag(tag) {
            let buffer = try loadBuffer(r.path)
            let text = buffer.text
            buffer.setText(text + (text.hasSuffix("\n") || text.isEmpty ? "" : "\n") + "\n#" + tag + "\n")
            try SafeWrite.write(buffer.data(), to: url(r.path))
            refresh(r.path)
        }
        try move(inside.map(\.path), to: "")
        // Pictures and other files the notes linked to stay where the links now point.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: url(path).path)) ?? []
        if left.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: url(path)) }
        let smart = SmartFolder(name: name, filters: [.tags(.anySelected, [tag])])
        state.smartFolders.append(smart)
        state.folders[path] = nil
        saveState()
        folders = Self.listFolders(root)
        post(structure: true)
        return smart
    }

    public func setTagColor(_ tag: String, _ color: String?) {
        state.tagColors[tag.lowercased()] = color
        saveState()
        post(structure: true)
    }

    /// Rewrites `#old` as `#new` (or removes it when `new` is nil) in every note that has it.
    /// All or nothing: if one file cannot be written, the ones already written go back.
    @discardableResult
    public func replaceTag(_ old: String, with new: String?) throws -> Int {
        let pattern = #"(?<![\p{L}\p{N}_#/&\-])#"# + NSRegularExpression.escapedPattern(for: old) + #"(?![\p{L}\p{N}_\-])"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        var written: [(String, NoteBuffer, String)] = []
        do {
            for r in notes.values where r.hasTag(old) && !r.isLocked {
                let buffer = try loadBuffer(r.path)
                let original = buffer.text
                let range = NSRange(location: 0, length: (original as NSString).length)
                var text = regex.stringByReplacingMatches(in: original, range: range,
                                                          withTemplate: new.map { NSRegularExpression.escapedTemplate(for: "#" + $0) } ?? "")
                if new == nil {
                    text = text.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: [.regularExpression])
                }
                guard text != original else { continue }
                buffer.setText(text)
                try SafeWrite.write(buffer.data(), to: url(r.path))
                written.append((r.path, buffer, original))
            }
        } catch {
            for (path, buffer, original) in written {
                buffer.setText(original)
                try? SafeWrite.write(buffer.data(), to: url(path))
            }
            throw error
        }
        written.forEach { refresh($0.0) }
        if let color = state.tagColors.removeValue(forKey: old.lowercased()), let new { state.tagColors[new.lowercased()] = color }
        saveState()
        post(changed: written.map(\.0), structure: true)
        return written.count
    }

    // MARK: Attachments

    /// Copies a file into Attachments/ГГГГ/ММ/ (or finds the same file already there).
    /// Returns its library-relative path.
    public func addAttachment(data: Data, name: String, now: Date = Date()) throws -> String {
        let fm = FileManager.default
        let base = root.appendingPathComponent(Self.attachmentsFolder)
        if let existing = findAttachment(data, in: base) { return existing }
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        let dir = base.appendingPathComponent(String(format: "%04d/%02d", comps.year ?? 2000, comps.month ?? 1))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = String(UUID().uuidString.lowercased().prefix(6))
        let file = dir.appendingPathComponent(id + "-" + FileNames.attachmentName(name))
        try data.write(to: file, options: .withoutOverwriting)
        return relativePath(file)
    }

    public func addAttachment(fileAt url: URL) throws -> String {
        try addAttachment(data: Data(contentsOf: url), name: url.lastPathComponent)
    }

    private func findAttachment(_ data: Data, in base: URL) -> String? {
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return nil }
        var digest: SHA256.Digest?
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == data.count,
                  let other = try? Data(contentsOf: url) else { continue }
            if digest == nil { digest = SHA256.hash(data: data) }
            if SHA256.hash(data: other) == digest { return relativePath(url) }
        }
        return nil
    }

    /// Link target for `attachment` written in a note inside `folder`.
    public func linkTarget(to path: String, fromFolder folder: String) -> String {
        LinkRewriter.target(LinkRewriter.relative(from: folder, to: path))
    }
}
