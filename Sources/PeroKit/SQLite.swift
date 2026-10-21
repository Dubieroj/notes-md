import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin wrapper over the system SQLite. Not thread-safe: use from one queue.
final class Database {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(description: message)
        }
    }

    deinit { sqlite3_close(handle) }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteError(description: lastError) }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(description: lastError + " in " + sql)
        }
        return Statement(stmt)
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    private let stmt: OpaquePointer

    init(_ stmt: OpaquePointer) { self.stmt = stmt }
    deinit { sqlite3_finalize(stmt) }

    @discardableResult
    func bind(_ values: Any?...) -> Statement {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(stmt, index)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, index, v)
            case let v as Bool: sqlite3_bind_int64(stmt, index, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as Date: sqlite3_bind_double(stmt, index, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, transient)
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return self
    }

    /// Runs a statement that returns no rows.
    func run() throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }
    }

    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }

    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    func string(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }
}
