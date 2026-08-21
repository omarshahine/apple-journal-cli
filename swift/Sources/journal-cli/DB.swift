// DB.swift — minimal SQLite wrapper over the system libsqlite3.
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DB {
    let handle: OpaquePointer

    init(path: String, readOnly: Bool = false) {
        var h: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h = h else {
            die("cannot open database \(path)")
        }
        handle = h
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func exec(_ sql: String, _ params: [Any?] = []) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            die("sql error: \(String(cString: sqlite3_errmsg(handle))) in \(sql.prefix(120))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt!, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            die("sql step error: \(String(cString: sqlite3_errmsg(handle)))")
        }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            die("sql error: \(String(cString: sqlite3_errmsg(handle))) in \(sql.prefix(120))")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt!, params)
        var out: [[String: Any]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:   row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    if let p = sqlite3_column_blob(stmt, i) {
                        row[name] = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
                    } else { row[name] = Data() }
                default: break // NULL: leave absent
                }
            }
            out.append(row)
        }
        return out
    }

    func one(_ sql: String, _ params: [Any?] = []) -> [String: Any]? {
        query(sql, params).first
    }

    func scalarInt(_ sql: String, _ params: [Any?] = []) -> Int64? {
        guard let r = one(sql, params), let v = r.values.first else { return nil }
        return v as? Int64
    }

    private func bind(_ stmt: OpaquePointer, _ params: [Any?]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil:               sqlite3_bind_null(stmt, idx)
            case let v as Int:      sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64:    sqlite3_bind_int64(stmt, idx, v)
            case let v as Double:   sqlite3_bind_double(stmt, idx, v)
            case let v as String:   sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: die("unbindable parameter \(String(describing: p))")
            }
        }
    }
}

// Row value helpers: SQLite NULL leaves the key absent.
extension Dictionary where Key == String, Value == Any {
    func i(_ k: String) -> Int64? { self[k] as? Int64 }
    func d(_ k: String) -> Double? { (self[k] as? Double) ?? (self[k] as? Int64).map(Double.init) }
    func s(_ k: String) -> String? { self[k] as? String }
    func b(_ k: String) -> Data? { self[k] as? Data }
    func flag(_ k: String) -> Bool { (i(k) ?? 0) != 0 }
}
