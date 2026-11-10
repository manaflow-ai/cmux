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

/// Makes the index when it is missing, partial or on other columns (a
/// build before 50ec02a727a4 made it on `terminal_id, event_sequence`).
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

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    use super::*;

    fn columns(connection: &Connection) -> Vec<String> {
        connection
            .prepare("SELECT name FROM pragma_index_info(?1) ORDER BY seqno ASC")
            .unwrap()
            .query_map([NAME], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
    }

    /// SQLite's schema cookie: it changes with each change of the schema.
    fn schema_cookie(connection: &Connection) -> i64 {
        connection.query_row("PRAGMA schema_version", [], |row| row.get(0)).unwrap()
    }

    fn ensure_in_a_transaction(connection: &Connection) {
        let transaction = connection.unchecked_transaction().unwrap();
        ensure(&transaction).unwrap();
        transaction.commit().unwrap();
    }

    #[test]
    fn an_index_of_an_older_shape_is_made_again_and_a_current_one_is_left_alone() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE resource_agent_hook_pending (
                   idempotency_key TEXT PRIMARY KEY NOT NULL,
                   terminal_id TEXT,
                   event_sequence INTEGER NOT NULL
                 );
                 CREATE INDEX resource_agent_hook_pending_by_terminal
                   ON resource_agent_hook_pending(terminal_id, event_sequence);",
            )
            .unwrap();
        ensure_in_a_transaction(&connection);
        assert_eq!(columns(&connection), COLUMNS, "the older index was not made again");

        let made = schema_cookie(&connection);
        ensure_in_a_transaction(&connection);
        assert_eq!(schema_cookie(&connection), made, "a current index was made again");
        assert_eq!(columns(&connection), COLUMNS);

        connection.execute_batch("DROP INDEX resource_agent_hook_pending_by_terminal;").unwrap();
        ensure_in_a_transaction(&connection);
        assert_eq!(columns(&connection), COLUMNS, "a missing index was not made");
    }
}
