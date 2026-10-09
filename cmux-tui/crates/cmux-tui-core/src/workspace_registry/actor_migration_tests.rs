//! The `resource_mutations.actor` column on a state store written before it
//! existed (P8 slice 3): forward-only, old rows read `legacy`, never `user`,
//! and an older daemon that omits the column keeps working.

use super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-actor-migration-{label}-{}", new_uuid_v4()))
}

/// A ledger row as a daemon without actors writes it.
fn insert_old_row(connection: &Connection, key: &str, revision: i64) {
    connection
        .execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES('resource-api', ?1, 'workspace.create', '{}', '{}', ?2)",
            params![key, revision],
        )
        .unwrap();
}

fn actor_of(registry: &WorkspaceRegistry, key: &str) -> String {
    registry
        .connection
        .query_row(
            "SELECT actor FROM resource_mutations WHERE idempotency_key = ?1",
            [key],
            |row| row.get::<_, String>(0),
        )
        .unwrap()
}

#[test]
fn rows_written_before_the_actor_column_read_legacy_after_the_upgrade() {
    let root = temp_root("old-rows");
    {
        let registry = WorkspaceRegistry::open(&root, "actor-migration").unwrap();
        // The table shape of a store written by a daemon without actors.
        let has_actor = registry
            .connection
            .prepare("PRAGMA table_info(resource_mutations)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .map(Result::unwrap)
            .any(|column| column == "actor");
        if has_actor {
            registry
                .connection
                .execute_batch("ALTER TABLE resource_mutations DROP COLUMN actor;")
                .unwrap();
        }
        insert_old_row(&registry.connection, "old-one", 1);
        insert_old_row(&registry.connection, "old-two", 2);
    }
    let registry = WorkspaceRegistry::open(&root, "actor-migration").unwrap();
    assert_eq!(actor_of(&registry, "old-one"), "legacy");
    assert_eq!(actor_of(&registry, "old-two"), "legacy");
    // An older daemon on the upgraded store: its writes omit the column.
    insert_old_row(&registry.connection, "old-daemon-after", 3);
    assert_eq!(actor_of(&registry, "old-daemon-after"), "legacy");
    drop(registry);
    // A second open is a no-op on the migrated store.
    let registry = WorkspaceRegistry::open(&root, "actor-migration").unwrap();
    assert_eq!(actor_of(&registry, "old-one"), "legacy");
    drop(registry);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn effect_receipts_written_before_the_actor_column_read_legacy() {
    let root = temp_root("old-receipts");
    {
        let registry = WorkspaceRegistry::open(&root, "receipt-migration").unwrap();
        let columns = registry
            .connection
            .prepare("PRAGMA table_info(resource_effect_receipts)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .map(Result::unwrap)
            .collect::<Vec<_>>();
        if columns.iter().any(|column| column == "actor") {
            registry
                .connection
                .execute_batch("ALTER TABLE resource_effect_receipts DROP COLUMN actor;")
                .unwrap();
        }
        registry
            .connection
            .execute(
                "INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES('old-receipt', 'workspace.close', '{}', '{}', 'pending', NULL, NULL)",
                [],
            )
            .unwrap();
    }
    let registry = WorkspaceRegistry::open(&root, "receipt-migration").unwrap();
    let actor: String = registry
        .connection
        .query_row(
            "SELECT actor FROM resource_effect_receipts WHERE idempotency_key = 'old-receipt'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(actor, "legacy");
    drop(registry);
    let _ = fs::remove_dir_all(root);
}

/// The ledgers that predate actors (P8 landing 3b).
const OLDER_LEDGERS: [&str; 4] =
    ["mutations", "terminal_mutations", "projection_mutations", "bookmark_mutations"];

fn has_actor_column(connection: &Connection, table: &str) -> bool {
    connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .map(Result::unwrap)
        .any(|column| column == "actor")
}

/// One row in each older ledger, as a daemon without actors writes it.
fn insert_old_ledger_rows(connection: &Connection, id: &str) {
    for table in ["mutations", "terminal_mutations"] {
        let sql = format!(
            "INSERT INTO {table}(origin, mutation_id, fingerprint, result_json, committed_revision)
             VALUES('old-origin', ?1, '{{}}', '{{}}', 0)"
        );
        connection.execute(&sql, [id]).unwrap();
    }
    connection
        .execute(
            "INSERT INTO projection_mutations(origin, mutation_id, fingerprint, result_json)
             VALUES('old-origin', ?1, '{}', '{}')",
            [id],
        )
        .unwrap();
    connection
        .execute(
            "INSERT INTO bookmark_mutations(origin, mutation_id, operation, fingerprint, result_json)
             VALUES('old-origin', ?1, 'bookmark.create', '{}', '{}')",
            [id],
        )
        .unwrap();
}

/// Design D (landing 2c): a nullable column, so a row from before it, or
/// from an older daemon on the upgraded store, stays NULL and reads `legacy`.
#[test]
fn older_ledgers_gain_a_nullable_actor_and_their_old_rows_read_legacy() {
    let root = temp_root("older-ledgers");
    {
        let registry = WorkspaceRegistry::open(&root, "ledger-migration").unwrap();
        for table in OLDER_LEDGERS {
            if has_actor_column(&registry.connection, table) {
                let sql = format!("ALTER TABLE {table} DROP COLUMN actor;");
                registry.connection.execute_batch(&sql).unwrap();
            }
        }
        insert_old_ledger_rows(&registry.connection, "old");
    }
    let registry = WorkspaceRegistry::open(&root, "ledger-migration").unwrap();
    // An older daemon on the upgraded store omits the column on its writes.
    insert_old_ledger_rows(&registry.connection, "old-daemon-after");
    for table in OLDER_LEDGERS {
        assert!(has_actor_column(&registry.connection, table), "{table} has no actor column");
        let sql = format!("SELECT COUNT(*) FROM {table} WHERE actor IS NOT NULL");
        let stored: i64 = registry.connection.query_row(&sql, [], |row| row.get(0)).unwrap();
        assert_eq!(stored, 0, "{table}: an old row got an actor");
    }
    let tx = registry.connection.unchecked_transaction().unwrap();
    let actor = session_journal::resource_record_actor(&tx, "old-origin", "old", true).unwrap();
    assert_eq!(actor.as_deref(), Some("legacy"), "a NULL ledger actor reads legacy");
    drop(tx);
    drop(registry);
    // A second open is a no-op on the migrated store.
    let registry = WorkspaceRegistry::open(&root, "ledger-migration").unwrap();
    assert!(has_actor_column(&registry.connection, "bookmark_mutations"));
    drop(registry);
    let _ = fs::remove_dir_all(root);
}

/// A fresh journal record takes the actor of the row its own commit wrote,
/// matched by origin and key: a terminal commit writes no resource row, and
/// another origin's row under the same key never lends it its actor.
#[test]
fn a_record_takes_the_actor_of_its_own_origins_row() {
    let root = temp_root("record-origin");
    let registry = WorkspaceRegistry::open(&root, "record-origin").unwrap();
    let tx = registry.connection.unchecked_transaction().unwrap();
    let theirs = WorkspaceMutation::new(
        "shared-key",
        "other-origin",
        Actor::Peer { id: "websocket".into() },
    )
    .unwrap();
    insert_resource_mutation(&tx, &theirs, "workspace.create", "{}", "{}", 1).unwrap();
    let mine = WorkspaceMutation::new("shared-key", "cmux-tui", Actor::local_user()).unwrap();
    let ledger = mutation_ledger::KeyedLedger::Terminal;
    mutation_ledger::insert_keyed_mutation(&tx, ledger, &mine, "{}", "{}", 1).unwrap();
    let actor =
        |origin| session_journal::resource_record_actor(&tx, origin, "shared-key", true).unwrap();
    assert_eq!(actor("cmux-tui").as_deref(), Some("user:user_local"));
    assert_eq!(actor("other-origin").as_deref(), Some("peer:websocket"));
    assert_eq!(actor("nobody").as_deref(), Some("daemon"), "no row: the daemon's own");
    drop(tx);
    drop(registry);
    let _ = fs::remove_dir_all(root);
}
