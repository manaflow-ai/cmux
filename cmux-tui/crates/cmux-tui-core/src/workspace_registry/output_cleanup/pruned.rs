//! `journal_pruned_ranges`: the runs of sequences that output cleanup removed.
//! One row per maximal run, keyed by its first sequence, so a lookup is one
//! index seek. Readers check gaps and the journal's possibly pruned tail; a
//! registry that never had a cleanup has no rows and every gap stays an error.

use rusqlite::{Connection, OptionalExtension};

/// Created with the session journal schema of every registry.
pub(crate) const PRUNED_RANGES_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS journal_pruned_ranges (
       start_sequence INTEGER PRIMARY KEY CHECK(start_sequence > 0),
       end_sequence INTEGER NOT NULL CHECK(end_sequence >= start_sequence)
     );";

/// The last removed sequence, including a fully pruned journal's tail.
pub(crate) fn pruned_head(connection: &Connection) -> anyhow::Result<u64> {
    // Ranges are disjoint and keyed by start: the last range has the largest
    // end. MAX(end_sequence) would scan every range on each head read.
    let end = connection
        .prepare_cached(
            "SELECT end_sequence FROM journal_pruned_ranges
             ORDER BY start_sequence DESC LIMIT 1",
        )
        .and_then(|mut statement| statement.query_row([], |row| row.get::<_, i64>(0)))
        .optional();
    match end {
        Ok(Some(end)) => Ok(u64::try_from(end)?),
        Ok(None) => Ok(0),
        Err(error) if is_missing_table(&error) => Ok(0),
        Err(error) => Err(error.into()),
    }
}

/// True when the sequences strictly between `after` and `next` are all
/// inside one pruned range. `after` may itself be a pruned sequence (a
/// cursor or checkpoint that pointed at removed output).
pub(crate) fn pruned_gap(connection: &Connection, after: u64, next: u64) -> anyhow::Result<bool> {
    let Some(first_missing) = after.checked_add(1) else { return Ok(false) };
    if next <= first_missing {
        return Ok(false);
    }
    let last_missing = next - 1;
    let end = connection
        .query_row(
            "SELECT end_sequence FROM journal_pruned_ranges
             WHERE start_sequence <= ?1
             ORDER BY start_sequence DESC
             LIMIT 1",
            [i64::try_from(first_missing)?],
            |row| row.get::<_, i64>(0),
        )
        .optional();
    match end {
        Ok(Some(end)) => Ok(u64::try_from(end).is_ok_and(|end| end >= last_missing)),
        Ok(None) => Ok(false),
        // A read-only reader of a registry that an older build created.
        Err(error) if is_missing_table(&error) => Ok(false),
        Err(error) => Err(error.into()),
    }
}

fn is_missing_table(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(_, Some(message)) if message.starts_with("no such table")
    )
}

#[cfg(test)]
mod tests {
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
}
