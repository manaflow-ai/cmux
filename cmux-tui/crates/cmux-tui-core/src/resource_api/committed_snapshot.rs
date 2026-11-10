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
//! of the commit count (`WalDurability::counts`) and makes one atomic load. The reader that builds tries the state
//! lock once after its rows, with no walk under it (`routes_of_committed_rows_are_published`).
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

#[cfg(test)]
thread_local! {
    static ROUTE_WAITS: std::cell::RefCell<Vec<std::time::Duration>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// How many times a snapshot read on this thread waited for a mutator before it loaded its routes (test hook).
#[cfg(test)]
pub(crate) fn route_waits_on_this_thread() -> u64 {
    ROUTE_WAITS.with(|waits| waits.borrow().len() as u64)
}

/// How long each of those waits was (test hook, for the measure in `mux/tests/snapshot_read/route_wait.rs`).
#[cfg(test)]
pub(crate) fn route_wait_times_on_this_thread() -> Vec<std::time::Duration> {
    ROUTE_WAITS.with(|waits| waits.borrow().clone())
}

/// Called after the rows are read and before the caller loads the published routes: when it returns, the routes
/// of every commit in the rows are published.
///
/// A mutator that changes a route table and commits in one hold of the state lock (a terminal respawn, an
/// adoption at daemon start) publishes its routes when its state guard drops, after its COMMIT. A read between
/// the two would show the rows of the commit with the routes of before it, and a client that starts at that
/// cursor never gets the delta of the commit. Such a mutator holds the state lock from before its COMMIT to its
/// publish. So if the state lock is free at a time after the rows were read, each mutator whose commit the rows
/// show has dropped its guard: one try, no wait, no walk under it. If a thread holds the state lock now, the read
/// waits for it once (an O(1) hold of its own), as the read under the state lock did before. Routes newer than
/// the rows are harmless: the read walks the rows.
fn routes_of_committed_rows_are_published(mux: &Mux) {
    if matches!(mux.state.try_lock(), Err(std::sync::TryLockError::WouldBlock)) {
        #[cfg(test)]
        let waited_from = std::time::Instant::now();
        drop(mux.state.lock());
        #[cfg(test)]
        ROUTE_WAITS.with(|waits| waits.borrow_mut().push(waited_from.elapsed()));
    }
}

/// The committed rows as of now: the cached ones when no commit landed since they were read. The routes of every
/// commit in the returned rows are published (see [`routes_of_committed_rows_are_published`]).
pub(super) fn committed_snapshot(mux: &Mux) -> anyhow::Result<Arc<CommittedSnapshot>> {
    let Some(snapshots) = &mux.committed_snapshots else {
        let built = Arc::new(super::read_committed_registry(mux, |connection, ids| {
            build(connection, &ids.registry_id, &ids.generation, &ids.session_id, 0)
        })?);
        routes_of_committed_rows_are_published(mux);
        return Ok(built);
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
    // Before the rows go in the cache: a reader that takes them from the cache makes no try of its own.
    routes_of_committed_rows_are_published(mux);
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
