use super::*;

#[test]
fn an_older_read_only_journal_has_no_pruned_head() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch("PRAGMA query_only=ON;").unwrap();
    assert_eq!(pruned_head(&db).unwrap(), 0);
}

#[test]
fn the_pruned_head_tracks_the_last_disjoint_range() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(PRUNED_RANGES_SCHEMA).unwrap();
    assert_eq!(pruned_head(&db).unwrap(), 0);
    db.execute_batch("INSERT INTO journal_pruned_ranges VALUES (11, 20), (1, 4), (30, 40);")
        .unwrap();
    assert_eq!(pruned_head(&db).unwrap(), 40);
}

#[test]
fn a_malformed_pruned_schema_is_not_an_empty_journal() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch("CREATE TABLE journal_pruned_ranges(start_sequence INTEGER);").unwrap();
    assert!(pruned_head(&db).is_err());
}

#[test]
fn the_pruned_head_does_not_scan_a_large_cleanup_history() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(PRUNED_RANGES_SCHEMA).unwrap();
    db.execute_batch(
        "WITH RECURSIVE n(i) AS (
               VALUES(1) UNION ALL SELECT i + 1 FROM n WHERE i < 100000
             ) INSERT INTO journal_pruned_ranges SELECT i * 3, i * 3 + 1 FROM n;",
    )
    .unwrap();
    let steps = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let counter = steps.clone();
    db.progress_handler(
        1,
        Some(move || {
            counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            false
        }),
    )
    .unwrap();
    let old: i64 = db
        .query_row("SELECT MAX(end_sequence) FROM journal_pruned_ranges", [], |row| row.get(0))
        .unwrap();
    let scan_steps = steps.swap(0, std::sync::atomic::Ordering::Relaxed);
    assert_eq!(pruned_head(&db).unwrap(), old as u64);
    let seek_steps = steps.load(std::sync::atomic::Ordering::Relaxed);
    db.progress_handler(0, None::<fn() -> bool>).unwrap();
    eprintln!("100000 pruned ranges: scan={scan_steps} VM steps, seek={seek_steps} VM steps");
    assert!(seek_steps < 100, "head read scanned history: {seek_steps} VM steps");
    assert!(scan_steps > 100000);
}
