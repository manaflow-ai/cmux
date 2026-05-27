import CMUXMobileCore
import Foundation
import SQLite3
import os

private let pairedMacStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "PairedMacStore")

/// A Mac paired with this iOS device, persisted across launches.
/// Auth tokens are never persisted — only enough to re-mint a fresh attach
/// ticket via the StackAuth-authenticated manual host flow on next launch.
public struct MobilePairedMac: Codable, Equatable, Sendable, Identifiable {
    public var macDeviceID: String
    public var displayName: String?
    public var routes: [CmxAttachRoute]
    public var createdAt: Date
    public var lastSeenAt: Date
    public var isActive: Bool
    public var stackUserID: String?

    public var id: String { macDeviceID }

    public init(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool,
        stackUserID: String?
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.routes = routes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
        self.stackUserID = stackUserID
    }
}

public enum MobilePairedMacStoreError: Error {
    case openFailed(Int32)
    case prepareFailed(Int32, String)
    case stepFailed(Int32, String)
    case unknownSchemaVersion(Int)
    case decodeFailed
}

/// SQLite-backed store of paired Macs. Schema migrations gated on
/// `PRAGMA user_version`. All access must go through the actor's queue.
public final class MobilePairedMacStore: @unchecked Sendable {
    public static let currentSchemaVersion: Int32 = 1

