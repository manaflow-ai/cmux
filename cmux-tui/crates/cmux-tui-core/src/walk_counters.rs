//! Test-only counts of the in-memory walks one request runs on its own
//! thread, so a test can say that a request's work does not grow with the
//! session (`mux/tests/workspace_close_cost.rs`).

use std::cell::Cell;

thread_local! {
    static INDEX_REBUILD: Cell<u64> = const { Cell::new(0) };
    static DECORATION_WALK: Cell<u64> = const { Cell::new(0) };
    static TERMINAL_CLONES: Cell<u64> = const { Cell::new(0) };
    static WORKSPACE_ROWS: Cell<u64> = const { Cell::new(0) };
    static FRAME_ROWS: Cell<u64> = const { Cell::new(0) };
    static PATCH_CHANGES: Cell<u64> = const { Cell::new(0) };
    static PUBLIC_DELTAS: Cell<u64> = const { Cell::new(0) };
}

/// The walks this thread ran so far.
#[cfg(unix)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct WalkCounts {
    /// Workspaces visited by a rebuild of the split index or of the public
    /// resource indexes.
    pub(crate) index_rebuild: u64,
    /// Surfaces and tab slots visited to build tree decorations.
    pub(crate) decoration_walk: u64,
    /// Catalog terminals cloned to publish waiting directory reports.
    pub(crate) terminal_clones: u64,
    /// Workspaces whose row and public value a walk of the live tree stated.
    pub(crate) workspace_rows: u64,
    /// Stored workspace rows that the read of a scoped projection returned.
    pub(crate) frame_rows: u64,
    /// Durable changes in the patches that a projection commit prepared.
    pub(crate) patch_changes: u64,
    /// Public deltas (JSON values) in the projections that a projection commit prepared.
    pub(crate) public_deltas: u64,
}

fn add(counter: &'static std::thread::LocalKey<Cell<u64>>, items: usize) {
    counter.with(|count| count.set(count.get() + items as u64));
}

pub(crate) fn index_rebuild_visited(workspaces: usize) {
    add(&INDEX_REBUILD, workspaces);
}

pub(crate) fn decoration_walk_visited(surfaces: usize) {
    add(&DECORATION_WALK, surfaces);
}

pub(crate) fn terminals_cloned(terminals: usize) {
    add(&TERMINAL_CLONES, terminals);
}

pub(crate) fn workspace_rows_stated(workspaces: usize) {
    add(&WORKSPACE_ROWS, workspaces);
}

pub(crate) fn frame_rows_read(workspaces: usize) {
    add(&FRAME_ROWS, workspaces);
}

pub(crate) fn projection_prepared(patch_changes: usize, public_deltas: usize) {
    add(&PATCH_CHANGES, patch_changes);
    add(&PUBLIC_DELTAS, public_deltas);
}

#[cfg(unix)]
pub(crate) fn walk_counts_for_test() -> WalkCounts {
    WalkCounts {
        index_rebuild: INDEX_REBUILD.with(Cell::get),
        decoration_walk: DECORATION_WALK.with(Cell::get),
        terminal_clones: TERMINAL_CLONES.with(Cell::get),
        workspace_rows: WORKSPACE_ROWS.with(Cell::get),
        frame_rows: FRAME_ROWS.with(Cell::get),
        patch_changes: PATCH_CHANGES.with(Cell::get),
        public_deltas: PUBLIC_DELTAS.with(Cell::get),
    }
}
