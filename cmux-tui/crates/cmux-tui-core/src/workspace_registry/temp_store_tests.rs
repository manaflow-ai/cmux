//! The registry connection keeps savepoint journals in memory, and VACUUM
//! keeps its whole-database copy on disk.
//!
//! The journal writer applies each intent in a savepoint. With SQLite's
//! default file temp store, a savepoint that changed more than 64 KiB of
//! pages (an ordinary `terminal write` commit) spilled its journal to a new
//! file in the temp directory on every commit, before the reply.

use super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-temp-store-{label}-{}", new_uuid_v4()))
}

fn temp_store(connection: &Connection) -> i64 {
    connection.query_row("PRAGMA temp_store", [], |row| row.get(0)).unwrap()
}

/// 2 is MEMORY (0 DEFAULT, 1 FILE).
const MEMORY: i64 = 2;
const FILE: i64 = 1;

#[test]
fn registry_connection_keeps_savepoint_journals_in_memory_and_rolls_them_back() {
    let root = temp_root("savepoint");
    let registry = WorkspaceRegistry::open(&root, "temp-store").unwrap();
    let db = registry.connection.get();
    assert_eq!(temp_store(&db), MEMORY);

    // A savepoint that changes far more than the 64 KiB spill size still
    // rolls back exactly from its memory journal.
    db.execute_batch("CREATE TABLE scratch(value BLOB NOT NULL);").unwrap();
    let transaction = db.unchecked_transaction().unwrap();
    transaction.execute("INSERT INTO scratch(value) VALUES(zeroblob(4096))", []).unwrap();
    transaction.execute_batch("SAVEPOINT intent;").unwrap();
    for _ in 0..64 {
        transaction.execute("INSERT INTO scratch(value) VALUES(zeroblob(4096))", []).unwrap();
    }
    transaction.execute("UPDATE scratch SET value = zeroblob(8192)", []).unwrap();
    transaction.execute_batch("ROLLBACK TO intent; RELEASE intent;").unwrap();
    transaction.commit().unwrap();
    let (rows, bytes): (i64, i64) = db
        .query_row("SELECT COUNT(*), SUM(length(value)) FROM scratch", [], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })
        .unwrap();
    assert_eq!((rows, bytes), (1, 4096));
    drop(db);
    drop(registry);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn vacuum_runs_on_a_file_temp_store_and_puts_memory_back() {
    let root = temp_root("vacuum");
    let registry = WorkspaceRegistry::open(&root, "temp-store").unwrap();
    let db = registry.connection.get();

    // The statement after VACUUM records the temp store VACUUM ran with.
    vacuum_with_file_temp_store(
        &db,
        "VACUUM; CREATE TABLE vacuum_temp_store AS SELECT temp_store FROM pragma_temp_store;",
    )
    .unwrap();
    let during: i64 =
        db.query_row("SELECT temp_store FROM vacuum_temp_store", [], |row| row.get(0)).unwrap();
    assert_eq!(during, FILE);
    assert_eq!(temp_store(&db), MEMORY);

    // A failed VACUUM batch still puts the memory temp store back.
    assert!(vacuum_with_file_temp_store(&db, "VACUUM; SELECT * FROM no_such_table;").is_err());
    assert_eq!(temp_store(&db), MEMORY);
    drop(db);
    drop(registry);
    let _ = fs::remove_dir_all(root);
}
