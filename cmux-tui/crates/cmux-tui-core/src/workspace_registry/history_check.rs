//! The full integrity check of the tables that grow with use, moved off the
//! registry open.
//!
//! Lawrence 2026-10-30: with a cold page cache the open's `quick_check` of
//! every state table took 1.0-1.7 s on a 41.6 GB registry, and 1.6 s of it
//! was five tables that only grow: the exactly-once receipts, the resource
//! mutation ledger and the terminal event log; later the reopen-closed
//! history (`closed_groups`, 90 ms cold). The open reads them by key
//! or by their newest rows, so it touches only their tail, as it does for
//! the journal and the other ledgers.
//!
//! - The journal maintenance worker runs their full `quick_check` on a
//!   read-only connection of its own, after the daemon serves
//!   (`scan_background_checked_tables`).
//! - A table that fails sets [`FULL_OPEN_CHECK_META_KEY`]. The next open
//!   then checks every state table in full, as every open did before, and
//!   fails with the data intact when the damage is still there (the
//!   `open_guard` rule for logical integrity failures). An open whose full
//!   check passes clears the key.
//!
//! The guarantee is the one the open gave before, one start later; a
//! receipt table is not set aside like a mutation ledger, because its rows
//! decide whether an interrupted effect runs again.

use std::path::Path;

use rusqlite::{Connection, ErrorCode, params};

use super::{WorkspaceRegistry, open_registry_database_read_only};

/// Present when a background check found a damaged table: the next open
/// checks every state table in full. The value names the table and report.
pub(crate) const FULL_OPEN_CHECK_META_KEY: &str = "integrity_full_open_check_required";

/// The tables checked in full by the maintenance worker instead of the open,
/// each with the columns of its newest key, which the open touches.
pub(crate) const BACKGROUND_CHECKED_TABLES: [(&str, &str); 6] = [
    ("resource_effect_receipts", "idempotency_key DESC"),
    ("resource_creation_receipts", "correlation_key DESC"),
    ("journal_operation_receipts", "operation DESC, origin DESC, idempotency_key DESC"),
    ("resource_mutations", "idempotency_key DESC"),
    ("terminal_events", "revision DESC"),
    // Reopen-closed history: read only to reopen, bounded but large (2,630
    // groups, 4.5 MB, 90 ms of a cold full check on a nightly registry).
    ("closed_groups", "closed_id DESC"),
];

/// Whether the maintenance worker, not the open, checks `table` in full.
pub(crate) fn is_background_checked(table: &str) -> bool {
    BACKGROUND_CHECKED_TABLES.iter().any(|(name, _)| *name == table)
}

/// Whether a background check asked the next open for a full check.
pub(crate) fn full_open_check_required(connection: &Connection) -> anyhow::Result<bool> {
    Ok(super::meta_value(connection, FULL_OPEN_CHECK_META_KEY)?.is_some())
}

/// The open's check of a background-checked table: its newest row and its
/// newest key, so a damaged tail page still stops the open.
pub(crate) fn touch_background_checked_tails(
    connection: &Connection,
    tables: &[String],
) -> anyhow::Result<()> {
    for (table, key_order) in BACKGROUND_CHECKED_TABLES {
        if !tables.iter().any(|name| name.as_str() == table) {
            continue;
        }
        for order in ["rowid DESC", key_order] {
            let query = format!("SELECT 1 FROM {table} ORDER BY {order} LIMIT 1");
            let _: Option<i64> =
                rusqlite::OptionalExtension::optional(
                    connection.query_row(&query, [], |row| row.get(0)),
                )?;
        }
    }
    Ok(())
}

/// The background-checked tables whose `quick_check` fails, each with
/// SQLite's report. It reads on a connection of its own, so the check never
/// holds the registry lock while it walks a large table.
pub(crate) fn scan_background_checked_tables(
    database: &Path,
) -> anyhow::Result<Vec<(&'static str, String)>> {
    let connection = open_registry_database_read_only(database)?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    let mut damaged = Vec::new();
    for (table, _) in BACKGROUND_CHECKED_TABLES {
        let present = connection
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |_| Ok(()),
            )
            .is_ok();
        if !present {
            continue;
        }
        let pragma = format!("PRAGMA quick_check('{table}')");
        match connection.query_row(&pragma, [], |row| row.get::<_, String>(0)) {
            Ok(report) if report == "ok" => {}
            Ok(report) => damaged.push((table, report)),
            Err(error) if error.sqlite_error_code() == Some(ErrorCode::DatabaseCorrupt) => {
                damaged.push((table, error.to_string()));
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(damaged)
}

impl WorkspaceRegistry {
    /// Ask the next open to check every state table in full: a background
    /// check found `table` damaged (`report` is SQLite's).
    pub(crate) fn require_full_open_check(&self, table: &str, report: &str) -> anyhow::Result<()> {
        self.connection.get().execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![FULL_OPEN_CHECK_META_KEY, format!("{table}: {report}")],
        )?;
        Ok(())
    }
}
