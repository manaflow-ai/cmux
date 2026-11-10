//! The index of pending agent hooks by terminal, made only when it is
//! missing or has another shape.
//!
//! The open of a registry ran `DROP INDEX` and `CREATE INDEX` for it on every
//! start, so the open of a registry at the current schema always committed.
//! A daemon start must write nothing that depends on old state: a commit on
//! the start path pays for the WAL the previous run left
//! (`wal_durability` module docs).

use rusqlite::Transaction;

const NAME: &str = "resource_agent_hook_pending_by_terminal";
const COLUMNS: [&str; 3] = ["terminal_id", "event_sequence", "idempotency_key"];

/// Makes the index when it is missing, partial or on other columns (an
/// older build made it on `terminal_id` alone).
pub(super) fn ensure(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    if is_current(transaction)? {
        return Ok(());
    }
    transaction.execute_batch(
        "DROP INDEX IF EXISTS resource_agent_hook_pending_by_terminal;
         CREATE INDEX IF NOT EXISTS resource_agent_hook_pending_by_terminal
           ON resource_agent_hook_pending(terminal_id, event_sequence, idempotency_key);",
    )?;
    Ok(())
}

fn is_current(transaction: &Transaction<'_>) -> anyhow::Result<bool> {
    let whole: bool = transaction.query_row(
        "SELECT COUNT(*) = 1 FROM pragma_index_list('resource_agent_hook_pending')
         WHERE name = ?1 AND partial = 0",
        [NAME],
        |row| row.get(0),
    )?;
    if !whole {
        return Ok(false);
    }
    let columns = transaction
        .prepare("SELECT name FROM pragma_index_info(?1) ORDER BY seqno ASC")?
        .query_map([NAME], |row| row.get::<_, Option<String>>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(columns.iter().map(Option::as_deref).eq(COLUMNS.into_iter().map(Some)))
}
