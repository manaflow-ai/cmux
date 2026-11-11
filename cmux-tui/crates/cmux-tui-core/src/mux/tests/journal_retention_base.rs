//! The base of a reducer on a registry with a retention floor
//! (`workspace_registry/journal_retention/base.rs`).
//!
//! After retention deleted records, the saved state of the agent roster and
//! of the agent history fold (`journal_reducer.<id>` in `meta`) is the only
//! copy of each agent and session below the floor, and every build writes
//! that key. A build from before 2026-11-09 does not decode the sealed
//! segments: it folds an empty roster and saves it there. A value that does
//! not load is folded again from the first RETAINED record. Each test here
//! puts one such value in the place of the saved state and starts this build
//! again: the agent below the floor is still served, the records above the
//! base are folded on top of it, and the state the start saves holds both.

use std::path::PathBuf;

use serde_json::Value;

use super::journal_retention_readers::{
    Damage, RESTED_SESSION, damage_saved_state, listed_agents, stopped_meta,
    stopped_store_after_a_prune,
};
use super::*;
use crate::history_ops::{AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION};
use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, AgentRoster};
use crate::mux::agent_roster_restore::{RosterFoldLimits, restore_agent_roster_with};

/// The agent roster reducer version of the nightly of 2026-11-03, the oldest
/// one this build migrates from.
const OLDER_ROSTER_VERSION: u32 = 6;

/// The provider's session id of the agent that starts after the last floor
/// move of [`store`].
const LATER_SESSION: &str = "session-above-the-base";

struct Store {
    session: &'static str,
    root: PathBuf,
    /// The terminal of the agent whose records are all below the floor.
    rested: TerminalPublicId,
    /// The terminal of the agent of [`LATER_SESSION`].
    later: TerminalPublicId,
    /// The journal head before the first record of the later agent.
    later_after: u64,
}

impl Drop for Store {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// The store of `stopped_store_after_a_prune`, then one more run of the
/// daemon in which a third agent starts a session and works. No floor moves
/// in that run: every record of the third agent is above the cursor of each
/// base. The roster and the agent history fold are saved at the head.
fn store(session: &'static str) -> Store {
    let root = std::env::temp_dir()
        .join(format!("cmux-{session}-{}", crate::workspace_registry::new_uuid_v4()));
    let rested = stopped_store_after_a_prune(session, &root);
    let mux = open_persistent_test_mux(session, &root);
    mux.stop_journal_maintenance();
    let later_after = mux.session_journal_head().unwrap();
    let later = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    append_journal_hook(&mux, &later, "SessionStart", Some(LATER_SESSION));
    for _ in 0..8 {
        append_journal_hook(&mux, &later, "UserPromptSubmit", Some(LATER_SESSION));
        append_journal_hook(&mux, &later, "Stop", Some(LATER_SESSION));
    }
    assert!(roster_agent_state(&mux, &later).is_some(), "the setup: the roster has the agent");
    assert!(
        roster_agent_state(&mux, &rested).is_some(),
        "the setup: a restart with its own saved roster serves the agent below the floor"
    );
    assert!(
        crate::history_ops::fold_for_retention(&mux, Duration::from_secs(30), 1).unwrap(),
        "the setup: the agent history fold reaches the journal head"
    );
    mux.shutdown();
    drop(mux);
    Store { session, root, rested, later, later_after }
}

/// The raw `meta` value of the base of `reducer` in the stopped store. What
/// is wrong with it goes to `problems`: there is none, it does not hold
/// `needle`, or its cursor is not below the later agent's first record.
fn base(store: &Store, reducer: &str, needle: &str, problems: &mut Vec<String>) -> Option<String> {
    let key = format!("journal_reducer_base.{reducer}");
    let Some(raw) = stopped_meta(store.session, &store.root, &key) else {
        problems.push(format!("retention deleted records and {reducer} has no base"));
        return None;
    };
    if !raw.contains(needle) {
        problems.push(format!("the base of {reducer} does not hold {needle}"));
    }
    let cursor = serde_json::from_str::<Value>(&raw)
        .ok()
        .and_then(|value| value["cursor"].as_str().and_then(|cursor| cursor.parse::<u64>().ok()));
    match cursor {
        Some(cursor) if cursor <= store.later_after => {}
        cursor => problems.push(format!(
            "the setup: the base of {reducer} has cursor {cursor:?}; the later agent's records \
             start after {}",
            store.later_after
        )),
    }
    Some(raw)
}

/// What a build from before 2026-11-09 leaves: an empty roster of its
/// reducer version, with the cursor at the journal head.
fn an_older_build_saves_an_empty_roster(store: &Store) {
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    let head = registry.session_journal_head().unwrap();
    registry
        .put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            OLDER_ROSTER_VERSION,
            head,
            &AgentRoster::default().snapshot().to_string(),
        )
        .unwrap();
}

