import Foundation

/// The SQLite cache in .pero/cache/index.sqlite: note records for a fast launch and a
/// full-text index for search. Everything here can be rebuilt from the files.
final class LibraryIndex {
    static let schemaVersion = 1

    private let db: Database
    private let queue = DispatchQueue(label: "pero.index")

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db = try Database(path: url.path)
        if (try? Self.version(db)) != Self.schemaVersion {
            // A cache from another version: start over.
            db = try Self.recreate(at: url)
        }
        // Rows of a note that gets locked are overwritten, not just unlinked: its words
        // must not stay readable in the file.
        try? db.exec("PRAGMA secure_delete=ON")
        self.db = db
    }

    private static func version(_ db: Database) throws -> Int {
        let stmt = try db.prepare("PRAGMA user_version")
        return stmt.step() ? stmt.int(0) : 0
    }

    private static func recreate(at url: URL) throws -> Database {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let db = try Database(path: url.path)
        try db.exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE note (
              id INTEGER PRIMARY KEY,
              path TEXT UNIQUE NOT NULL,
              title TEXT NOT NULL, preview TEXT NOT NULL,
              created REAL NOT NULL, modified REAL NOT NULL, size INTEGER NOT NULL,
              tags TEXT NOT NULL, links TEXT NOT NULL,
              tasks_total INTEGER NOT NULL, tasks_done INTEGER NOT NULL,
              flags INTEGER NOT NULL, first_image TEXT,
              locked INTEGER NOT NULL, words INTEGER NOT NULL
            );
            CREATE VIRTUAL TABLE note_fts USING fts5(title, body, tags, tokenize='unicode61 remove_diacritics 2');
            PRAGMA user_version=\(schemaVersion);
            """)
        return db
    }

    private static let separator = "\u{1F}"

    func loadAll() -> [NoteRecord] {
        queue.sync {
            guard let stmt = try? db.prepare("""
                SELECT path, title, preview, created, modified, size, tags, links, tasks_total, tasks_done,
                       flags, first_image, locked, words FROM note
                """) else { return [] }
            var out: [NoteRecord] = []
            while stmt.step() {
                out.append(NoteRecord(
                    path: stmt.string(0) ?? "", title: stmt.string(1) ?? "", preview: stmt.string(2) ?? "",
                    created: stmt.date(3), modified: stmt.date(4), size: stmt.int(5),
                    tags: Self.split(stmt.string(6)), wikiLinks: Self.split(stmt.string(7)),
                    tasksTotal: stmt.int(8), tasksDone: stmt.int(9), flags: NoteFlags(rawValue: stmt.int(10)),
                    firstImage: stmt.string(11), isLocked: stmt.int(12) != 0, words: stmt.int(13)))
            }
            return out
        }
    }

    private static func split(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        return s.components(separatedBy: separator)
    }

    /// Search text is lowercased with «ё» folded to «е» on both sides: SQLite only
    /// strips diacritics from Latin letters.
    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    func upsert(_ records: [(NoteRecord, String)]) {
        guard !records.isEmpty else { return }
        queue.async { [db] in
            do {
                try db.transaction {
                    let find = try db.prepare("SELECT id FROM note WHERE path = ?")
                    let insert = try db.prepare("""
                        INSERT INTO note (path, title, preview, created, modified, size, tags, links, tasks_total,
                                          tasks_done, flags, first_image, locked, words)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """)
                    let update = try db.prepare("""
                        UPDATE note SET title=?, preview=?, created=?, modified=?, size=?, tags=?, links=?, tasks_total=?,
                                        tasks_done=?, flags=?, first_image=?, locked=?, words=? WHERE id=?
                        """)
                    let deleteFTS = try db.prepare("DELETE FROM note_fts WHERE rowid = ?")
                    let insertFTS = try db.prepare("INSERT INTO note_fts (rowid, title, body, tags) VALUES (?, ?, ?, ?)")
                    for (r, body) in records {
                        let tags = r.tags.joined(separator: Self.separator)
                        let links = r.wikiLinks.joined(separator: Self.separator)
                        var id: Int64
                        if find.bind(r.path).step() {
                            id = find.int64(0)
                            try update.bind(r.title, r.preview, r.created, r.modified, r.size, tags, links, r.tasksTotal,
                                            r.tasksDone, r.flags.rawValue, r.firstImage, r.isLocked, r.words, id).run()
                            try deleteFTS.bind(id).run()
                        } else {
                            try insert.bind(r.path, r.title, r.preview, r.created, r.modified, r.size, tags, links,
                                            r.tasksTotal, r.tasksDone, r.flags.rawValue, r.firstImage, r.isLocked,
                                            r.words).run()
                            id = db.lastInsertID
                        }
                        try insertFTS.bind(id, Self.normalize(r.title), Self.normalize(body),
                                           Self.normalize(r.tags.joined(separator: " "))).run()
                    }
                }
            } catch {
                NSLog("Pero index: \(error)")
            }
        }
    }

    func remove(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        queue.async { [db] in
            try? db.transaction {
                let find = try db.prepare("SELECT id FROM note WHERE path = ?")
                let delete = try db.prepare("DELETE FROM note WHERE id = ?")
                let deleteFTS = try db.prepare("DELETE FROM note_fts WHERE rowid = ?")
                for path in paths where find.bind(path).step() {
                    let id = find.int64(0)
                    try delete.bind(id).run()
                    try deleteFTS.bind(id).run()
                }
            }
        }
    }

    func rename(_ moves: [String: String]) {
        guard !moves.isEmpty else { return }
        queue.async { [db] in
            try? db.transaction {
                let stmt = try db.prepare("UPDATE OR REPLACE note SET path = ? WHERE path = ?")
                for (from, to) in moves { try stmt.bind(to, from).run() }
            }
        }
    }

    /// Paths of notes matching every word of the query (as a word prefix), best first.
    func search(_ query: String, limit: Int = 1000) -> [String] {
        let words = Self.normalize(query)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        return queue.sync {
            guard let stmt = try? db.prepare("""
                SELECT note.path FROM note_fts JOIN note ON note.id = note_fts.rowid
                WHERE note_fts MATCH ? ORDER BY bm25(note_fts, 10.0, 1.0, 5.0) LIMIT ?
                """) else { return [] }
            stmt.bind(match, limit)
            var out: [String] = []
            while stmt.step() { if let p = stmt.string(0) { out.append(p) } }
            return out
        }
    }

    /// Waits for queued writes (tests, quitting).
    func flush() { queue.sync {} }
}
