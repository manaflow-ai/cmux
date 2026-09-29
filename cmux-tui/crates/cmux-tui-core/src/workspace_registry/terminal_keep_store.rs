//! Durable per-terminal `keep` flags (`terminal-reap-v1`).
//!
//! The owner ends a terminal that has had no tab placement for its reap grace
//! period unless the terminal is marked `keep`. A row in `terminal_keep`
//! means keep; no row means the terminal is reaped once unplaced.
//!
//! The table is additive and has no foreign key, like the idle-close policy
//! table, so the schema version does not change and an older binary still
//! opens this registry (it ignores the table). Rows of tombstoned or unknown
//! terminals are inert and pruned by the owner's reaper.
//!
//! Registries written before the table existed are classified once, on the
//! first open by a build that knows it: a live terminal without a live tab
//! placement becomes `keep`, so an upgrade never ends detached work that the
//! user left running on purpose. A terminal with a placement stays reapable.

use rusqlite::{Transaction, params};

use super::{
    TerminalLifecycle, WorkspaceRegistry, meta_value, read_terminal, validate_terminal_identity,
};

/// Set once the legacy classification has run for this registry.
const TERMINAL_KEEP_CLASSIFIED_META_KEY: &str = "terminal_keep_classified";

pub(super) fn create_terminal_keep_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_keep (
           terminal_id TEXT PRIMARY KEY NOT NULL
         );",
    )?;
    Ok(())
}

/// Mark every live terminal that has no live tab placement as `keep`, once
/// per registry. Later opens do nothing, so a terminal created afterwards
/// (including by an older binary) keeps the default: reapable.
pub(super) fn classify_legacy_terminals(transaction: &Transaction<'_>) -> anyhow::Result<usize> {
    create_terminal_keep_schema(transaction)?;
    if meta_value(transaction, TERMINAL_KEEP_CLASSIFIED_META_KEY)?.is_some() {
        return Ok(0);
    }
    let kept = transaction.execute(
        "INSERT OR IGNORE INTO terminal_keep(terminal_id)
         SELECT host.terminal_id FROM terminal_hosts AS host
         WHERE host.lifecycle != 'tombstoned'
           AND NOT EXISTS (
             SELECT 1 FROM resource_terminals AS terminal
             JOIN resource_tabs AS tab ON tab.content_id = terminal.public_id
             JOIN resource_panes AS pane ON pane.public_id = tab.pane_id
             WHERE terminal.terminal_id = host.terminal_id
               AND terminal.deleted_revision IS NULL
               AND tab.deleted_revision IS NULL
               AND pane.deleted_revision IS NULL
           )",
        [],
    )?;
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, '1')",
        params![TERMINAL_KEEP_CLASSIFIED_META_KEY],
    )?;
    Ok(kept)
}

impl WorkspaceRegistry {
    /// Mark (`true`) or unmark (`false`) a live terminal as `keep`. Tombstoned
    /// or unknown terminals are rejected so a stale request cannot leave an
    /// orphan row behind.
    pub fn set_terminal_keep(&mut self, terminal_id: &str, keep: bool) -> anyhow::Result<()> {
        validate_terminal_identity("terminal id", terminal_id)?;
        let tx = self.connection.transaction()?;
        let terminal = read_terminal(&tx, terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal_not_found"))?;
        anyhow::ensure!(terminal.lifecycle != TerminalLifecycle::Tombstoned, "terminal_not_found");
        if keep {
            tx.execute(
                "INSERT OR IGNORE INTO terminal_keep(terminal_id) VALUES(?1)",
                [terminal_id],
            )?;
        } else {
            tx.execute("DELETE FROM terminal_keep WHERE terminal_id = ?1", [terminal_id])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Whether one terminal is marked `keep`.
    pub fn terminal_keep(&self, terminal_id: &str) -> anyhow::Result<bool> {
        validate_terminal_identity("terminal id", terminal_id)?;
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM terminal_keep WHERE terminal_id = ?1)",
            [terminal_id],
            |row| row.get::<_, bool>(0),
        )?)
    }

    /// Every terminal id marked `keep`, including rows not yet pruned.
    pub fn kept_terminals(&self) -> anyhow::Result<std::collections::HashSet<String>> {
        let mut statement = self.connection.prepare("SELECT terminal_id FROM terminal_keep")?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut kept = std::collections::HashSet::new();
        for row in rows {
            kept.insert(row?);
        }
        Ok(kept)
    }

    /// Delete `keep` rows whose terminal is tombstoned or no longer
    /// registered. Returns the number of rows removed.
    pub fn prune_terminal_keep(&mut self) -> anyhow::Result<usize> {
        Ok(self.connection.execute(
            "DELETE FROM terminal_keep
             WHERE terminal_id NOT IN (
               SELECT terminal_id FROM terminal_hosts WHERE lifecycle != 'tombstoned'
             )",
            [],
        )?)
    }
}
