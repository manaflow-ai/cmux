use super::*;
use rusqlite::hooks::{AuthAction, Authorization};
use std::sync::Mutex;

/// The tables `check_registry_integrity` runs `PRAGMA quick_check` on.
fn quick_checked_tables(database: &Path) -> Vec<String> {
    let connection = Connection::open(database).unwrap();
    let checked = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&checked);
    connection
        .authorizer(Some(move |context: rusqlite::hooks::AuthContext<'_>| {
            if let AuthAction::Pragma { pragma_name, pragma_value: Some(table) } = context.action
                && pragma_name.eq_ignore_ascii_case("quick_check")
            {
                sink.lock().unwrap().push(table.trim_matches('\'').to_string());
            }
            Authorization::Allow
        }))
        .unwrap();
    check_registry_integrity(&connection).unwrap();
    checked.lock().unwrap().clone()
}

/// The mutation ledgers keep every write's result for idempotent retries and
/// are only read by primary key, so a quick_check over them made startup
/// track their size: a nightly's 1 GB `projection_mutations` held the
/// daemon's socket back for 40 s after launch.
#[test]
fn open_integrity_check_skips_mutation_ledgers() {
    let root = temp_root("integrity-check-scope");
    let registry = WorkspaceRegistry::open(&root, "integrity-check-scope").unwrap();
    let database = registry.session_journal_database_path().unwrap();
    drop(registry);

    let checked = quick_checked_tables(&database);
    assert!(
        checked.iter().any(|table| table == "workspaces"),
        "state tables stay checked: {checked:?}"
    );
    assert!(
        checked.iter().any(|table| table == "resource_mutations"),
        "resource_mutations holds restored state and stays checked: {checked:?}"
    );
    for ledger in
        ["mutations", "projection_mutations", "terminal_mutations", "journal_ingress_receipts"]
    {
        assert!(!checked.iter().any(|table| table == ledger), "{ledger} was quick_checked on open");
    }
    fs::remove_dir_all(root).unwrap();
}

/// The open-time foreign-key check covers the registry state the open migrates
/// with foreign keys off, not the receipt ledgers: on a 41 GB nightly registry a
/// whole-database `pragma_foreign_key_check` walked 588k ingress receipts and,
/// with their quick_check, held the daemon's socket for about 10 s of a 27 s
/// cold launch while every restored terminal said "Restoring…".
#[test]
fn open_foreign_key_check_skips_receipt_ledgers() {
    let root = temp_root("fk-check-scope");
    let database = {
        let registry = WorkspaceRegistry::open(&root, "fk-check-scope").unwrap();
        registry.session_journal_database_path().unwrap()
    };
    let connection = Connection::open(&database).unwrap();
    connection.execute_batch("PRAGMA foreign_keys=OFF;").unwrap();
    // A receipt naming a producer the ledger no longer has: a violation only a
    // scan of the whole ledger finds.
    connection
        .execute(
            "INSERT INTO journal_ingress_receipts(
               producer_id, origin, idempotency_key, fingerprint, event_id,
               journal_sequence, result_json
             ) VALUES('gone-producer', 'origin', 'key', zeroblob(32), 'event-gone', 999999, '{}')",
            [],
        )
        .unwrap();
    drop(connection);

    WorkspaceRegistry::open(&root, "fk-check-scope")
        .expect("a receipt ledger row is not checked on open");
    fs::remove_dir_all(root).unwrap();
}
