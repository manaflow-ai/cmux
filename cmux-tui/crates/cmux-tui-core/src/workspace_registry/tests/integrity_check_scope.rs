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
    let tables = checked.lock().unwrap().clone();
    tables
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
    for ledger in ["mutations", "projection_mutations", "terminal_mutations"] {
        assert!(!checked.iter().any(|table| table == ledger), "{ledger} was quick_checked on open");
    }
    fs::remove_dir_all(root).unwrap();
}
