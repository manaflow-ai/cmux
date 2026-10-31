//! The agent roster's saved cursor keeps up with the journal between agent
//! events.
//!
//! Lawrence 2026-10-30: the roster saved its cursor only when an agent event
//! arrived, so a quiet stretch left it behind the journal head; on the
//! nightly registry it was 9,821 records behind, and every start decoded 13
//! sealed segments (about 300 ms cold) to fold records that change nothing.
//! The maintenance worker now folds the tail on its ticks and saves the
//! cursor, so a start replays at most one tick of records.

use super::*;

fn saved_roster_cursor(mux: &Mux) -> u64 {
    mux.workspace_registry
        .lock()
        .unwrap()
        .journal_reducer_state(crate::journal_reducers::AGENT_ROSTER_REDUCER_ID)
        .unwrap()
        .map_or(0, |(_, cursor, _)| cursor)
}

#[test]
fn a_maintenance_tick_saves_the_roster_cursor_at_the_journal_head() {
    let root = std::env::temp_dir()
        .join(format!("cmux-roster-catch-up-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("roster-catch-up", &root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &terminal_id, "SessionStart", Some("agent-catch-up"));
    assert_eq!(roster_agent_state(&mux, &terminal_id).as_deref(), Some("idle"));
    let after_agent = saved_roster_cursor(&mux);
    assert!(after_agent > 0, "an agent event saves the roster");

    // A quiet stretch: journal records, none from an agent.
    for index in 0..20 {
        mux.create_empty_workspace(Some(format!("quiet-{index}")), None, None).unwrap();
    }
    let head = mux.workspace_registry.lock().unwrap().session_journal_head().unwrap();
    assert!(head > after_agent, "the quiet stretch appended journal records");

    mux.catch_up_agent_roster();

    assert_eq!(
        saved_roster_cursor(&mux),
        head,
        "the next start would replay {} records that change nothing",
        head - after_agent
    );
    assert_eq!(roster_agent_state(&mux, &terminal_id).as_deref(), Some("idle"));
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
