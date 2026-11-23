//! The output store's prune asks which terminals of the session are parked (`Mux::parked_terminal_ids`): the
//! workspace store keeps a tab of the terminal and no shell of it runs. A daemon start asks it for each terminal
//! of the session, with the registry lock and the state lock held.
//!
//! The check: a count with no clock. The read compiles the same number of statements at any number of parked
//! terminals.

use std::collections::HashSet;

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};

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

/// With no ended terminal the parked read compiles no statement: a terminal whose shell runs is not parked, and
/// the read does not ask the registry for the kept tabs.
#[test]
fn the_parked_read_compiles_no_statement_when_no_terminal_ended() {
    let (mux, root) = file_session_of("parked-read-none-ended", 4);
    let live = mux.workspace_registry.lock().unwrap().live_terminal_public_ids().unwrap();
    assert!(!live.is_empty(), "setup: the session has terminals");
    let each_runs = mux.with_state(|state| {
        live.iter()
            .all(|id| state.terminal_catalog.get(id).is_some_and(|surface| !surface.is_dead()))
    });
    assert!(each_runs, "setup: the shell of each terminal of the session runs");
    let mut named = HashSet::new();
    let statements = selects_of(&mux, || named = mux.parked_terminal_ids(live.clone()));
    assert!(named.is_empty(), "a terminal whose shell runs was named as parked: {named:?}");
    assert_eq!(statements, 0, "statements that the parked read compiled with no ended terminal");
    close_file_session(mux, root);
}

/// What `request` gives while the registry refuses each read of the table `kept_tabs` on the calling thread.
fn with_kept_tabs_unreadable<T>(mux: &Arc<Mux>, request: impl FnOnce() -> T) -> T {
    let request_thread = std::thread::current().id();
    let refuse = move |context: AuthContext<'_>| match context.action {
        AuthAction::Read { table_name: "kept_tabs", .. }
            if std::thread::current().id() == request_thread =>
        {
            Authorization::Deny
        }
        _ => Authorization::Allow,
    };
    mux.registry_connection.get().authorizer(Some(refuse)).unwrap();
    let out = request();
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    out
}

/// A read of the kept tabs that fails names no parked terminal. The pass of the output store that follows then
/// trims no snapshot and removes none (`with_no_parked_terminal_the_pass_changes_no_snapshot`): a failed read
/// can only keep bytes on disk.
#[test]
fn a_failed_read_of_the_kept_tabs_names_no_parked_terminal() {
    let name = "parked-read-refused";
    let (mux, root) = file_session_of(name, 4);
    let tabs: Vec<SurfaceId> =
        mux.with_state(|state| state.resource_indexes.content_ids.keys().copied().collect());
    let parked = mux.park_terminal_tabs(&tabs).unwrap();
    assert_eq!(parked.len(), tabs.len(), "setup: each tab of the session is parked");
    mux.shutdown();
    drop(mux);

    let reopened = open_persistent_test_mux(name, &root);
    let live = reopened.workspace_registry.lock().unwrap().live_terminal_public_ids().unwrap();
    assert!(!live.is_empty(), "setup: the restart keeps the terminals of the kept tabs");
    assert_eq!(
        reopened.parked_terminal_ids(live.clone()),
        live,
        "setup: with a read that works, each terminal of the session is parked"
    );
    let named = with_kept_tabs_unreadable(&reopened, || reopened.parked_terminal_ids(live.clone()));
    assert!(named.is_empty(), "a failed read of the kept tabs named parked terminals: {named:?}");
    assert_eq!(
        reopened.parked_terminal_ids(live.clone()),
        live,
        "the read works again after the refusal: the refusal was the cause"
    );
    close_file_session(reopened, root);
}
