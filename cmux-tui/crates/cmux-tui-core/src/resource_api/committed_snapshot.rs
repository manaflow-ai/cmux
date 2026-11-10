//! The committed rows of the whole-session snapshot, read with no writer lock.
//!
//! Lawrence's daemon, 2026-11-10 (826 workspaces, 2 h): the snapshot read held the workspace registry lock and the
//! state lock across its O(session) walk 434 times, mean 105 ms, max 262 ms; a split waited behind it. Chromium's
//! rule: a reader never holds the writer's lock across an O(session) walk; it reads a published immutable snapshot.
//!
//! No writer publishes here, because a rebuild per commit is O(session). The first reader after a commit builds the
//! rows on a read-only WAL connection of its own, in ONE read transaction: the journal head, the topology (the
//! cursor), the terminal rows, the projections and the state fields are one committed revision. The key is the
//! registry writer's commit count, read before the rows, so the rows are never older than their key. A reader that
//! finds the key unchanged runs no statement and takes no registry lock and no state lock: it takes the short mutex
//! of the commit count (`WalDurability::counts`) and makes one atomic load.
//!
//! The key is a correctness key: the count must move inside every COMMIT that writes rows on the registry's
//! connection (the WAL hook, `workspace_registry/wal_durability.rs` `note_commit`). `mux/tests/snapshot_read.rs`
//! (`a_warm_snapshot_shows_the_next_commit_of_each_kind`) fails when a commit does not move it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use serde_json::{Value, json};

use super::{public_pane_and_tab_values, public_workspace_values};
use crate::Mux;
use crate::resource::SessionPublicId;
use crate::resource_screen::{public_screen_value, tabs_by_pane};
use crate::workspace_registry::SessionRows;

/// One committed revision of everything durable the session snapshot shows.
pub(crate) struct CommittedSnapshot {
    commits: u64,
    pub(super) rows: SessionRows,
    pub(super) workspaces: Vec<Value>,
    pub(super) screens: Vec<Value>,
    pub(super) panes: Vec<Value>,
    pub(super) tabs: Vec<Value>,
    pub(super) state: Value,
}

/// The snapshot readers' own read-only connection and the rows of the last commit count a reader saw.
pub(crate) struct CommittedSnapshots {
    reader: Mutex<rusqlite::Connection>,
    latest: arc_swap::ArcSwapOption<CommittedSnapshot>,
}

impl CommittedSnapshots {
    /// `None` for an in-memory registry (no second connection) or when the connection does not open: the read
    /// then runs on the registry's readers (`read_committed_registry`).
    pub(crate) fn open(database_path: Option<&std::path::Path>) -> Option<Self> {
        let reader = crate::workspace_registry::open_registry_database_read_only(database_path?)
            .inspect_err(|error| {
                eprintln!("cmux-tui: snapshot reader connection unavailable: {error:#}");
            })
            .ok()?;
        Some(Self { reader: Mutex::new(reader), latest: arc_swap::ArcSwapOption::empty() })
    }

    #[cfg(test)]
    pub(crate) fn with_reader_for_test<T>(
        &self,
        run: impl FnOnce(&rusqlite::Connection) -> T,
    ) -> T {
        run(&self.reader.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

/// The committed rows as of now: the cached ones when no commit landed since they were read.
pub(super) fn committed_snapshot(mux: &Mux) -> anyhow::Result<Arc<CommittedSnapshot>> {
    let Some(snapshots) = &mux.committed_snapshots else {
        return Ok(Arc::new(super::read_committed_registry(mux, |connection, ids| {
            build(connection, &ids.registry_id, &ids.generation, &ids.session_id, 0)
        })?));
    };
    let current =
        |commits: u64| snapshots.latest.load_full().filter(|latest| latest.commits == commits);
    if let Some(latest) = current(mux.registry_connection.durability_counts().0) {
        return Ok(latest);
    }
    // One builder at a time: a reader that waited here takes what the builder before it stored.
    let reader = snapshots.reader.lock().unwrap_or_else(PoisonError::into_inner);
    // The count before the rows: a commit that lands after this line gives rows newer than the key, and the next
    // reader builds again.
    let commits = mux.registry_connection.durability_counts().0;
    if let Some(latest) = current(commits) {
        return Ok(latest);
    }
    let (registry_id, generation) = mux.registry_identity();
    let transaction = reader.unchecked_transaction()?;
    let built =
        Arc::new(build(&transaction, &registry_id, &generation, &mux.session_public_id, commits)?);
    transaction.finish()?;
    snapshots.latest.store(Some(built.clone()));
    Ok(built)
}

fn build(
    connection: &rusqlite::Connection,
    registry_id: &str,
    generation: &str,
    session_id: &SessionPublicId,
    commits: u64,
) -> anyhow::Result<CommittedSnapshot> {
    let rows = crate::workspace_registry::read_session_rows(
        connection,
        registry_id,
        generation,
        session_id,
    )?;
    anyhow::ensure!(
        rows.registry.generation == rows.topology.generation
            && rows.registry.resource_revision == rows.topology.revision,
        "resource projection changed while snapshotting"
    );
    let (workspaces, screens, panes, tabs) = {
        let topology = &rows.topology;
        let tabs_by_pane = tabs_by_pane(&topology.tabs);
        let panes_by_id =
            topology.panes.iter().map(|pane| (&pane.public_id, pane)).collect::<HashMap<_, _>>();
        let screens_by_id = topology
            .screens
            .iter()
            .map(|screen| (&screen.public_id, screen))
            .collect::<HashMap<_, _>>();
        let workspaces = public_workspace_values(&rows.registry, topology)?;
        let screens = topology
            .screens
            .iter()
            .map(|screen| public_screen_value(topology, screen, &tabs_by_pane, &panes_by_id))
            .collect::<anyhow::Result<Vec<_>>>()?;
        let (panes, tabs) = public_pane_and_tab_values(topology, &screens_by_id, &panes_by_id)?;
        (workspaces, screens, panes, tabs)
    };
    let mut decorated = json!({"workspaces": workspaces, "screens": screens, "tabs": tabs});
    crate::state::values::decorate_snapshot(connection, &mut decorated)?;
    let mut take = |key: &str| match decorated[key].take() {
        Value::Array(values) => values,
        _ => Vec::new(),
    };
    let (workspaces, screens, tabs) = (take("workspaces"), take("screens"), take("tabs"));
    let state = crate::state::store::state_snapshot(connection)?;
    Ok(CommittedSnapshot { commits, rows, workspaces, screens, panes, tabs, state })
}
