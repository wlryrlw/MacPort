import Foundation
import SQLite3

struct DiffEngine: Sendable {
    private var previous: [String: PortRecord] = [:]
    private var hasBaseline = false

    mutating func events(for snapshot: ScanSnapshot) -> [PortEvent] {
        let current = snapshot.records.reduce(into: [String: PortRecord]()) { result, record in
            result[record.stableKey] = record
        }
        var events: [PortEvent] = []

        if hasBaseline {
            for (key, record) in current where previous[key] == nil {
                events.append(PortEvent(id: UUID(), occurredAt: snapshot.scannedAt,
                                        type: .opened, port: record, previousValue: nil))
            }
            for (key, oldRecord) in previous where current[key] == nil {
                events.append(PortEvent(id: UUID(), occurredAt: snapshot.scannedAt,
                                        type: .closed, port: oldRecord, previousValue: oldRecord.state))
            }
            for (key, record) in current {
                guard let oldRecord = previous[key] else { continue }
                if oldRecord.state != record.state {
                    events.append(PortEvent(id: UUID(), occurredAt: snapshot.scannedAt,
                                            type: .stateChanged, port: record,
                                            previousValue: oldRecord.state))
                }
                if oldRecord.processID != record.processID || oldRecord.processName != record.processName {
                    events.append(PortEvent(id: UUID(), occurredAt: snapshot.scannedAt,
                                            type: .processChanged, port: record,
                                            previousValue: oldRecord.displayName))
                }
                if oldRecord.visibility != record.visibility {
                    events.append(PortEvent(id: UUID(), occurredAt: snapshot.scannedAt,
                                            type: .visibilityChanged, port: record,
                                            previousValue: oldRecord.visibility.rawValue))
                }
            }
        } else {
            events = current.values.map {
                PortEvent(id: UUID(), occurredAt: snapshot.scannedAt,
                          type: .opened, port: $0, previousValue: nil)
            }
        }

        previous = current
        hasBaseline = true
        return events.sorted { $0.port.stableKey < $1.port.stableKey }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}

private final class SQLiteDatabase: @unchecked Sendable {
    let handle: OpaquePointer

    init(url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle,
                                     SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                                     nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw MacPortError.databaseOpenFailed(detail: message)
        }
        self.handle = handle
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw MacPortError.databaseOperationFailed(detail: message)
        }
    }

    func run(_ sql: String, values: [SQLiteValue] = []) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MacPortError.databaseOperationFailed(detail: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw MacPortError.databaseOperationFailed(detail: String(cString: sqlite3_errmsg(handle)))
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func query(_ sql: String, values: [SQLiteValue] = [], row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MacPortError.databaseOperationFailed(detail: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let string): result = sqlite3_bind_text(statement, position, string, -1, sqliteTransient)
            case .integer(let integer): result = sqlite3_bind_int64(statement, position, integer)
            case .real(let real): result = sqlite3_bind_double(statement, position, real)
            case .null: result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else {
                throw MacPortError.databaseOperationFailed(detail: "SQLite bind failed at \(position)")
            }
        }
    }
}

struct HistoryItem: Identifiable, Sendable {
    let id: Int64
    let occurredAt: Date
    let eventType: PortEventType
    let stableKey: String
    let localPort: UInt16
    let processName: String?
}