/// One start of the daemon on the store, to the end of the roster's rebuild.
/// What is wrong with the roster it serves and with the roster it saved goes
/// to `problems`.
fn start_and_check_the_roster(store: &Store, problems: &mut Vec<String>) {
    let mux = open_persistent_test_mux(store.session, &store.root);
    mux.stop_journal_maintenance();
    if roster_agent_state(&mux, &store.rested).is_none() {
        problems.push("the roster the start serves lost the agent below the floor".to_owned());
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    while mux.agent_roster_rebuilding() && Instant::now() < deadline {
        settled(&mux);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!mux.agent_roster_rebuilding(), "the roster rebuild ends");
    for (name, terminal) in [("below the floor", &store.rested), ("above the base", &store.later)] {
        if roster_agent_state(&mux, terminal).is_none() {
            problems.push(format!("the roster lost the agent {name}"));
        }
    }
    {
        let registry = mux.workspace_registry.lock().unwrap();
        match registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID) {
            Ok(Some((version, _, snapshot))) => {
                if version != AGENT_ROSTER_REDUCER_VERSION {
                    problems.push(format!("the saved roster is of version {version}"));
                }
                for (name, terminal) in
                    [("below the floor", &store.rested), ("above the base", &store.later)]
                {
                    if !snapshot.contains(terminal.as_str()) {
                        problems.push(format!("the saved roster lost the agent {name}"));
                    }
                }
            }
            other => problems.push(format!("the saved roster does not read: {other:?}")),
        }
        if let Ok(Some(from)) = registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID) {
            problems.push(format!("a roster rebuild from version {from} is still owed"));
        }
    }
    mux.shutdown();
    drop(mux);
}

/// The return from a build from before 2026-11-09. That build saved an empty
/// roster of its version over the only copy of the agent below the floor.
/// This build migrates the empty roster with success, so nothing told it that
/// an agent was gone.
#[test]
fn an_empty_roster_of_an_older_build_does_not_lose_an_agent_below_the_floor() {
    let store = store("retention-base-older-roster");
    let mut problems = Vec::new();
    let before = base(&store, AGENT_ROSTER_REDUCER_ID, store.rested.as_str(), &mut problems);
    an_older_build_saves_an_empty_roster(&store);
    start_and_check_the_roster(&store, &mut problems);
    // No floor moved in that start: the base is the same bytes.
    let key = format!("journal_reducer_base.{AGENT_ROSTER_REDUCER_ID}");
    if before.is_some() && stopped_meta(store.session, &store.root, &key) != before {
        problems.push("a start with no floor move wrote the roster's base again".to_owned());
    }
    assert!(
        problems.is_empty(),
        "an older build's empty roster loses an agent below the retention floor: {problems:#?}"
    );
}

