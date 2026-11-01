use super::*;
use crate::workspace_registry::mutation_ledger_retention::{
    MUTATION_LEDGERS, scan_mutation_ledgers,
};

fn ledger_rowids(registry: &WorkspaceRegistry, table: &str) -> Vec<i64> {
    let connection = registry.connection.get();
    let mut statement =
        connection.prepare(&format!("SELECT rowid FROM {table} ORDER BY rowid")).unwrap();
    statement.query_map([], |row| row.get(0)).unwrap().collect::<Result<_, _>>().unwrap()
}

/// Appends `rows` ledger rows straight through SQL, each with a result of
/// `result_bytes` bytes.
fn fill_ledger(registry: &WorkspaceRegistry, table: &str, rows: usize, result_bytes: usize) {
    let connection = registry.connection.get();
    let transaction = connection.unchecked_transaction().unwrap();
    let (columns, values) =
        if table == "projection_mutations" { ("", "") } else { (", committed_revision", ", 1") };
    let result = format!("\"{}\"", "r".repeat(result_bytes));
    let start: i64 = transaction
        .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row.get(0))
        .unwrap();
    for index in 0..rows {
        transaction
            .execute(
                &format!(
                    "INSERT INTO {table}(origin, mutation_id, fingerprint, result_json{columns})
                     VALUES('fill', ?1, 'fingerprint', ?2{values})"
                ),
                params![format!("fill-{}", start + index as i64), result],
            )
            .unwrap();
    }
    transaction.commit().unwrap();
}

fn table_schema(registry: &WorkspaceRegistry, table: &str) -> String {
    registry
        .connection
        .get()
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get(0),
        )
        .unwrap()
}