    private let dbPath: String
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "dev.cmux.mobile.pairedMacStore")

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("cmux", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("paired-macs.sqlite3")
    }

    public init(databaseURL: URL) throws {
        self.dbPath = databaseURL.path
        try openAndMigrate()
    }

    public convenience init() throws {
        try self.init(databaseURL: try Self.defaultDatabaseURL())
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Open + migrate

    private func openAndMigrate() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbPath, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw MobilePairedMacStoreError.openFailed(rc)
        }
        self.db = handle
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA journal_mode = WAL;")
        try runMigrations()
    }

    private func runMigrations() throws {
        let version = try userVersion()
        switch version {
        case 0:
            try migrateToV1()
            try setUserVersion(1)
            fallthrough
        case 1:
            break
        default:
            // Future schema; fail closed so we don't corrupt on downgrade.
            throw MobilePairedMacStoreError.unknownSchemaVersion(Int(version))
        }
    }

    private func migrateToV1() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS paired_macs (
                mac_device_id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT,
                stack_user_id TEXT,
                created_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_stack_user ON paired_macs(stack_user_id);")
        try exec("""
            CREATE TABLE IF NOT EXISTS mac_routes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                route_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (mac_device_id) REFERENCES paired_macs(mac_device_id) ON DELETE CASCADE
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_routes_device ON mac_routes(mac_device_id);")
    }

    // MARK: - Public API

    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date = Date()
    ) throws {
        try queue.sync {
            try transaction {
                if markActive {
                    let scope = stackUserID.map(BindValue.text) ?? .null
                    if stackUserID != nil {
                        try exec("UPDATE paired_macs SET is_active = 0 WHERE stack_user_id IS ?;",
                                 binding: [scope])
                    } else {
                        try exec("UPDATE paired_macs SET is_active = 0;")
                    }
                }
                let existing = try fetchMacRow(macDeviceID: macDeviceID)
                let createdAt = existing?.createdAt ?? now
                try upsertMacRow(
                    macDeviceID: macDeviceID,
                    displayName: displayName,
                    stackUserID: stackUserID,
                    createdAt: createdAt,
                    lastSeenAt: now,
                    isActive: markActive
                )
                try exec("DELETE FROM mac_routes WHERE mac_device_id = ?;", binding: [.text(macDeviceID)])
                for route in routes {
                    let encoded = try Self.encodeRoute(route)
                    try exec("""
                        INSERT INTO mac_routes (mac_device_id, route_id, kind, endpoint_json, priority)
                        VALUES (?, ?, ?, ?, ?);
                    """, binding: [
                        .text(macDeviceID),
                        .text(route.id),
                        .text(route.kind.rawValue),
                        .text(encoded),
                        .int(Int64(route.priority)),
                    ])
                }
            }
        }
    }

    public func loadAll(stackUserID: String? = nil) throws -> [MobilePairedMac] {
        try queue.sync {
            try fetchAllMacs(stackUserID: stackUserID)
        }
    }

    public func activeMac(stackUserID: String? = nil) throws -> MobilePairedMac? {
        try queue.sync {
            try fetchAllMacs(activeOnly: true, stackUserID: stackUserID).first
        }
    }

    public func setActive(macDeviceID: String) throws {
        try queue.sync {
            try transaction {
                try exec("UPDATE paired_macs SET is_active = 0;")
                try exec("UPDATE paired_macs SET is_active = 1 WHERE mac_device_id = ?;",
                         binding: [.text(macDeviceID)])
            }
        }
    }

    public func remove(macDeviceID: String) throws {
        try queue.sync {
            try exec("DELETE FROM paired_macs WHERE mac_device_id = ?;",
                     binding: [.text(macDeviceID)])
        }
    }

    public func removeAll() throws {
        try queue.sync {
            try exec("DELETE FROM paired_macs;")
        }
    }

    // MARK: - Internals

    private func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
        return sqlite3_column_int(statement, 0)
    }

    private func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    private struct MacRow {
        let macDeviceID: String
        let displayName: String?
        let stackUserID: String?
        let createdAt: Date
        let lastSeenAt: Date
        let isActive: Bool
    }

    private func fetchMacRow(macDeviceID: String) throws -> MacRow? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT display_name, stack_user_id, created_at, last_seen_at, is_active
            FROM paired_macs WHERE mac_device_id = ?;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(macDeviceID)])
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
        let displayName = Self.readNullableText(statement, column: 0)
        let stackUserID = Self.readNullableText(statement, column: 1)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        let isActive = sqlite3_column_int(statement, 4) != 0
        return MacRow(
            macDeviceID: macDeviceID,
            displayName: displayName,
            stackUserID: stackUserID,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            isActive: isActive
        )
    }

    private func upsertMacRow(
        macDeviceID: String,
        displayName: String?,
        stackUserID: String?,
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool
    ) throws {
        try exec("""
            INSERT INTO paired_macs (mac_device_id, display_name, stack_user_id, created_at, last_seen_at, is_active)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(mac_device_id) DO UPDATE SET
                display_name = excluded.display_name,
                stack_user_id = excluded.stack_user_id,
                last_seen_at = excluded.last_seen_at,
                is_active = excluded.is_active;
        """, binding: [
            .text(macDeviceID),
            displayName.map(BindValue.text) ?? .null,
            stackUserID.map(BindValue.text) ?? .null,
            .real(createdAt.timeIntervalSince1970),
            .real(lastSeenAt.timeIntervalSince1970),
            .int(isActive ? 1 : 0),
        ])
    }

    private func fetchAllMacs(activeOnly: Bool = false, stackUserID: String? = nil) throws -> [MobilePairedMac] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var clauses: [String] = []
        var bindings: [BindValue] = []
        if activeOnly {
            clauses.append("is_active = 1")
        }
        if let stackUserID {
            clauses.append("stack_user_id IS ?")
            bindings.append(.text(stackUserID))
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT mac_device_id, display_name, stack_user_id, created_at, last_seen_at, is_active
            FROM paired_macs
            \(whereClause)
            ORDER BY last_seen_at DESC;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: bindings)
        var rows: [MacRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let macDeviceID = String(cString: cString)
            let displayName = Self.readNullableText(statement, column: 1)
            let storedStackUserID = Self.readNullableText(statement, column: 2)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let isActive = sqlite3_column_int(statement, 5) != 0
            rows.append(MacRow(
                macDeviceID: macDeviceID,
                displayName: displayName,
                stackUserID: storedStackUserID,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                isActive: isActive
            ))
        }

        return try rows.map { row in
            let routes = try fetchRoutes(macDeviceID: row.macDeviceID)
            return MobilePairedMac(
                macDeviceID: row.macDeviceID,
                displayName: row.displayName,
                routes: routes,
                createdAt: row.createdAt,
                lastSeenAt: row.lastSeenAt,
                isActive: row.isActive,
                stackUserID: row.stackUserID
            )
        }
    }

    private func fetchRoutes(macDeviceID: String) throws -> [CmxAttachRoute] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT endpoint_json
            FROM mac_routes
            WHERE mac_device_id = ?
            ORDER BY priority ASC, id ASC;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(macDeviceID)])

        var routes: [CmxAttachRoute] = []
        let decoder = JSONDecoder()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let json = String(cString: cString)
            guard let data = json.data(using: .utf8),
                  let route = try? decoder.decode(CmxAttachRoute.self, from: data) else {
                pairedMacStoreLog.warning("dropping unparsable route row")
                continue
            }
            routes.append(route)
        }
        return routes
    }

    private static func encodeRoute(_ route: CmxAttachRoute) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(route)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MobilePairedMacStoreError.decodeFailed
        }
        return string
    }

    private static func readNullableText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    // MARK: - Statement helpers

    private enum BindValue {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    private func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
        if parameters.isEmpty {
            let rc = sqlite3_exec(db, sql, nil, nil, nil)
            guard rc == SQLITE_OK else {
                throw MobilePairedMacStoreError.stepFailed(rc, lastErrorMessage())
            }
            return
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: parameters)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
    }

    private func bind(statement: OpaquePointer?, parameters: [BindValue]) throws {
        for (index, value) in parameters.enumerated() {
            let pos = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let s):
                rc = s.withCString { ptr in
                    // SQLITE_TRANSIENT == -1; sqlite3 needs to copy the buffer.
                    sqlite3_bind_text(statement, pos, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let i):
                rc = sqlite3_bind_int64(statement, pos, i)
            case .real(let d):
                rc = sqlite3_bind_double(statement, pos, d)
            case .null:
                rc = sqlite3_bind_null(statement, pos)
            }
            guard rc == SQLITE_OK else {
                throw MobilePairedMacStoreError.stepFailed(rc, lastErrorMessage())
            }
        }
    }

    private func transaction(_ block: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try block()
            try exec("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(db) else { return "" }
        return String(cString: cString)
    }
}

/// Provides a process-wide shared paired-mac store, lazily opened.
/// Returns `nil` if the store can't be initialized (e.g. read-only sandbox)
/// so MobileShellStore can degrade to in-memory operation in tests/previews.
public enum MobileShellStorePairedMacStoreFactory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sharedInstance: MobilePairedMacStore?
    nonisolated(unsafe) private static var attempted = false

    public static func shared() -> MobilePairedMacStore? {
        lock.lock()
        defer { lock.unlock() }
        if attempted { return sharedInstance }
        attempted = true
        do {
            sharedInstance = try MobilePairedMacStore()
        } catch {
            pairedMacStoreLog.error("failed to open paired mac store: \(String(describing: error), privacy: .public)")
            sharedInstance = nil
        }
        return sharedInstance
    }

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        sharedInstance = nil
        attempted = false
    }
}

