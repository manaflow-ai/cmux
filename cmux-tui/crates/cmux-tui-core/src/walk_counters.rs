//! Test-only counts of the in-memory walks one request runs on its own
//! thread, so a test can say that a request's work does not grow with the
//! session (`mux/tests/workspace_close_cost.rs`).

use std::cell::Cell;

thread_local! {
    static INDEX_REBUILD: Cell<u64> = const { Cell::new(0) };
    static DECORATION_WALK: Cell<u64> = const { Cell::new(0) };
    static TERMINAL_CLONES: Cell<u64> = const { Cell::new(0) };
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

#[cfg(unix)]
pub(crate) fn walk_counts_for_test() -> WalkCounts {
    WalkCounts {
        index_rebuild: INDEX_REBUILD.with(Cell::get),
        decoration_walk: DECORATION_WALK.with(Cell::get),
        terminal_clones: TERMINAL_CLONES.with(Cell::get),
    }
}
