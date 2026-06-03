import Foundation
import GRDB

final class AppDatabase {
    private enum MetadataKey {
        static let legacySnapshotImported = "legacy_terminal_snapshot_imported"
        static let selectedWorkspaceID = "selected_workspace_id"
    }

    enum Error: Swift.Error {
        case invalidUUID(table: String, column: String, value: String)
        case invalidEnum(table: String, column: String, value: String)
    }

    struct WorkspaceRow: FetchableRecord, Equatable, Sendable {
        let workspaceID: String
        let title: String
        let latestEventSeq: Int
        let lastReadEventSeq: Int

        init(row: Row) {
            workspaceID = row["workspace_id"]
            title = row["title"]
            latestEventSeq = row["latest_event_seq"]
            lastReadEventSeq = row["last_read_event_seq"]
        }

        var isUnread: Bool {
            latestEventSeq > lastReadEventSeq
        }
    }

    struct WorkspaceInboxRow: FetchableRecord, Equatable, Sendable {
        let workspaceID: String
        let machineID: String?
        let teamID: String?
        let title: String
        let preview: String
        let lastActivityAt: Date
        let tmuxSessionName: String?
        let latestEventSeq: Int
        let lastReadEventSeq: Int
        let machineDisplayName: String?
        let tailscaleHostname: String?
        let tailscaleIPs: [String]

        init(
            workspaceID: String,
            machineID: String?,
            teamID: String? = nil,
            title: String,
            preview: String,
            lastActivityAt: Date,
            tmuxSessionName: String? = nil,
            latestEventSeq: Int,
            lastReadEventSeq: Int,
            machineDisplayName: String? = nil,
            tailscaleHostname: String? = nil,
            tailscaleIPs: [String] = []
        ) {
            self.workspaceID = workspaceID
            self.machineID = machineID
            self.teamID = teamID
            self.title = title
            self.preview = preview
            self.lastActivityAt = lastActivityAt
            self.tmuxSessionName = tmuxSessionName
            self.latestEventSeq = latestEventSeq
            self.lastReadEventSeq = lastReadEventSeq
            self.machineDisplayName = machineDisplayName
            self.tailscaleHostname = tailscaleHostname
            self.tailscaleIPs = tailscaleIPs
        }

        init(row: Row) {
            workspaceID = row["workspace_id"]
            machineID = row["machine_id"]
            teamID = row["team_id"]
            title = row["title"]
            preview = row["preview"]
            lastActivityAt = Date(timeIntervalSince1970: row["last_activity_at"])
            tmuxSessionName = row["tmux_session_name"]
            latestEventSeq = row["latest_event_seq"]
            lastReadEventSeq = row["last_read_event_seq"]
            machineDisplayName = row["accessory_label"]
            tailscaleHostname = row["tailscale_hostname"]
            let tailscaleIPsJSON: String = row["tailscale_ips_json"]
            tailscaleIPs = (try? JSONDecoder().decode([String].self, from: Data(tailscaleIPsJSON.utf8))) ?? []
        }

        var unreadCount: Int {
            max(0, latestEventSeq - lastReadEventSeq)
        }
    }

    private let dbQueue: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(path: String) throws {
        let fileURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbQueue = try DatabaseQueue(path: path)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try AppDatabaseMigrator.makeMigrator().migrate(dbQueue)
    }

