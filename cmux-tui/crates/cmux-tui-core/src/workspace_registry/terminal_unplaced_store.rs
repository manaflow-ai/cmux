//! When each live terminal lost its last tab placement (the unplaced-terminal
//! reaper, `mux/terminal_reap.rs`).
//!
//! The owner ends a terminal once it has had no placement for the reap grace
//! period. Counted only in the owner's memory, each owner start would count
//! it again from zero: with restarts faster than the grace (a crash loop) no
//! closed terminal was ever reaped, and their hosts held the machine's PTYs
//! until new terminals failed (feat P0 TERMINAL-HOST LEAK, 2026-10-31). A row
//! here is the wall-clock time the owner first saw the terminal unplaced; a
//! restarted owner counts the grace from it.
//!
//! The table is additive and has no foreign key, like the idle-close policy
//! table, so the schema version does not change and an older binary still
//! opens this registry (it ignores the table). Rows of tombstoned, exited or
//! unknown terminals are pruned by the reaper.
//!
//! An owner that does not keep the table (an older binary, or a daemon
//! started without a reap grace) leaves rows as they were: a terminal it
//! placed again and that was unplaced again later keeps its first time, and
//! the next owner that keeps the table can reap it up to one grace early.
//! Only a closed terminal with no attached client is affected; it loses the
//! rest of its undo window.

// Red commit: stub store (the fix commit keeps the rows and drops this).
#![allow(dead_code)]

use std::collections::{HashMap, HashSet};

use rusqlite::Transaction;

use super::WorkspaceRegistry;

pub(super) fn create_terminal_unplaced_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_unplaced (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           since_ms INTEGER NOT NULL CHECK(since_ms >= 0)
         );",
    )?;
    Ok(())
}

/// What [`WorkspaceRegistry::sync_terminal_unplaced`] found.
#[derive(Debug, Default)]
pub struct UnplacedSince {
    /// Each unplaced terminal's first unplaced time (Unix ms).
    pub since_ms: HashMap<String, u64>,
    /// Whether any row is left (a terminal unplaced, or one still adopting);
    /// with none, a pass that sees no unplaced terminal has nothing to do.
    pub rows_left: bool,
}

impl WorkspaceRegistry {
    /// Red stub: keeps nothing; every terminal is unplaced since `now_ms`.
    pub fn sync_terminal_unplaced(
        &mut self,
        unplaced: &HashSet<String>,
        _placed: &HashSet<String>,
        now_ms: u64,
    ) -> anyhow::Result<UnplacedSince> {
        let since_ms = unplaced.iter().map(|terminal_id| (terminal_id.clone(), now_ms)).collect();
        Ok(UnplacedSince { since_ms, rows_left: false })
    }
}

#[cfg(test)]
impl WorkspaceRegistry {
    /// Moves `terminal_id`'s unplaced time back by `by`, as if it had been
    /// closed that much earlier (an owner restart in between).
    pub(crate) fn backdate_terminal_unplaced(
        &mut self,
        terminal_id: &str,
        by: std::time::Duration,
    ) -> anyhow::Result<()> {
        let by = i64::try_from(by.as_millis()).unwrap_or(i64::MAX);
        let changed = self.connection.execute(
            "UPDATE terminal_unplaced SET since_ms = MAX(since_ms - ?2, 0) WHERE terminal_id = ?1",
            rusqlite::params![terminal_id, by],
        )?;
        anyhow::ensure!(changed == 1, "no unplaced time for {terminal_id}");
        Ok(())
    }
}
