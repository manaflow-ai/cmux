//! `journal_pruned_ranges`: the runs of sequences that output cleanup removed.
//! One row per maximal run, keyed by its first sequence, so a lookup is one
//! index seek. Readers ask only when they see a gap; a registry that never
//! had a cleanup has no rows and every gap stays an error.

use rusqlite::{Connection, OptionalExtension};

/// Created with the session journal schema of every registry.
pub(crate) const PRUNED_RANGES_SCHEMA: &str = "CREATE TABLE IF NOT EXISTS journal_pruned_ranges (
       start_sequence INTEGER PRIMARY KEY CHECK(start_sequence > 0),
       end_sequence INTEGER NOT NULL CHECK(end_sequence >= start_sequence)
     );";

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