/// A saved roster that does not load. Its raw value is kept
/// (`journal_retention_readers.rs`); the agent below the floor must also
/// still be served.
#[test]
fn a_roster_that_does_not_load_does_not_lose_an_agent_below_the_floor() {
    for (name, damage) in [
        ("not-read", Damage::NotRead),
        ("cut", Damage::SnapshotCut),
        ("cursor", Damage::CursorAboveHead),
    ] {
        let store = store("retention-base-roster-damage");
        let mut problems = Vec::new();
        base(&store, AGENT_ROSTER_REDUCER_ID, store.rested.as_str(), &mut problems);
        damage_saved_state(store.session, &store.root, AGENT_ROSTER_REDUCER_ID, damage, name);
        start_and_check_the_roster(&store, &mut problems);
        assert!(
            problems.is_empty(),
            "a saved roster that does not load ({name}) loses an agent below the retention \
             floor: {problems:#?}"
        );
    }
}

/// The kill. After the return from an older build, the start of this build
/// is killed in its fold. What it wrote to the registry must not pass for
/// this build's own fold of the whole journal at the next start: the roster
/// that came from the older build's empty one is never saved at this build's
/// version with no rebuild owed. The next start has the agent, and the floor
/// move after it leaves the agent in the base.
#[test]
fn a_kill_in_the_rebuild_after_an_older_build_does_not_lose_the_agent() {
    let store = store("retention-base-kill");
    let mut problems = Vec::new();
    base(&store, AGENT_ROSTER_REDUCER_ID, store.rested.as_str(), &mut problems);
    an_older_build_saves_an_empty_roster(&store);

    // The start, killed after two pages of its fold, with a save after each
    // page: only what it wrote to the registry is left.
    {
        let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
        let limits = RosterFoldLimits { page: 4, save_every_pages: 1, stop_after_pages: Some(2) };
        if let Err(error) = restore_agent_roster_with(&registry, limits) {
            problems.push(format!("the start's roster restore failed: {error:#}"));
        }
        let owed = registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap();
        let (version, cursor, snapshot) =
            registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap().unwrap();
        if version == AGENT_ROSTER_REDUCER_VERSION
            && owed.is_none()
            && !snapshot.contains(store.rested.as_str())
        {
            problems.push(format!(
                "the killed start saved a roster without the agent as this build's own fold \
                 through {cursor}"
            ));
        }
    }
    start_and_check_the_roster(&store, &mut problems);

    // The next floor move, in a run of the daemon after that start.
    let mux = open_persistent_test_mux(store.session, &store.root);
    mux.stop_journal_maintenance();
    let deleted_before = mux.journal_pruned_through().unwrap();
    for cycle in 0..32 {
        for _ in 0..32 {
            append_journal_hook(&mux, &store.later, "UserPromptSubmit", Some(LATER_SESSION));
            append_journal_hook(&mux, &store.later, "Stop", Some(LATER_SESSION));
        }
        mux.create_journal_checkpoint("client_test", &format!("kill_{cycle}_checkpoint")).unwrap();
        mux.run_journal_maintenance_for_test();
        mux.run_journal_maintenance_for_test();
    }
    let deleted = mux.journal_pruned_through().unwrap();
    if deleted <= deleted_before {
        problems.push(format!(
            "the setup: the floor did not move after the restart; retention deleted through \
             {deleted_before} before and {deleted} after"
        ));
    }
    mux.shutdown();
    drop(mux);
    let key = format!("journal_reducer_base.{AGENT_ROSTER_REDUCER_ID}");
    match stopped_meta(store.session, &store.root, &key) {
        None => problems.push("the floor moved again and the roster has no base".to_owned()),
        Some(raw) => {
            if !raw.contains(store.rested.as_str()) {
                problems
                    .push("the floor move after the kill took the agent out of the base".into());
            }
            let cursor = serde_json::from_str::<Value>(&raw).ok().and_then(|value| {
                value["cursor"].as_str().and_then(|cursor| cursor.parse::<u64>().ok())
            });
            if cursor.is_none_or(|cursor| cursor < deleted) {
                problems.push(format!(
                    "the roster's base has cursor {cursor:?}; retention deleted through {deleted}"
                ));
            }
        }
    }
    assert!(
        problems.is_empty(),
        "a kill in the roster rebuild after an older build loses an agent: {problems:#?}"
    );
}

