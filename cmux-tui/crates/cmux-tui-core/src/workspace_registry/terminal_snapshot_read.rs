//! The terminal registry snapshot reader (moved out of workspace_registry.rs).

use super::*;

impl WorkspaceRegistry {
    /// Rows of terminals that run or are about to (launching, adopting,
    /// running): one count, no row read.
    pub(crate) fn live_terminal_row_count(&self) -> anyhow::Result<usize> {
        let count: i64 = self.connection.get().query_row(
            "SELECT COUNT(*) FROM terminal_hosts
             WHERE lifecycle IN ('launching', 'adopting', 'running')",
            [],
            |row| row.get(0),
        )?;
        Ok(usize::try_from(count).unwrap_or(usize::MAX))
    }

    /// Returns the canonical, non-tombstoned terminal placement projection.
    /// Runtime surface ids and renderer process ids are intentionally absent.
    pub fn terminal_snapshot(&self) -> anyhow::Result<TerminalRegistrySnapshot> {
        terminal_snapshot_in(&self.connection.get(), &self.registry_id, &self.generation)
    }
}

/// The terminal placement projection, read on `db` (the registry's connection or the read-only one).
pub(crate) fn terminal_snapshot_in(
    db: &Connection,
    registry_id: &str,
    generation: &str,
) -> anyhow::Result<TerminalRegistrySnapshot> {
    let revision = current_terminal_revision(db)?;
    let terminals = load_terminal_rows(db)?;
    Ok(TerminalRegistrySnapshot {
        registry_id: registry_id.to_string(),
        generation: generation.to_string(),
        revision,
        terminals,
    })
}

/// The rows of one whole-session snapshot: read on one connection, in one read transaction on the read-only one,
/// so the journal head, the topology and the projections are one committed revision.
pub(crate) struct SessionRows {
    pub(crate) journal_head: u64,
    pub(crate) registry: RegistrySnapshot,
    pub(crate) topology: ResourceTopologySnapshot,
    pub(crate) terminals: TerminalRegistrySnapshot,
    pub(crate) terminal_resource_ids: Vec<(String, TerminalPublicId)>,
    pub(crate) projections: RegistryPublicProjections,
}

pub(crate) fn read_session_rows(
    db: &Connection,
    registry_id: &str,
    generation: &str,
    session_id: &SessionPublicId,
) -> anyhow::Result<SessionRows> {
    Ok(SessionRows {
        journal_head: session_journal::query_journal_head(db)?,
        registry: registry_snapshot_in(db, registry_id, generation, session_id)?,
        topology: resource_store::load_resource_topology(
            db,
            session_id.clone(),
            generation.to_string(),
        )?,
        terminals: terminal_snapshot_in(db, registry_id, generation)?,
        terminal_resource_ids: load_live_terminal_resource_ids(db)?,
        projections: public_projection_store::ProjectionReader { db, session_id }
            .public_projections()?,
    })
}

/// The non-tombstoned terminal rows of `connection`, in creation order. The
/// registry's terminal snapshot and a committed read (a `terminal.list` with
/// no scope, which takes no registry lock) share it.
pub(crate) fn load_terminal_rows(connection: &Connection) -> anyhow::Result<Vec<RegistryTerminal>> {
    let mut statement = connection.prepare(
        "SELECT terminal_id, workspace_key, incarnation, lifecycle,
                launch_spec_json, exit_json, on_exit
         FROM terminal_hosts
         WHERE lifecycle != 'tombstoned'
         ORDER BY created_revision ASC, terminal_id ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, Option<String>>(5)?,
            row.get::<_, String>(6)?,
        ))
    })?;
    rows.map(|row| terminal_from_stored(row?)).collect()
}
