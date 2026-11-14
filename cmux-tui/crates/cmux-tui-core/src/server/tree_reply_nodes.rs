//! The nodes of a `list-workspaces` tree, built from a copy of the state.
//!
//! The reply takes the mux state lock one time, for a copy of the state
//! (`Mux::tree_state_and_decorations`), and builds its nodes here with no lock held. A test
//! build counts each build that runs while its thread holds the lock, so a test can say that
//! there is none.

use super::workspaces_json;
use crate::TreeDecorations;
use crate::model::State;
use serde_json::Value;

/// The nodes of the whole tree (tree_json.rs).
pub(super) fn tree_nodes(state: &State, decorations: &TreeDecorations) -> Value {
    #[cfg(test)]
    if crate::workspace_registry::registry_connection::current_thread_holds_state() {
        TREES_BUILT_UNDER_STATE_LOCK.with(|built| built.set(built.get().saturating_add(1)));
    }
    workspaces_json(state, decorations)
}

#[cfg(test)]
thread_local! {
    static TREES_BUILT_UNDER_STATE_LOCK: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Test seam: the `list-workspaces` trees whose nodes this thread built while it held the mux
/// state lock.
#[cfg(test)]
pub(super) fn trees_built_under_state_lock_on_this_thread() -> u64 {
    TREES_BUILT_UNDER_STATE_LOCK.with(std::cell::Cell::get)
}
