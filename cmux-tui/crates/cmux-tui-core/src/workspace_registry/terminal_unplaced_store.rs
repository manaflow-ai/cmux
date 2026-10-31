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

impl WorkspaceRegistry {
    /// Record what the reaper sees now and return, for each of `unplaced`,
    /// the wall-clock time (Unix ms) it was first seen unplaced: a terminal
    /// without a row gets `now_ms`. Rows of `placed` terminals (a placement
    /// came back, or the terminal is kept) and of tombstoned or unknown
    /// terminals are removed. A terminal in neither set (one a restarted
    /// owner is still adopting) keeps its row, so its grace goes on counting.
    /// Writes only when a row changes.
    pub fn sync_terminal_unplaced(
        &mut self,
        unplaced: &HashSet<String>,
        placed: &HashSet<String>,
        now_ms: u64,
    ) -> anyhow::Result<HashMap<String, u64>> {
        let db = self.connection.get();
        let mut rows: HashMap<String, u64> = {
            let mut statement =
                db.prepare("SELECT terminal_id, since_ms FROM terminal_unplaced")?;
            let rows = statement
                .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?;
            let mut map = HashMap::new();
            for row in rows {
                let (terminal_id, since_ms) = row?;
                map.insert(terminal_id, u64::try_from(since_ms).unwrap_or(0));
            }
            map
        };
        let stale: Vec<&String> = rows.keys().filter(|id| placed.contains(*id)).collect();
        let fresh: Vec<&String> = unplaced.iter().filter(|id| !rows.contains_key(*id)).collect();
        if !stale.is_empty() || !fresh.is_empty() {
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
            tx.execute(
                "DELETE FROM terminal_unplaced
                 WHERE terminal_id NOT IN (
                   SELECT terminal_id FROM terminal_hosts WHERE lifecycle != 'tombstoned'
                 )",
                [],
            )?;
            tx.commit()?;
            let stale: Vec<String> = stale.into_iter().cloned().collect();
            let fresh: Vec<String> = fresh.into_iter().cloned().collect();
            for terminal_id in stale {
                rows.remove(&terminal_id);
            }
            for terminal_id in fresh {
                rows.insert(terminal_id, now_ms);
            }
        }
        Ok(unplaced
            .iter()
            .map(|terminal_id| {
                (terminal_id.clone(), rows.get(terminal_id).copied().unwrap_or(now_ms))
            })
            .collect())
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