actor HistoryStore {
    private let database: SQLiteDatabase
    private let isoFormatter: ISO8601DateFormatter

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        database = try SQLiteDatabase(url: url)
        isoFormatter = ISO8601DateFormatter()
        try database.execute("""
        CREATE TABLE IF NOT EXISTS schema_meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS scan_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at TEXT NOT NULL,
            finished_at TEXT NOT NULL,
            scan_mode TEXT NOT NULL,
            status TEXT NOT NULL,
            record_count INTEGER NOT NULL,
            warning_count INTEGER NOT NULL,
            error_message TEXT
        );
        CREATE TABLE IF NOT EXISTS port_lifecycles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            stable_key TEXT NOT NULL,
            protocol TEXT NOT NULL,
            local_address TEXT NOT NULL,
            local_port INTEGER NOT NULL,
            remote_address TEXT,
            remote_port INTEGER,
            state TEXT,
            process_id INTEGER,
            process_name TEXT,
            user_name TEXT,
            visibility TEXT NOT NULL,
            first_seen_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            ended_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_port_lifecycles_key ON port_lifecycles(stable_key, ended_at);
        CREATE TABLE IF NOT EXISTS port_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lifecycle_id INTEGER NOT NULL,
            occurred_at TEXT NOT NULL,
            event_type TEXT NOT NULL,
            previous_value TEXT,
            FOREIGN KEY(lifecycle_id) REFERENCES port_lifecycles(id)
        );
        CREATE INDEX IF NOT EXISTS idx_port_events_time ON port_events(occurred_at);
        INSERT OR IGNORE INTO schema_meta(key, value) VALUES('version', '1');
        """)
    }

    func record(snapshot: ScanSnapshot, events: [PortEvent]) throws {
        let timestamp = isoFormatter.string(from: snapshot.scannedAt)
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            _ = try database.run("""
            INSERT INTO scan_runs(started_at, finished_at, scan_mode, status, record_count, warning_count)
            VALUES(?, ?, ?, ?, ?, ?)
            """, values: [.text(timestamp), .text(timestamp), .text(snapshot.mode.rawValue),
                            .text(snapshot.warnings.isEmpty ? "success" : "warning"),
                            .integer(Int64(snapshot.records.count)), .integer(Int64(snapshot.warnings.count))])

            for record in snapshot.records {
                let values: [SQLiteValue] = [
                    .text(record.stableKey), .text(record.protocolType.rawValue),
                    .text(record.localEndpoint.address), .integer(Int64(record.localEndpoint.port)),
                    record.remoteEndpoint.map { .text($0.address) } ?? .null,
                    record.remoteEndpoint.map { .integer(Int64($0.port)) } ?? .null,
                    record.state.map(SQLiteValue.text) ?? .null,
                    record.processID.map { .integer(Int64($0)) } ?? .null,
                    record.processName.map(SQLiteValue.text) ?? .null,
                    record.userName.map(SQLiteValue.text) ?? .null,
                    .text(record.visibility.rawValue), .text(timestamp), .text(timestamp)
                ]
                _ = try database.run("""
                UPDATE port_lifecycles SET last_seen_at = ?, state = ?, process_id = ?,
                    process_name = ?, user_name = ?, visibility = ?
                WHERE stable_key = ? AND ended_at IS NULL
                """, values: [.text(timestamp), record.state.map(SQLiteValue.text) ?? .null,
                                record.processID.map { .integer(Int64($0)) } ?? .null,
                                record.processName.map(SQLiteValue.text) ?? .null,
                                record.userName.map(SQLiteValue.text) ?? .null,
                                .text(record.visibility.rawValue), .text(record.stableKey)])
                if try activeLifecycleID(for: record.stableKey) == nil {
                    _ = try database.run("""
                    INSERT INTO port_lifecycles(stable_key, protocol, local_address, local_port,
                        remote_address, remote_port, state, process_id, process_name, user_name,
                        visibility, first_seen_at, last_seen_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, values: values)
                }
            }

            for event in events {
                let key = event.port.stableKey
                if event.type == .closed {
                    _ = try database.run("UPDATE port_lifecycles SET ended_at = ?, last_seen_at = ? WHERE stable_key = ? AND ended_at IS NULL",
                                         values: [.text(timestamp), .text(timestamp), .text(key)])
                }
                let activeID = try activeLifecycleID(for: key)
                let lifecycleID: Int64?
                if let activeID {
                    lifecycleID = activeID
                } else {
                    lifecycleID = try latestLifecycleID(for: key)
                }
                guard let lifecycleID else { continue }
                _ = try database.run("INSERT INTO port_events(lifecycle_id, occurred_at, event_type, previous_value) VALUES(?, ?, ?, ?)",
                                     values: [.integer(lifecycleID), .text(timestamp), .text(event.type.rawValue),
                                              event.previousValue.map(SQLiteValue.text) ?? .null])
            }
            try database.execute("COMMIT;")
        } catch {
            do {
                try database.execute("ROLLBACK;")
            } catch {
                throw MacPortError.databaseOperationFailed(detail: "事务回滚失败：\(error.localizedDescription)；原始错误：\(String(describing: error))")
            }
            throw error
        }
    }

    func recentEvents(limit: Int = 100) throws -> [HistoryItem] {
        var items: [HistoryItem] = []
        try database.query("""
        SELECT e.id, e.occurred_at, e.event_type, l.stable_key, l.local_port, l.process_name
        FROM port_events e JOIN port_lifecycles l ON l.id = e.lifecycle_id
        ORDER BY e.occurred_at DESC LIMIT ?
        """, values: [.integer(Int64(limit))]) { statement in
            guard let dateText = sqlite3_column_text(statement, 1),
                  let typeText = sqlite3_column_text(statement, 2),
                  let keyText = sqlite3_column_text(statement, 3),
                  let eventType = PortEventType(rawValue: String(cString: typeText)) else { return }
            let date = isoFormatter.date(from: String(cString: dateText)) ?? Date.distantPast
            let process = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            items.append(HistoryItem(id: sqlite3_column_int64(statement, 0), occurredAt: date,
                                     eventType: eventType, stableKey: String(cString: keyText),
                                     localPort: UInt16(sqlite3_column_int(statement, 4)), processName: process))
        }
        return items
    }

    func clear() throws {
        try database.execute("DELETE FROM port_events; DELETE FROM port_lifecycles; DELETE FROM scan_runs;")
    }

    private func activeLifecycleID(for stableKey: String) throws -> Int64? {
        var result: Int64?
        try database.query("SELECT id FROM port_lifecycles WHERE stable_key = ? AND ended_at IS NULL ORDER BY id DESC LIMIT 1",
                           values: [.text(stableKey)]) { statement in result = sqlite3_column_int64(statement, 0) }
        return result
    }

    private func latestLifecycleID(for stableKey: String) throws -> Int64? {
        var result: Int64?
        try database.query("SELECT id FROM port_lifecycles WHERE stable_key = ? ORDER BY id DESC LIMIT 1",
                           values: [.text(stableKey)]) { statement in result = sqlite3_column_int64(statement, 0) }
        return result
    }
}

actor DiagnosticsStore {
    private let database: SQLiteDatabase
    private let isoFormatter = ISO8601DateFormatter()
    private let appVersion: String

    init(url: URL, appVersion: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(url: url)
        self.appVersion = appVersion
        try database.execute("""
        CREATE TABLE IF NOT EXISTS diagnostic_events (
            id TEXT PRIMARY KEY NOT NULL,
            code TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_diagnostic_events_time ON diagnostic_events(created_at);
        """)
    }

    func record(_ issue: UserFacingIssue, system: SystemInfo) throws {
        let event = DiagnosticEvent(id: issue.id, issue: issue,
                                    systemVersion: system.version, systemBuild: system.build,
                                    appVersion: appVersion, createdAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw MacPortError.databaseOperationFailed(detail: "诊断事件无法编码")
        }
        _ = try database.run("INSERT OR REPLACE INTO diagnostic_events(id, code, payload, created_at) VALUES(?, ?, ?, ?)",
                             values: [.text(issue.id.uuidString), .text(issue.code), .text(payload),
                                      .text(isoFormatter.string(from: event.createdAt))])
        _ = try database.run("DELETE FROM diagnostic_events WHERE id NOT IN (SELECT id FROM diagnostic_events ORDER BY created_at DESC LIMIT 200)")
    }

    func recent(limit: Int = 200) throws -> [DiagnosticEvent] {
        var events: [DiagnosticEvent] = []
        var decodeError: Error?
        try database.query("SELECT payload FROM diagnostic_events ORDER BY created_at DESC LIMIT ?",
                           values: [.integer(Int64(limit))]) { statement in
            guard let payload = sqlite3_column_text(statement, 0),
                  let data = String(cString: payload).data(using: .utf8) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                events.append(try decoder.decode(DiagnosticEvent.self, from: data))
            } catch {
                decodeError = error
            }
        }
        if let decodeError {
            throw MacPortError.databaseOperationFailed(detail: "诊断记录解码失败：\(decodeError.localizedDescription)")
        }
        return events
    }
}
