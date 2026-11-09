import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLValue {
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    public var int: Int64? { if case .int(let v) = self { return v }; return nil }
    public var text: String? { if case .text(let v) = self { return v }; return nil }
    public var blob: Data? { if case .blob(let v) = self { return v }; return nil }
}

public final class Database {
    private var handle: OpaquePointer?

    /// `readOnly` never takes write locks and refuses writes, which is what chat.db and Contacts get.
    public init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(description: "\(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            switch param {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .real(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes {
                    sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            case .null: sqlite3_bind_null(statement, position)
            }
        }

        var rows: [[SQLValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else {
                throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
            }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
                    return .blob(Data(bytes: bytes, count: count))
                default: return .null
                }
            })
        }
    }
}