/// The ledgers grew with every write until one held 1 GB. Retention keeps
/// each one's newest rows, frees at most one batch per call so a large
/// ledger drains across maintenance ticks, and keeps the newest results
/// replayable.
#[test]
fn ledger_retention_keeps_each_ledgers_newest_rows() {
    let root = temp_root("ledger-retention");
    let mut registry = WorkspaceRegistry::open(&root, "ledger-retention").unwrap();
    for ledger in &MUTATION_LEDGERS {
        fill_ledger(&registry, ledger.table, ledger.capacity + 2 * ledger.batch + 7, 8);
    }
    let retained = WorkspaceMutation::daemon("layout-retained", "cmux-tui").unwrap();
    let put = |registry: &mut WorkspaceRegistry| {
        registry
            .put_frontend_projection(
                &retained,
                "cmux-tui",
                "window-group",
                "group-a",
                1,
                Some(0),
                &json!({"columns": []}),
            )
            .unwrap()
    };
    assert!(!put(&mut registry).replayed);
    let before: Vec<Vec<i64>> =
        MUTATION_LEDGERS.iter().map(|ledger| ledger_rowids(&registry, ledger.table)).collect();

    let first = registry.prune_mutation_ledgers().unwrap().deleted;
    assert_eq!(
        first,
        MUTATION_LEDGERS.iter().map(|ledger| ledger.batch).sum::<usize>(),
        "one call frees one batch per ledger"
    );
    let mut calls = 1;
    while registry.prune_mutation_ledgers().unwrap().deleted > 0 {
        calls += 1;
        assert!(calls < 10, "retention never converged");
    }
    assert_eq!(calls, 3, "two full batches and a partial one");

    for (ledger, before) in MUTATION_LEDGERS.iter().zip(before) {
        let after = ledger_rowids(&registry, ledger.table);
        assert_eq!(
            after,
            before[before.len() - ledger.capacity..],
            "{} keeps exactly its newest {} rows",
            ledger.table,
            ledger.capacity
        );
    }
    assert!(put(&mut registry).replayed, "the newest result still replays");
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// A corrupt ledger page fails every commit that writes there, and the open
/// check no longer reads the whole ledger. Pruning past the bound reaches the
/// oldest page first, so it reports the damage without stopping the other
/// ledgers; the scan confirms it, and quarantine sets the damaged table aside
/// and recreates the ledger, so writes go on and later opens skip the copy.
#[test]
fn ledger_scan_finds_and_quarantines_a_corrupt_ledger() {
    let root = temp_root("ledger-quarantine");
    let registry = WorkspaceRegistry::open(&root, "ledger-quarantine").unwrap();
    let database = registry.session_journal_database_path().unwrap();
    let capacity = MUTATION_LEDGERS[0].capacity;
    fill_ledger(&registry, "terminal_mutations", capacity + 100, 200);
    fill_ledger(&registry, "mutations", capacity + 10, 8);
    let schema = table_schema(&registry, "terminal_mutations");
    drop(registry);
    assert!(scan_mutation_ledgers(&database).unwrap().is_empty(), "a fresh registry scans clean");

    // Overwrite the ledger's first leaf. The open check reads only the
    // newest rows, which sit on the last leaf.
    let (page_size, root_page) = {
        let connection = Connection::open(&database).unwrap();
        let (busy, _, _): (i64, i64, i64) = connection
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .unwrap();
        assert_eq!(busy, 0, "the main file holds every commit before it is edited");
        let page_size: i64 =
            connection.query_row("PRAGMA page_size", [], |row| row.get(0)).unwrap();
        let root_page: i64 = connection
            .query_row(
                "SELECT rootpage FROM sqlite_master WHERE name = 'terminal_mutations'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        (usize::try_from(page_size).unwrap(), usize::try_from(root_page).unwrap())
    };
    let mut bytes = fs::read(&database).unwrap();
    let root_offset = (root_page - 1) * page_size;
    assert_eq!(bytes[root_offset], 0x05, "the ledger's root is an interior table page");
    let cell = usize::from(u16::from_be_bytes([bytes[root_offset + 12], bytes[root_offset + 13]]));
    let child =
        u32::from_be_bytes(bytes[root_offset + cell..root_offset + cell + 4].try_into().unwrap())
            as usize;
    let child_offset = (child - 1) * page_size;
    bytes[child_offset..child_offset + page_size].fill(0xAB);
    fs::write(&database, bytes).unwrap();

    let mut registry = WorkspaceRegistry::open(&root, "ledger-quarantine").unwrap();
    let prune = registry.prune_mutation_ledgers().unwrap();
    assert_eq!(prune.corrupt, ["terminal_mutations"]);
    assert_eq!(prune.deleted, 10, "the intact ledger is still pruned");
    let corrupt = scan_mutation_ledgers(&database).unwrap();
    assert_eq!(
        corrupt.iter().map(|(table, _)| *table).collect::<Vec<_>>(),
        ["terminal_mutations"],
        "{corrupt:?}"
    );
    let aside = registry.quarantine_mutation_ledger("terminal_mutations").unwrap();
    assert!(aside.starts_with("terminal_mutations_quarantined_"), "{aside}");
    assert!(ledger_rowids(&registry, "terminal_mutations").is_empty());
    assert_eq!(table_schema(&registry, "terminal_mutations"), schema);
    fill_ledger(&registry, "terminal_mutations", 1, 8);
    assert_eq!(ledger_rowids(&registry, "terminal_mutations").len(), 1);
    drop(registry);

    let registry = WorkspaceRegistry::open(&root, "ledger-quarantine")
        .expect("open skips the quarantined ledger");
    assert!(scan_mutation_ledgers(&database).unwrap().is_empty());
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

fn pragma_count(registry: &WorkspaceRegistry, pragma: &str) -> i64 {
    registry.connection.get().query_row(&format!("PRAGMA {pragma}"), [], |row| row.get(0)).unwrap()
}

/// Pruned ledger rows leave free pages; one maintenance step must return up
/// to 256 of them, not one, or an idle owner keeps waking until they are gone.
#[test]
fn one_incremental_vacuum_step_returns_up_to_256_free_pages() {
    let root = temp_root("incremental-vacuum-step");
    let registry = WorkspaceRegistry::open(&root, "incremental-vacuum-step").unwrap();
    assert_eq!(pragma_count(&registry, "auto_vacuum"), 2, "a fresh registry vacuums incrementally");
    fill_ledger(&registry, "projection_mutations", 400, 8 * 1024);
    registry.connection.get().execute("DELETE FROM projection_mutations", []).unwrap();
    let before = pragma_count(&registry, "freelist_count");
    assert!(before > 300, "the test needs more than 256 free pages, got {before}");

    let more = registry.incremental_journal_vacuum().unwrap();

    let after = pragma_count(&registry, "freelist_count");
    assert_eq!(before - after, 256, "one step returns 256 pages ({before} -> {after})");
    assert!(more, "free pages remain for a later step");
}
