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
