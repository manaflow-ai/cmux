//! Detached terminals (`detached-terminals-v1`): kept terminals created with
//! no workspace, pane, screen or tab.

use rusqlite::{Connection, OptionalExtension, Transaction};

use super::RegistryTerminal;

/// The durable `workspace_key` of a detached terminal. `terminal_hosts.workspace_key`
/// is `NOT NULL` and every terminal write (including the resource
/// projection's terminal upsert, in older binaries too) rejects an empty key,
/// so a detached row carries this sentinel. It can never name a workspace,
/// because workspace keys are canonical lowercase UUIDs, so it needs no live
/// workspace. The live-workspace check runs only when a row's key changes,
/// so an older binary that updates the row keeps accepting it; adoption binds
/// a terminal by its durable resource row, never by this key.
pub(crate) const DETACHED_TERMINAL_WORKSPACE_KEY: &str = "detached";

/// Keep a newly reserved detached terminal in the transaction that reserves
/// it, so no later failure can leave it reapable or replay a receipt for a
/// terminal that never started.
pub(super) fn keep_reserved_detached(
    transaction: &Transaction<'_>,
    existing: Option<&RegistryTerminal>,
    terminal: &RegistryTerminal,
) -> anyhow::Result<()> {
    if existing.is_none() && terminal.workspace_key == DETACHED_TERMINAL_WORKSPACE_KEY {
        transaction.execute(
            "INSERT OR IGNORE INTO terminal_keep(terminal_id) VALUES(?1)",
            [&terminal.terminal_id],
        )?;
    }
    Ok(())
}

pub(super) fn require_live_workspace(
    connection: &Connection,
    workspace_key: &str,
) -> anyhow::Result<()> {
    // A detached terminal names no workspace; its sentinel key needs none.
    if workspace_key == DETACHED_TERMINAL_WORKSPACE_KEY {
        return Ok(());
    }
    let live = connection
        .query_row(
            "SELECT 1 FROM workspaces WHERE workspace_key = ?1 AND tombstoned = 0",
            [workspace_key],
            |_| Ok(()),
        )
        .optional()?;
    if live.is_none() {
        anyhow::bail!("terminal workspace is missing or closed: {workspace_key}");
    }
    Ok(())
}
