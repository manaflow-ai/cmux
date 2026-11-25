//! When each live terminal lost its last tab placement (`terminal-reap-v1`).
//!
//! The owner ends a terminal once it has had no placement for the reap grace
//! period. That grace used to be counted only in the owner's memory, so each
//! owner start counted it again from zero: with restarts faster than the
//! grace (a crash loop; the restore fuzz's kill every ~14 s against the app's
//! 30 s) no closed terminal was ever reaped, and their hosts held the
//! machine's PTYs until new terminals failed (P0 TERMINAL-HOST LEAK,
//! 2026-10-31). A row here is the wall-clock time the owner first saw the
//! terminal unplaced; a restarted owner counts the grace from it.
//!
//! The table is additive and has no foreign key, like `terminal_keep`, so the
//! schema version does not change and an older binary still opens this
//! registry (it ignores the table, and counts the grace from its own start as
//! before). Rows of tombstoned or unknown terminals are pruned by the reaper.
//!
//! An owner that does not keep the table (an older binary, or a daemon
//! started without a reap grace) leaves rows as they were: a terminal it
//! placed again and that was unplaced again later keeps its first time, and
//! the next owner that keeps the table can reap it up to one grace early.
//! Only a closed terminal that is not kept and has no attached client is
//! affected; it loses the rest of its undo window.

use std::collections::{HashMap, HashSet};

use rusqlite::{Transaction, params};

use super::{WorkspaceRegistry, validate_terminal_identity};

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
    /// Record what the reaper sees now and return, for each of `unplaced`,
    /// the wall-clock time (Unix ms) it was first seen unplaced: a terminal
    /// without a row gets `now_ms`. Rows of `placed` terminals (a placement
    /// came back, or the terminal is kept) and of terminals that are no
    /// longer live (exited, tombstoned or unknown) are removed. A live
    /// terminal in neither set (one a restarted owner is still adopting)
    /// keeps its row, so its grace goes on counting. Writes only when a row
    /// changes.
    pub fn sync_terminal_unplaced(
        &mut self,
        unplaced: &HashSet<String>,
        placed: &HashSet<String>,
        now_ms: u64,
    ) -> anyhow::Result<UnplacedSince> {
        let db = self.connection.get();
        let read_rows = || -> anyhow::Result<HashMap<String, u64>> {
            let mut statement =
                db.prepare("SELECT terminal_id, since_ms FROM terminal_unplaced")?;
            let rows = statement
                .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?;
            let mut map = HashMap::new();
            for row in rows {
                let (terminal_id, since_ms) = row?;
                map.insert(terminal_id, u64::try_from(since_ms).unwrap_or(0));
            }
            Ok(map)
        };
        let mut rows = read_rows()?;
        let stale: Vec<String> = rows.keys().filter(|id| placed.contains(*id)).cloned().collect();
        let fresh: Vec<String> =
            unplaced.iter().filter(|id| !rows.contains_key(*id)).cloned().collect();
        let unseen = rows.keys().any(|id| !placed.contains(id) && !unplaced.contains(id));
        if !stale.is_empty() || !fresh.is_empty() || unseen {
            let stored = i64::try_from(now_ms).unwrap_or(i64::MAX);
            let tx = db.unchecked_transaction()?;
            for terminal_id in &stale {
                tx.execute("DELETE FROM terminal_unplaced WHERE terminal_id = ?1", [terminal_id])?;
            }
            for terminal_id in &fresh {
                validate_terminal_identity("terminal id", terminal_id)?;
                tx.execute(
                    "INSERT OR IGNORE INTO terminal_unplaced(terminal_id, since_ms)
                     VALUES(?1, ?2)",
                    params![terminal_id, stored],
                )?;
            }
            let pruned = tx.execute(
                "DELETE FROM terminal_unplaced
                 WHERE terminal_id NOT IN (
                   SELECT terminal_id FROM terminal_hosts
                   WHERE lifecycle IN ('launching', 'adopting', 'running')
                 )",
                [],
            )?;
            tx.commit()?;
            if pruned > 0 {
                rows = read_rows()?;
            } else {
                for terminal_id in stale {
                    rows.remove(&terminal_id);
                }
                for terminal_id in fresh {
                    rows.insert(terminal_id, now_ms);
                }
            }
        }
        let since_ms = unplaced
            .iter()
            .map(|terminal_id| {
                (terminal_id.clone(), rows.get(terminal_id).copied().unwrap_or(now_ms))
            })
            .collect();
        Ok(UnplacedSince { since_ms, rows_left: !rows.is_empty() })
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
        let changed = self.connection.get().execute(
            "UPDATE terminal_unplaced SET since_ms = MAX(since_ms - ?2, 0) WHERE terminal_id = ?1",
            params![terminal_id, by],
        )?;
        anyhow::ensure!(changed == 1, "no unplaced time for {terminal_id}");
        Ok(())
    }
}
