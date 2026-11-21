//! The durable part of one terminal's record, for a live terminal item of
//! a `session.events` stream (`mux/terminal_live.rs`).

use super::topology_load::load_tabs;
use super::*;

/// The durable rows of one terminal and the resource revision they were
/// read at.
pub(crate) struct LiveTerminalRows {
    pub(crate) revision: u64,
    /// `None` when the terminal has no live resource row or no host row.
    pub(crate) durable: Option<RegistryTerminal>,
    /// The terminal's own tab rows, not the session topology.
    pub(crate) tabs: Vec<RegistryTab>,
}

impl WorkspaceRegistry {
    /// `query_live_terminal` on the registry's connection, under the
    /// registry lock.
    pub(crate) fn live_terminal(
        &self,
        terminal: &TerminalPublicId,
    ) -> anyhow::Result<LiveTerminalRows> {
        query_live_terminal(&self.connection.get(), terminal)
    }
}

/// The durable rows of `terminal`, read on `connection`. The caller makes
/// the reads one cut: the registry lock, or a read transaction on a
/// `SessionJournalReader`'s connection.
pub(crate) fn query_live_terminal(
    connection: &Connection,
    terminal: &TerminalPublicId,
) -> anyhow::Result<LiveTerminalRows> {
    let revision = current_resource_revision(connection)?;
    let host = connection
        .query_row(
            "SELECT terminal_id FROM resource_terminals
             WHERE public_id = ?1 AND deleted_revision IS NULL",
            [terminal.as_str()],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let durable = match host {
        Some(host) => read_terminal(connection, &host)?,
        None => None,
    };
    let tabs = if durable.is_some() {
        load_tabs(connection, " AND t.content_id = ?1", &[&terminal.as_str()])?
    } else {
        Vec::new()
    };
    Ok(LiveTerminalRows { revision, durable, tabs })
}