/// One start of the daemon on the store and one read of the list the app
/// reads. The session below the floor comes from the base; the later session
/// has all its records above the base's cursor, so the fold went on from
/// that cursor. What is wrong with the list and with the fold the start
/// saved goes to `problems`.
fn start_and_check_the_list(store: &Store, problems: &mut Vec<String>) {
    let sessions = [
        ("below the floor", RESTED_SESSION, &store.rested),
        ("above the base", LATER_SESSION, &store.later),
    ];
    let mux = open_persistent_test_mux(store.session, &store.root);
    mux.stop_journal_maintenance();
    let listed = listed_agents(&mux);
    for (name, session, terminal) in sessions {
        match listed.get(session) {
            None => problems.push(format!("the list lost the session {name}")),
            Some(row) if row.get("terminal").and_then(Value::as_str) != Some(terminal.as_str()) => {
                problems.push(format!(
                    "the terminal of the session {name} is {:?}",
                    row.get("terminal")
                ));
            }
            Some(_) => {}
        }
    }
    // The next save is of this build's version and holds both sessions.
    match crate::history_ops::fold_for_retention(&mux, Duration::from_secs(30), 1) {
        Ok(true) => {}
        other => problems.push(format!("the agent history fold did not reach the head: {other:?}")),
    }
    {
        let registry = mux.workspace_registry.lock().unwrap();
        match registry.journal_reducer_state(AGENT_FOLD_STATE_ID) {
            Ok(Some((version, _, snapshot))) => {
                if version != AGENT_FOLD_STATE_VERSION {
                    problems.push(format!("the saved fold is of version {version}"));
                }
                for (name, session, _) in sessions {
                    if !snapshot.contains(session) {
                        problems.push(format!("the saved fold lost the session {name}"));
                    }
                }
            }
            other => problems.push(format!("the saved fold does not read: {other:?}")),
        }
    }
    mux.shutdown();
    drop(mux);
}

/// A build with another version of the agent history fold saved an empty
/// fold at the head. A saved fold of another version is the start state on a
/// registry with a floor: the two sessions were gone from the list.
#[test]
fn an_empty_history_fold_of_another_build_does_not_lose_a_session_below_the_floor() {
    let store = store("retention-base-other-fold");
    let mut problems = Vec::new();
    base(&store, AGENT_FOLD_STATE_ID, RESTED_SESSION, &mut problems);
    {
        let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
        let head = registry.session_journal_head().unwrap();
        let empty = serde_json::to_string(&cmux_history::AgentSessionFold::new("local")).unwrap();
        registry
            .put_journal_reducer_state(
                AGENT_FOLD_STATE_ID,
                AGENT_FOLD_STATE_VERSION + 1,
                head,
                &empty,
            )
            .unwrap();
    }
    start_and_check_the_list(&store, &mut problems);
    assert!(
        problems.is_empty(),
        "another build's empty agent history loses a session below the retention floor: \
         {problems:#?}"
    );
}

/// A saved agent history fold that does not load. Its raw value is kept
/// (`journal_retention_readers.rs`); the session below the floor must also
/// still be listed, and the fold reads the records above the base's cursor.
#[test]
fn a_history_fold_that_does_not_load_does_not_lose_a_session_below_the_floor() {
    for (name, damage) in [
        ("not-read", Damage::NotRead),
        ("cut", Damage::SnapshotCut),
        ("cursor", Damage::CursorAboveHead),
    ] {
        let store = store("retention-base-fold-damage");
        let mut problems = Vec::new();
        base(&store, AGENT_FOLD_STATE_ID, RESTED_SESSION, &mut problems);
        damage_saved_state(store.session, &store.root, AGENT_FOLD_STATE_ID, damage, name);
        start_and_check_the_list(&store, &mut problems);
        assert!(
            problems.is_empty(),
            "a saved agent history that does not load ({name}) loses a session below the \
             retention floor: {problems:#?}"
        );
    }
}
