//! The output store's prune asks which terminals of the session are parked (`Mux::parked_terminal_ids`): the
//! workspace store keeps a tab of the terminal and no shell of it runs. A daemon start asks it for each terminal
//! of the session, with the registry lock and the state lock held.
//!
//! The check: a count with no clock. The read compiles the same number of statements at any number of parked
//! terminals.

use std::collections::HashSet;

use super::tab_state_fields::{close_file_session, file_session_of, selects_of};
use super::*;

/// A session of `workspaces` workspaces on a file registry whose every terminal is parked (`park-tabs`), after a
/// restart: the statements that the parked read compiles for the terminals of the session, and how many
/// terminals it names.
fn parked_read_of(name: &str, workspaces: usize) -> (usize, usize) {
    let (mux, root) = file_session_of(name, workspaces);
    let tabs: Vec<SurfaceId> =
        mux.with_state(|state| state.resource_indexes.content_ids.keys().copied().collect());
    let parked = mux.park_terminal_tabs(&tabs).unwrap();
    assert_eq!(parked.len(), tabs.len(), "setup: each tab of the session is parked");
    mux.shutdown();
    drop(mux);

    let reopened = open_persistent_test_mux(name, &root);
    let live = reopened.workspace_registry.lock().unwrap().live_terminal_public_ids().unwrap();
    assert_eq!(live.len(), tabs.len(), "setup: the restart keeps the terminal of each kept tab");
    let mut named = HashSet::new();
    let statements = selects_of(&reopened, || named = reopened.parked_terminal_ids(live.clone()));
    assert_eq!(named, live, "setup: after the restart each terminal of the session is parked");
    close_file_session(reopened, root);
    (statements, named.len())
}

#[test]
fn the_parked_read_compiles_one_statement_set_at_any_number_of_terminals() {
    let (few, few_terminals) = parked_read_of("parked-read-few", 8);
    let (many, many_terminals) = parked_read_of("parked-read-many", 32);
    assert!(
        few_terminals >= 8 && many_terminals >= few_terminals * 4,
        "parked terminals: {few_terminals}, then {many_terminals}"
    );
    assert!(few > 0, "the count sees the statements of the parked read");
    assert_eq!(
        many, few,
        "the parked read compiled {few} statements for {few_terminals} parked terminals and {many} for \
         {many_terminals}: it reads the kept tabs with a statement of each terminal; one statement reads them \
         for the whole session"
    );
}
