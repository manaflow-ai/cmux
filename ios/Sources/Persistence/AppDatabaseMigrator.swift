import GRDB

enum AppDatabaseMigrator {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_terminal_cache") { db in
            try db.create(table: "hosts") { table in
                table.column("host_id", .text).notNull().primaryKey()
                table.column("stable_id", .text).notNull()
                table.column("name", .text).notNull()
                table.column("hostname", .text).notNull()
                table.column("port", .integer).notNull()
                table.column("username", .text).notNull()
                table.column("symbol_name", .text).notNull()
                table.column("palette", .text).notNull()
                table.column("bootstrap_command", .text).notNull()
                table.column("trusted_host_key", .text)
                table.column("pending_host_key", .text)
                table.column("sort_index", .integer).notNull().defaults(to: 0)
                table.column("source", .text).notNull()
                table.column("transport_preference", .text).notNull()
                table.column("ssh_authentication_method", .text).notNull()
                table.column("team_id", .text)
                table.column("server_id", .text)
                table.column("allows_ssh_fallback", .boolean).notNull().defaults(to: true)
                table.column("direct_tls_pins_json", .text).notNull().defaults(to: "[]")
            }

            try db.create(table: "workspaces") { table in
                table.column("workspace_id", .text).notNull().primaryKey()
                table.column("host_id", .text).notNull()
                table.column("title", .text).notNull()
                table.column("tmux_session_name", .text).notNull()
                table.column("preview", .text).notNull().defaults(to: "")
                table.column("last_activity_at", .double).notNull()
                table.column("unread", .boolean).notNull().defaults(to: false)
                table.column("phase", .text).notNull()
                table.column("last_error", .text)
                table.column("backend_identity_json", .text)
                table.column("backend_metadata_json", .text)
                table.column("remote_daemon_resume_state_json", .text)
                table.column("latest_event_seq", .integer).notNull().defaults(to: 0)
                table.column("last_read_event_seq", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "app_metadata") { table in
                table.column("key", .text).notNull().primaryKey()
                table.column("string_value", .text)
            }
        }

        migrator.registerMigration("v2_create_inbox_cache") { db in
            try db.alter(table: "workspaces") { table in
                table.add(column: "machine_id", .text)
            }

            try db.create(table: "inbox_items") { table in
                table.column("item_id", .text).notNull().primaryKey()
                table.column("kind", .text).notNull()
                table.column("conversation_id", .text)
                table.column("workspace_id", .text)
                table.column("machine_id", .text)
                table.column("title", .text).notNull()
                table.column("preview", .text).notNull().defaults(to: "")
                table.column("accessory_label", .text)
                table.column("symbol_name", .text)
                table.column("unread_count", .integer).notNull().defaults(to: 0)
                table.column("sort_timestamp", .double).notNull()
            }

            try db.create(index: "inbox_items_by_sort", on: "inbox_items", columns: ["sort_timestamp"])

            try db.create(table: "workspace_user_state") { table in
                table.column("workspace_id", .text).notNull().primaryKey()
                table.column("last_read_event_seq", .integer).notNull().defaults(to: 0)
                table.column("updated_at", .double).notNull()
            }

            try db.create(table: "machine_presence") { table in
                table.column("machine_id", .text).notNull().primaryKey()
                table.column("display_name", .text).notNull()
                table.column("tailscale_hostname", .text)
                table.column("tailscale_ips_json", .text).notNull().defaults(to: "[]")
                table.column("status", .text).notNull()
                table.column("last_seen_at", .double).notNull()
                table.column("last_workspace_sync_at", .double)
            }
        }

        migrator.registerMigration("v3_expand_mobile_inbox_cache") { db in
            try db.alter(table: "workspaces") { table in
                table.add(column: "remote_workspace_id", .text)
            }

            try db.alter(table: "inbox_items") { table in
                table.add(column: "team_id", .text)
                table.add(column: "tmux_session_name", .text)
                table.add(column: "latest_event_seq", .integer)
                table.add(column: "last_read_event_seq", .integer)
                table.add(column: "tailscale_hostname", .text)
                table.add(column: "tailscale_ips_json", .text).notNull().defaults(to: "[]")
            }
        }

        migrator.registerMigration("v4_prune_seed_placeholder_hosts") { db in
            try db.execute(
                sql: """
                DELETE FROM hosts
                WHERE name = ?
                  AND hostname = ?
                  AND port = 22
                  AND username = ?
                  AND symbol_name = ?
                  AND palette = ?
                  AND bootstrap_command = ?
                  AND trusted_host_key IS NULL
                  AND pending_host_key IS NULL
                  AND sort_index = 0
                  AND source = ?
                  AND transport_preference = ?
                  AND ssh_authentication_method = ?
                  AND team_id IS NULL
                  AND server_id IS NULL
                  AND allows_ssh_fallback = 1
                  AND direct_tls_pins_json = '[]'
                  AND NOT EXISTS (
                    SELECT 1
                    FROM workspaces
                    WHERE workspaces.host_id = hosts.host_id
                  )
                """,
                arguments: [
                    String(localized: "terminal.seed.mac_mini", defaultValue: "Mac Mini"),
                    "cmux-macmini",
                    "cmux",
                    "desktopcomputer",
                    TerminalHostPalette.mint.rawValue,
                    "tmux new-session -A -s {{session}}",
                    TerminalHostSource.custom.rawValue,
                    TerminalTransportPreference.rawSSH.rawValue,
                    TerminalSSHAuthenticationMethod.password.rawValue,
                ]
            )
        }

        return migrator
    }

    static func importLegacySnapshotIfNeeded(
        from legacyStore: TerminalSnapshotPersisting,
        into database: AppDatabase
    ) throws {
        if try database.hasImportedLegacySnapshot {
            return
        }

        if try database.hasPersistedTerminalSnapshot {
            try database.markLegacySnapshotImported()
            return
        }

        try database.writeTerminalSnapshot(legacyStore.load())
        try database.markLegacySnapshotImported()
    }
}
