import XCTest
import GRDB
@testable import cmux_DEV

final class AppDatabaseTests: XCTestCase {
    func testUnreadStateRoundTripsThroughDatabase() throws {
        let db = try AppDatabase.inMemory()
        try db.writeWorkspace(
            id: "ws_123",
            title: "orb / cmux",
            latestEventSeq: 4,
            lastReadEventSeq: 2
        )
        let row = try db.readWorkspace(id: "ws_123")
        XCTAssertEqual(row?.isUnread, true)
    }

    func testWorkspaceInboxUnreadCountTracksUnreadSequenceGap() throws {
        let db = try AppDatabase.inMemory()
        try db.writeWorkspace(
            id: "ws_123",
            title: "orb / cmux",
            preview: "feature/cache-first",
            machineID: "machine_123",
            lastActivityAt: Date(timeIntervalSince1970: 1_710_000_000),
            latestEventSeq: 9,
            lastReadEventSeq: 6
        )

        let row = try XCTUnwrap(db.readWorkspaceInboxRows().first)
        XCTAssertEqual(row.workspaceID, "ws_123")
        XCTAssertEqual(row.unreadCount, 3)
    }

    func testImportsLegacyTerminalSnapshot() throws {
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon,
            sshAuthenticationMethod: .privateKey,
            teamID: "team_123",
            serverID: "server_123",
            allowsSSHFallback: false,
            directTLSPins: ["pin_a", "pin_b"]
        )
        let workspace = TerminalWorkspace(
            hostID: host.id,
            title: "orb / cmux",
            tmuxSessionName: "cmux-orb",
            preview: "feature/inbox",
            lastActivity: Date(timeIntervalSince1970: 1_710_000_000),
            unread: true,
            phase: .connected,
            lastError: "boom",
            backendIdentity: TerminalWorkspaceBackendIdentity(
                teamID: "team_123",
                taskID: "task_123",
                taskRunID: "task_run_123",
                workspaceName: "orb-123",
                descriptor: "Orb #123"
            ),
            backendMetadata: TerminalWorkspaceBackendMetadata(preview: "feature/inbox"),
            remoteDaemonResumeState: TerminalRemoteDaemonResumeState(
                sessionID: "session_123",
                attachmentID: "attachment_123",
                readOffset: 42
            )
        )
        let legacySnapshot = TerminalStoreSnapshot(
            hosts: [host],
            workspaces: [workspace],
            selectedWorkspaceID: workspace.id
        )
        let legacyStore = InMemoryTerminalSnapshotStore(snapshot: legacySnapshot)
        let db = try AppDatabase.inMemory()

        try AppDatabaseMigrator.importLegacySnapshotIfNeeded(from: legacyStore, into: db)

        XCTAssertEqual(try db.fetchHostCount(), 1)
        XCTAssertEqual(try db.readTerminalSnapshot(), legacySnapshot)
    }

    func testFreshDatabaseStartsWithNoPlaceholderHost() throws {
        let db = try AppDatabase.inMemory()

        XCTAssertEqual(try db.readTerminalSnapshot(), .empty())
        XCTAssertEqual(try db.fetchHostCount(), 0)
    }

    func testMigratorPrunesLegacySeedPlaceholderHost() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        let migrator = AppDatabaseMigrator.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v3_expand_mobile_inbox_cache")
        try dbQueue.write { db in
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
                    UUID().uuidString,
                    UUID().uuidString,
                    String(localized: "terminal.seed.mac_mini", defaultValue: "Mac Mini"),
                    "cmux-macmini",
                    22,
                    "cmux",
                    "desktopcomputer",
                    TerminalHostPalette.mint.rawValue,
                    "tmux new-session -A -s {{session}}",
                    nil,
                    nil,
                    0,
                    TerminalHostSource.custom.rawValue,
                    TerminalTransportPreference.rawSSH.rawValue,
                    TerminalSSHAuthenticationMethod.password.rawValue,
                    nil,
                    nil,
                    true,
                    "[]",
                ]
            )
        }

        try migrator.migrate(dbQueue)

        let db = try AppDatabase(path: databaseURL.path)
        XCTAssertEqual(try db.readTerminalSnapshot(), .empty())
        XCTAssertEqual(try db.fetchHostCount(), 0)
    }
}
