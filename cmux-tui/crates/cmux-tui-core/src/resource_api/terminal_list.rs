//! `terminal.list` with no scope: the session snapshot's `terminals`, built
//! alone.

#[cfg(test)]
use std::cell::RefCell;
use std::collections::HashMap;

use serde_json::Value;

use super::{
    load_terminal_list_rows, operation_failed, public_terminal_values, read_committed_registry,
};
use crate::Mux;
use crate::resource::ResourceError;

#[cfg(test)]
thread_local! {
    /// Runs once on this thread, in the next lock-free terminal list, after it
    /// copied the live surface handles and before it builds the values: a
    /// test ends a terminal between the two cuts.
    static BETWEEN_CUTS_HOOK: RefCell<Option<Box<dyn FnOnce()>>> = RefCell::new(None);
}

#[cfg(test)]
pub(crate) fn set_terminal_list_between_cuts_hook(hook: impl FnOnce() + 'static) {
    BETWEEN_CUTS_HOOK.with(|slot| {
        *slot.borrow_mut() = Some(Box::new(hook));
    });
}

/// Why a list could not answer from its lock-free read.
enum NoLockFreeAnswer {
    /// The read of the stored rows returned an error.
    CommittedRead(anyhow::Error),
    /// The rows and the live terminals are two cuts, and they did not agree.
    TwoCuts(anyhow::Error),
}

/// The session snapshot's `terminals`, built alone (`terminal.list` with no
/// scope): the same values in the same order. At 826 workspaces the whole
/// snapshot held the registry lock and the state lock for each `terminal
/// list` of a script or an agent. This reads the stored rows as one
/// committed read (no registry lock on a file registry), takes the state
/// lock one time to copy each terminal's live surface handle, and builds the
/// values with no lock held. A surface that changes after the read gives its
/// newer live fields (title, size, directory), as it does to a list that
/// runs a moment later.
///
/// When that gives no answer, the list reads the rows and the live terminals
/// as one cut under the registry and state locks, as the snapshot does. It
/// does so for each of the two causes ([`NoLockFreeAnswer`]): the registry's
/// own connection can read what the read-only one could not, and a terminal
/// that ended between the two cuts is gone from both under the locks. Each
/// such list is counted (`server-stats` `registry_reads`), because it waits
/// for each writer that holds the registry lock. If the read under the locks
/// fails too, that error is the answer of the list (`operation.failed`): a
/// real mismatch gives the snapshot's error.
pub(crate) fn public_terminals(mux: &Mux) -> Result<Vec<Value>, ResourceError> {
    // Memory only, as in the snapshot: not under a session lock.
    let last_sessions = mux.agent_last_sessions();
    let cause = match lock_free_terminals(mux, &last_sessions) {
        Ok(terminals) => return Ok(terminals),
        Err(cause) => cause,
    };
    let stats = mux.registry_connection.read_stats();
    let (committed_read_failed, cause) = match cause {
        NoLockFreeAnswer::CommittedRead(error) => (true, error),
        NoLockFreeAnswer::TwoCuts(error) => (false, error),
    };
    let fallbacks = stats.list_fell_back(committed_read_failed);
    crate::debug_spans::mark("terminal_list.fallback");
    // One line at the 1st, 2nd, 4th, 8th... fallback: a daemon that takes
    // this path for each list says so, and never with one line for each list.
    if fallbacks.is_power_of_two() {
        let what = if committed_read_failed {
            "its committed read failed"
        } else {
            "its rows and its live terminals did not agree"
        };
        eprintln!(
            "cmux-tui: terminal.list read under the registry and state locks ({what}; \
             fallback {fallbacks}): {cause:#}"
        );
    }
    mux.with_resource_projection(|registry, state| {
        let (durable_terminals, terminal_resource_ids, tabs) =
            registry.read_state(load_terminal_list_rows)?;
        public_terminal_values(
            mux,
            &durable_terminals,
            terminal_resource_ids,
            &tabs,
            |terminal_id| state.terminal_catalog.get(terminal_id).cloned(),
            &last_sessions,
        )
    })
    .map_err(|error| {
        stats.fallback_failed();
        operation_failed(error)
    })
}

/// The list from two cuts and no registry lock: the stored rows as one
/// committed read, then each terminal's live surface handle under the state
/// lock.
fn lock_free_terminals(
    mux: &Mux,
    last_sessions: &HashMap<String, (String, Option<String>)>,
) -> Result<Vec<Value>, NoLockFreeAnswer> {
    let (durable_terminals, terminal_resource_ids, tabs) =
        read_committed_registry(mux, |connection, _| load_terminal_list_rows(connection))
            .map_err(NoLockFreeAnswer::CommittedRead)?;
    let surfaces = mux.with_state(|state| {
        terminal_resource_ids
            .iter()
            .filter_map(|(_, terminal_id)| {
                let surface = state.terminal_catalog.get(terminal_id)?;
                Some((terminal_id.clone(), surface.clone()))
            })
            .collect::<HashMap<_, _>>()
    });
    #[cfg(test)]
    if let Some(hook) = BETWEEN_CUTS_HOOK.with(|slot| slot.borrow_mut().take()) {
        hook();
    }
    // A terminal that ended between the two cuts (its runtime gave up its
    // durable identity while this list held its handle) fails the identity
    // checks of the builder.
    public_terminal_values(
        mux,
        &durable_terminals,
        terminal_resource_ids,
        &tabs,
        |terminal_id| surfaces.get(terminal_id).cloned(),
        last_sessions,
    )
    .map_err(NoLockFreeAnswer::TwoCuts)
}