    static func inMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        let database = AppDatabase(dbQueue: dbQueue)
        try AppDatabaseMigrator.makeMigrator().migrate(dbQueue)
        return database
    }

    static func live() throws -> AppDatabase {
        try AppDatabase(path: defaultDatabaseURL().path)
    }

    func writeWorkspace(
        id: String,
        title: String,
        preview: String = "",
        machineID: String? = nil,
        lastActivityAt: Date = .now,
        latestEventSeq: Int,
        lastReadEventSeq: Int
    ) throws {
        let isUnread = latestEventSeq > lastReadEventSeq
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO workspaces (
                    workspace_id,
                    host_id,
                    machine_id,
                    title,
                    tmux_session_name,
                    preview,
                    last_activity_at,
                    unread,
                    phase,
                    latest_event_seq,
                    last_read_event_seq
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(workspace_id) DO UPDATE SET
                    machine_id = excluded.machine_id,
                    title = excluded.title,
                    preview = excluded.preview,
                    last_activity_at = excluded.last_activity_at,
                    unread = excluded.unread,
                    phase = excluded.phase,
                    latest_event_seq = excluded.latest_event_seq,
                    last_read_event_seq = excluded.last_read_event_seq
                """,
                arguments: [
                    id,
                    UUID().uuidString,
                    machineID,
                    title,
                    "cmux-\(id)",
                    preview,
                    lastActivityAt.timeIntervalSince1970,
                    isUnread,
                    TerminalConnectionPhase.idle.rawValue,
                    latestEventSeq,
                    lastReadEventSeq,
                ]
            )
        }
    }

    func readWorkspace(id: String) throws -> WorkspaceRow? {
        try dbQueue.read { db in
            try WorkspaceRow.fetchOne(
                db,
                sql: """
                SELECT
                    workspace_id,
                    title,
                    latest_event_seq,
                    last_read_event_seq
                FROM workspaces
                WHERE workspace_id = ?
                """,
                arguments: [id]
            )
        }
    }

    func readWorkspaceInboxRows() throws -> [WorkspaceInboxRow] {
        try dbQueue.read { db in
            try WorkspaceInboxRow.fetchAll(
                db,
                sql: """
                SELECT
                    workspace_id,
                    machine_id,
                    NULL AS team_id,
                    title,
                    preview,
                    last_activity_at,
                    tmux_session_name,
                    latest_event_seq,
                    last_read_event_seq,
                    NULL AS accessory_label,
                    NULL AS tailscale_hostname,
                    '[]' AS tailscale_ips_json
                FROM workspaces
                ORDER BY last_activity_at DESC
                """
            )
        }
    }

    func readCachedInboxItems() throws -> [UnifiedInboxItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    item_id,
                    kind,
                    conversation_id,
                    workspace_id,
                    machine_id,
                    team_id,
                    title,
                    preview,
                    accessory_label,
                    symbol_name,
                    unread_count,
                    sort_timestamp,
                    tmux_session_name,
                    latest_event_seq,
                    last_read_event_seq,
                    tailscale_hostname,
                    tailscale_ips_json
                FROM inbox_items
                ORDER BY sort_timestamp DESC, item_id ASC
                """
            )

            return try rows.map(decodeInboxItem(from:))
        }
    }

    func replaceCachedInboxItems(_ items: [UnifiedInboxItem]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM inbox_items")
            for item in items {
                try db.execute(
                    sql: """
                    INSERT INTO inbox_items (
                        item_id,
                        kind,
                        conversation_id,
                        workspace_id,
                        machine_id,
                        team_id,
                        title,
                        preview,
                        accessory_label,
                        symbol_name,
                        unread_count,
                        sort_timestamp,
                        tmux_session_name,
                        latest_event_seq,
                        last_read_event_seq,
                        tailscale_hostname,
                        tailscale_ips_json
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        item.id,
                        item.kind.rawValue,
                        item.conversationID,
                        item.workspaceID,
                        item.machineID,
                        item.teamID,
                        item.title,
                        item.preview,
                        item.accessoryLabel,
                        item.symbolName,
                        item.unreadCount,
                        item.sortDate.timeIntervalSince1970,
                        item.tmuxSessionName,
                        item.latestEventSeq,
                        item.lastReadEventSeq,
                        item.tailscaleHostname,
                        try encodeJSONString(item.tailscaleIPs) ?? "[]",
                    ]
                )
            }
        }
    }

    func fetchHostCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hosts") ?? 0
        }
    }

    var hasPersistedTerminalSnapshot: Bool {
        get throws {
            try dbQueue.read { db in
                let hostCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hosts") ?? 0
                let workspaceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspaces") ?? 0
                return hostCount > 0 || workspaceCount > 0
            }
        }
    }

    var hasImportedLegacySnapshot: Bool {
        get throws {
            try metadataValue(forKey: MetadataKey.legacySnapshotImported) == "1"
        }
    }

    func markLegacySnapshotImported() throws {
        try setMetadataValue("1", forKey: MetadataKey.legacySnapshotImported)
    }

    func readTerminalSnapshot() throws -> TerminalStoreSnapshot {
        try dbQueue.read { db in
            let hosts = try Row.fetchAll(db, sql: "SELECT * FROM hosts ORDER BY sort_index ASC")
                .map(decodeHost(from:))
            let workspaces = try Row.fetchAll(
                db,
                sql: "SELECT * FROM workspaces ORDER BY last_activity_at DESC"
            )
            .map(decodeWorkspace(from:))
            let selectedWorkspaceID = try String.fetchOne(
                db,
                sql: "SELECT string_value FROM app_metadata WHERE key = ?",
                arguments: [MetadataKey.selectedWorkspaceID]
            )
                .flatMap(UUID.init(uuidString:))

            if hosts.isEmpty && workspaces.isEmpty {
                return .empty()
            }

            return TerminalStoreSnapshot(
                hosts: hosts,
                workspaces: workspaces,
                selectedWorkspaceID: selectedWorkspaceID
            )
        }
    }

    func writeTerminalSnapshot(_ snapshot: TerminalStoreSnapshot) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM hosts")
            try db.execute(sql: "DELETE FROM workspaces")
            let machineIDsByHostID = Dictionary(
                snapshot.hosts.map { ($0.id, $0.effectiveServerID) },
                uniquingKeysWith: { _, last in last }
            )

            for host in snapshot.hosts {
                try db.execute(
                    sql: """
                    INSERT INTO hosts (
                        host_id,
                        stable_id,
                        name,
                        hostname,
                        port,
                        username,
                        symbol_name,
                        palette,
                        bootstrap_command,
                        trusted_host_key,
                        pending_host_key,
                        sort_index,
                        source,
                        transport_preference,
                        ssh_authentication_method,
                        team_id,
                        server_id,
                        allows_ssh_fallback,
                        direct_tls_pins_json
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        host.id.uuidString,
                        host.stableID,
                        host.name,
                        host.hostname,
                        host.port,
                        host.username,
                        host.symbolName,
                        host.palette.rawValue,
                        host.bootstrapCommand,
                        host.trustedHostKey,
                        host.pendingHostKey,
                        host.sortIndex,
                        host.source.rawValue,
                        host.transportPreference.rawValue,
                        host.sshAuthenticationMethod.rawValue,
                        host.teamID,
                        host.serverID,
                        host.allowsSSHFallback,
                        try encodeJSONString(host.directTLSPins) ?? "[]",
                    ]
                )
            }

            for workspace in snapshot.workspaces {
                let latestEventSeq = workspace.unread ? 1 : 0
                let lastReadEventSeq = workspace.unread ? 0 : latestEventSeq

                try db.execute(
                    sql: """
                    INSERT INTO workspaces (
                        workspace_id,
                        host_id,
                        machine_id,
                        remote_workspace_id,
                        title,
                        tmux_session_name,
                        preview,
                        last_activity_at,
                        unread,
                        phase,
                        last_error,
                        backend_identity_json,
                        backend_metadata_json,
                        remote_daemon_resume_state_json,
                        latest_event_seq,
                        last_read_event_seq
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        workspace.id.uuidString,
                        workspace.hostID.uuidString,
                        machineIDsByHostID[workspace.hostID],
                        workspace.remoteWorkspaceID,
                        workspace.title,
                        workspace.tmuxSessionName,
                        workspace.preview,
                        workspace.lastActivity.timeIntervalSince1970,
                        workspace.unread,
                        workspace.phase.rawValue,
                        workspace.lastError,
                        try encodeJSONString(workspace.backendIdentity),
                        try encodeJSONString(workspace.backendMetadata),
                        try encodeJSONString(workspace.remoteDaemonResumeState),
                        latestEventSeq,
                        lastReadEventSeq,
                    ]
                )
            }

            try setMetadataValue(
                snapshot.selectedWorkspaceID?.uuidString,
                forKey: MetadataKey.selectedWorkspaceID,
                in: db
            )
        }
    }

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    private static func defaultDatabaseURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("cmux.sqlite")
    }

    private func metadataValue(forKey key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT string_value FROM app_metadata WHERE key = ?",
                arguments: [key]
            )
        }
    }

    private func setMetadataValue(_ value: String?, forKey key: String) throws {
        try dbQueue.write { db in
            try setMetadataValue(value, forKey: key, in: db)
        }
    }

    private func setMetadataValue(_ value: String?, forKey key: String, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO app_metadata (key, string_value)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET string_value = excluded.string_value
            """,
            arguments: [key, value]
        )
    }

    private func decodeHost(from row: Row) throws -> TerminalHost {
        let hostID = try decodeUUID(from: row, column: "host_id", table: "hosts")
        let paletteRaw: String = row["palette"]
        let sourceRaw: String = row["source"]
        let transportPreferenceRaw: String = row["transport_preference"]
        let sshAuthenticationMethodRaw: String = row["ssh_authentication_method"]

        guard let palette = TerminalHostPalette(rawValue: paletteRaw) else {
            throw Error.invalidEnum(table: "hosts", column: "palette", value: paletteRaw)
        }
        guard let source = TerminalHostSource(rawValue: sourceRaw) else {
            throw Error.invalidEnum(table: "hosts", column: "source", value: sourceRaw)
        }
        guard let transportPreference = TerminalTransportPreference(rawValue: transportPreferenceRaw) else {
            throw Error.invalidEnum(
                table: "hosts",
                column: "transport_preference",
                value: transportPreferenceRaw
            )
        }
        guard let sshAuthenticationMethod = TerminalSSHAuthenticationMethod(rawValue: sshAuthenticationMethodRaw) else {
            throw Error.invalidEnum(
                table: "hosts",
                column: "ssh_authentication_method",
                value: sshAuthenticationMethodRaw
            )
        }

        return TerminalHost(
            id: hostID,
            stableID: row["stable_id"],
            name: row["name"],
            hostname: row["hostname"],
            port: row["port"],
            username: row["username"],
            symbolName: row["symbol_name"],
            palette: palette,
            bootstrapCommand: row["bootstrap_command"],
            trustedHostKey: row["trusted_host_key"],
            pendingHostKey: row["pending_host_key"],
            sortIndex: row["sort_index"],
            source: source,
            transportPreference: transportPreference,
            sshAuthenticationMethod: sshAuthenticationMethod,
            teamID: row["team_id"],
            serverID: row["server_id"],
            allowsSSHFallback: row["allows_ssh_fallback"],
            directTLSPins: try decodeJSON([String].self, from: row["direct_tls_pins_json"]) ?? []
        )
    }

    private func decodeWorkspace(from row: Row) throws -> TerminalWorkspace {
        let workspaceID = try decodeUUID(from: row, column: "workspace_id", table: "workspaces")
        let hostID = try decodeUUID(from: row, column: "host_id", table: "workspaces")
        let phaseRaw: String = row["phase"]

        guard let phase = TerminalConnectionPhase(rawValue: phaseRaw) else {
            throw Error.invalidEnum(table: "workspaces", column: "phase", value: phaseRaw)
        }

        return TerminalWorkspace(
            id: workspaceID,
            hostID: hostID,
            title: row["title"],
            tmuxSessionName: row["tmux_session_name"],
            preview: row["preview"],
            lastActivity: Date(timeIntervalSince1970: row["last_activity_at"]),
            unread: row["unread"],
            phase: phase,
            lastError: row["last_error"],
            remoteWorkspaceID: row["remote_workspace_id"],
            backendIdentity: try decodeJSON(
                TerminalWorkspaceBackendIdentity.self,
                from: row["backend_identity_json"]
            ),
            backendMetadata: try decodeJSON(
                TerminalWorkspaceBackendMetadata.self,
                from: row["backend_metadata_json"]
            ),
            remoteDaemonResumeState: try decodeJSON(
                TerminalRemoteDaemonResumeState.self,
                from: row["remote_daemon_resume_state_json"]
            )
        )
    }

    private func decodeInboxItem(from row: Row) throws -> UnifiedInboxItem {
        let kindRaw: String = row["kind"]
        guard let kind = UnifiedInboxKind(rawValue: kindRaw) else {
            throw Error.invalidEnum(table: "inbox_items", column: "kind", value: kindRaw)
        }

        return UnifiedInboxItem(
            kind: kind,
            conversationID: row["conversation_id"],
            workspaceID: row["workspace_id"],
            machineID: row["machine_id"],
            teamID: row["team_id"],
            title: row["title"],
            preview: row["preview"],
            unreadCount: row["unread_count"],
            sortDate: Date(timeIntervalSince1970: row["sort_timestamp"]),
            accessoryLabel: row["accessory_label"],
            symbolName: row["symbol_name"],
            tmuxSessionName: row["tmux_session_name"],
            latestEventSeq: row["latest_event_seq"],
            lastReadEventSeq: row["last_read_event_seq"],
            tailscaleHostname: row["tailscale_hostname"],
            tailscaleIPs: try decodeJSON([String].self, from: row["tailscale_ips_json"]) ?? []
        )
    }

    private func decodeUUID(from row: Row, column: String, table: String) throws -> UUID {
        let value: String = row[column]
        guard let uuid = UUID(uuidString: value) else {
            throw Error.invalidUUID(table: table, column: column, value: value)
        }
        return uuid
    }

    private func encodeJSONString<Value: Encodable>(_ value: Value?) throws -> String? {
        guard let value else { return nil }
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeJSON<Value: Decodable>(_ type: Value.Type, from string: String?) throws -> Value? {
        guard let string, !string.isEmpty else { return nil }
        return try decoder.decode(type, from: Data(string.utf8))
    }
}
