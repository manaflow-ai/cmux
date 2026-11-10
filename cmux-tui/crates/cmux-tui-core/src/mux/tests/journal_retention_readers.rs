//! What the readers of agent sessions get after retention deleted records.
//!
//! Retention deletes sealed journal records below its floor. An agent that
//! started a session and then stayed idle has every record of that session
//! below the floor after some hours. The app shows agent sessions in the
//! vault and in the agents palette and resumes one by its id; it needs each
//! session's terminal and tab for that. A reader that folds the journal from
//! its first retained record no longer finds such a session. So the daemon,
//! which keeps the fold of every agent record with its cursor, must give the
//! reader the whole session: `history.entries.list` is that answer.
#![cfg(unix)]

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::journal_retention_bound::{
    ACTIVE_AGENTS, AGENTS, RECORDS, head, session, write_through,
};
use super::*;
use crate::history_ops::{AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION};
use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
use crate::mux::agent_roster_restore::restore_agent_roster;

/// The terminal and the tab of each agent session, by the provider's session
/// id, as a fold of the journal from its first retained record gives them:
/// what the app's own fold of `session.journal.subscribe` from `beginning`
/// had.
fn folded_from_the_first_retained_record(
    mux: &Mux,
) -> BTreeMap<String, (Option<String>, Option<String>)> {
    let mut fold = cmux_history::AgentSessionFold::with_capacity("local", 5000);
    let mut sequence = 0;
    loop {
        let page = mux.session_journal_after(sequence, 500).unwrap();
        let Some(last) = page.records.last() else { break };
        sequence = last.sequence;
        let records = page
            .records
            .iter()
            .filter(|record| record.kind.starts_with("agent."))
            .map(|record| serde_json::to_value(record).unwrap())
            .collect::<Vec<_>>();
        fold.apply(&records);
    }
    fold.ordered()
        .into_iter()
        .map(|session| {
            (session.session_id.clone(), (session.terminal.clone(), session.tab.clone()))
        })
        .collect()
}

/// The agent rows of `history.entries.list`, by the provider's session id.
fn listed_agents(mux: &Arc<Mux>) -> BTreeMap<String, Value> {
    let mut fields = Map::new();
    fields.insert("kinds".into(), json!(["agent"]));
    fields.insert("limit".into(), json!(crate::history_ops::MAX_LIST));
    let listed = crate::history_ops::list_for_test(mux, &fields).expect("history list answers");
    assert!(listed.get("pending_kinds").is_none(), "the list folded the whole journal");
    listed["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .filter_map(|entry| Some((entry["session_id"].as_str()?.to_owned(), entry.clone())))
        .collect()
}

/// An agent session whose records are all below the retention floor is still
/// in the list the app reads, with the terminal, the tab and the times the
/// app's vault, agents palette and resume by id use.
#[test]
fn an_agent_session_below_the_retention_floor_keeps_its_terminal_and_tab_in_the_list() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-retention-readers-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let (mux, agents) = session(1, &root);
    assert!(mux.settle_agent_roster_for_test(), "the agent roster's owner settles");
    // No record is deleted yet: the fold of the whole journal has each
    // session with its terminal and tab.
    let whole = folded_from_the_first_retained_record(&mux);
    assert_eq!(whole.len(), AGENTS, "the journal has each agent's session: {whole:?}");
    for agent in &agents {
        let (terminal, tab) = &whole[&agent.session];
        assert_eq!(terminal.as_deref(), Some(agent.terminal.as_str()));
        println!("journal_retention_readers: {} terminal={terminal:?} tab={tab:?}", agent.session);
    }
    // Each record of an idle agent is at or below this sequence.
    let idle_end = head(&mux);
    let idle = &agents[ACTIVE_AGENTS..];

    let mut next_step = 0;
    write_through(&mux, &agents, &mut next_step, idle_end + RECORDS);
    for _ in 0..32 {
        mux.run_journal_maintenance_for_test();
    }

    // The setup: retention deleted every record of the idle agents, so a
    // fold of the journal alone does not have their sessions.
    let floor = mux.journal_pruned_through().unwrap();
    assert!(
        floor >= idle_end,
        "the setup: retention deleted through {floor}; the idle agents' records end at {idle_end}"
    );
    let retained = folded_from_the_first_retained_record(&mux);
    for agent in idle {
        assert!(
            !retained.contains_key(&agent.session),
            "the setup: the journal still has a record of the idle session {}",
            agent.session
        );
    }

    let listed = listed_agents(&mux);
    let mut problems = Vec::new();
    for agent in &agents {
        let (terminal, tab) = &whole[&agent.session];
        let Some(row) = listed.get(&agent.session) else {
            problems.push(format!("the list lost the session {}", agent.session));
            continue;
        };
        let text = |field: &str| row.get(field).and_then(Value::as_str).map(str::to_owned);
        if text("terminal") != *terminal {
            problems.push(format!(
                "{}: terminal is {:?}, the journal said {terminal:?}",
                agent.session,
                text("terminal")
            ));
        }
        if text("tab") != *tab {
            problems.push(format!(
                "{}: tab is {:?}, the journal said {tab:?}",
                agent.session,
                text("tab")
            ));
        }
        if text("started_at_ms").and_then(|time| time.parse::<u64>().ok()).is_none() {
            problems.push(format!("{}: no started_at_ms", agent.session));
        }
        if row.get("ended_at_ms").is_some() {
            problems.push(format!("{}: a session that did not end has ended_at_ms", agent.session));
        }
    }

    mux.shutdown();
    drop(agents);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        problems.is_empty(),
        "the list the app reads does not carry what the app's own journal fold had: {problems:#?}"
    );
}

/// S2 of the migration review asked for a floor term "the oldest live agent".
/// The floor has no such term: on a Mac whose agents rest for weeks it would
/// keep every record since the oldest of them started. What the term was for
/// is held by the saved states: a live agent whose records are ALL deleted
/// stays in the roster the daemon serves, in the roster a start restores
/// (with no rebuild from the journal), and in the list the app reads, where
/// its session has not ended.
#[test]
fn a_live_agent_with_every_record_deleted_stays_in_the_roster_a_start_and_the_list() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-retention-live-agent-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let (mux, agents) = session(1, &root);
    assert!(mux.settle_agent_roster_for_test(), "the agent roster's owner settles");
    let idle_end = head(&mux);
    let idle = &agents[ACTIVE_AGENTS..];

    let mut next_step = 0;
    write_through(&mux, &agents, &mut next_step, idle_end + RECORDS);
    for _ in 0..32 {
        mux.run_journal_maintenance_for_test();
    }
    // The setup: rows are deleted, not only a floor computed.
    let floor = mux.journal_pruned_through().unwrap();
    assert!(
        floor >= idle_end,
        "the setup: retention deleted through {floor}; the idle agents' records end at {idle_end}"
    );
    let first_retained =
        mux.session_journal_after(0, 1).unwrap().records.first().map(|record| record.sequence);
    assert!(
        first_retained.is_some_and(|sequence| sequence > idle_end),
        "the setup: the journal still has record {first_retained:?}, at or below {idle_end}"
    );

    let mut problems = Vec::new();
    assert!(mux.settle_agent_roster_for_test(), "the agent roster's owner settles");
    for agent in idle {
        if mux.agent_roster_state_now_for_test(agent.terminal.as_str()).is_none() {
            problems.push(format!("the served roster lost the live agent of {}", agent.terminal));
        }
    }
    let live = mux.agent_roster.lock().unwrap().roster.snapshot();
    let restored = {
        let registry = mux.workspace_registry.lock().unwrap();
        restore_agent_roster(&registry)
    };
    match restored {
        Ok(restored) => {
            if restored.rebuild {
                problems.push("a start would rebuild the roster from the journal".into());
            }
            for agent in idle {
                if !restored.host.roster.entries.contains_key(agent.terminal.as_str()) {
                    problems.push(format!("a start loses the live agent of {}", agent.terminal));
                }
            }
            if restored.host.roster.snapshot() != live {
                problems.push("a start restores a roster that is not the served roster".into());
            }
        }
        Err(error) => problems.push(format!("the roster does not restore: {error:#}")),
    }
    let listed = listed_agents(&mux);
    for agent in idle {
        match listed.get(&agent.session) {
            None => problems.push(format!("the list lost the live session {}", agent.session)),
            Some(row) if row.get("ended_at_ms").is_some() => {
                problems.push(format!("the list says the live session {} ended", agent.session));
            }
            Some(_) => {}
        }
    }

    mux.shutdown();
    drop(agents);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        problems.is_empty(),
        "a live agent whose records retention deleted is lost: {problems:#?}"
    );
}

/// The provider's session id of the agent that rests in
/// [`stopped_store_after_a_prune`].
const RESTED_SESSION: &str = "session-below-the-floor";

/// A stopped daemon's registry in which a first agent started a session and
/// then rested, a second agent worked, and retention deleted every record of
/// the first one. The saved roster and the saved agent history fold are then
/// the only copies of the first agent. Returns its terminal.
fn stopped_store_after_a_prune(session: &str, root: &Path) -> TerminalPublicId {
    let mux = open_persistent_test_mux(session, root);
    // The worker ticks each 30 s; this setup runs the same tick itself.
    mux.stop_journal_maintenance();
    let rested = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    append_journal_hook(&mux, &rested, "SessionStart", Some(RESTED_SESSION));
    let rested_end = mux.session_journal_head().unwrap();
    let live = mux.new_workspace(None, None).unwrap().terminal_public_id().cloned().unwrap();
    append_journal_hook(&mux, &live, "SessionStart", Some("session-live"));
    for cycle in 0..32 {
        for _ in 0..32 {
            append_journal_hook(&mux, &live, "UserPromptSubmit", Some("session-live"));
            append_journal_hook(&mux, &live, "Stop", Some("session-live"));
        }
        mux.create_journal_checkpoint("client_test", &format!("bump_{cycle}_checkpoint")).unwrap();
        mux.run_journal_maintenance_for_test();
        mux.run_journal_maintenance_for_test();
    }
    let floor = mux.journal_pruned_through().unwrap();
    assert!(
        floor >= rested_end,
        "the setup: retention deleted through {floor}; the rested agent's records end at \
         {rested_end}"
    );
    let first_retained =
        mux.session_journal_after(0, 1).unwrap().records.first().map(|record| record.sequence);
    assert!(
        first_retained.is_some_and(|sequence| sequence > rested_end),
        "the setup: the journal still has record {first_retained:?}, at or below {rested_end}"
    );
    assert!(roster_agent_state(&mux, &rested).is_some(), "the setup: the roster has the agent");
    mux.shutdown();
    drop(mux);
    rested
}

/// The saved state of `reducer` in a stopped store, written back as
/// `version`: what a build with another reducer version finds at its start.
/// The setup fails when the state is not of `saved_version` or does not
/// hold `needle`.
fn save_as_another_version(
    session: &str,
    root: &Path,
    reducer: &str,
    saved_version: u32,
    version: u32,
    needle: &str,
) {
    let registry = WorkspaceRegistry::open(root, session).unwrap();
    let (found, cursor, snapshot) =
        registry.journal_reducer_state(reducer).unwrap().expect("the setup: a saved state");
    assert_eq!(found, saved_version, "the setup: {reducer} is saved at the current version");
    assert!(snapshot.contains(needle), "the setup: the saved {reducer} holds {needle}");
    registry.put_journal_reducer_state(reducer, version, cursor, &snapshot).unwrap();
}

/// A build with a newer agent roster reducer starts on a registry where
/// retention deleted every record of a live agent. The start serves the
/// saved roster (migrated) and rebuilds it in the background. A rebuild from
/// the first RETAINED record would not have that agent: the rebuild must go
/// on from the served roster, and the roster it saves must hold the agent.
#[test]
fn a_roster_version_bump_after_retention_keeps_an_agent_whose_records_are_deleted() {
    let session = "retention-roster-bump";
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-retention-roster-bump-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let rested = stopped_store_after_a_prune(session, &root);
    save_as_another_version(
        session,
        &root,
        AGENT_ROSTER_REDUCER_ID,
        AGENT_ROSTER_REDUCER_VERSION,
        AGENT_ROSTER_REDUCER_VERSION - 1,
        rested.as_str(),
    );

    let mut problems = Vec::new();
    let reopened = open_persistent_test_mux(session, &root);
    reopened.stop_journal_maintenance();
    if roster_agent_state(&reopened, &rested).is_none() {
        problems.push("the roster the start serves lost the agent".to_owned());
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    while reopened.agent_roster_rebuilding() && Instant::now() < deadline {
        settled(&reopened);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!reopened.agent_roster_rebuilding(), "the roster rebuild ends");
    if roster_agent_state(&reopened, &rested).is_none() {
        problems.push("the rebuilt roster lost the agent".to_owned());
    }
    {
        let registry = reopened.workspace_registry.lock().unwrap();
        let (version, _, snapshot) =
            registry.journal_reducer_state(AGENT_ROSTER_REDUCER_ID).unwrap().unwrap();
        assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION, "the rebuild saves its roster");
        if !snapshot.contains(rested.as_str()) {
            problems.push("the roster the rebuild saved lost the agent".to_owned());
        }
    }

    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        problems.is_empty(),
        "a roster reducer version bump after retention loses an agent: {problems:#?}"
    );
}

/// A build with another version of the agent history fold starts on a
/// registry where retention deleted every record of an agent session. A
/// saved fold of another version used to be dropped and the journal folded
/// again: from the first RETAINED record, so the session left the list the
/// app reads, and the next save wrote the smaller fold over the only copy.
#[test]
fn a_history_fold_version_bump_after_retention_keeps_a_session_whose_records_are_deleted() {
    let session = "retention-history-bump";
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-retention-history-bump-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let rested = stopped_store_after_a_prune(session, &root);
    save_as_another_version(
        session,
        &root,
        AGENT_FOLD_STATE_ID,
        AGENT_FOLD_STATE_VERSION,
        AGENT_FOLD_STATE_VERSION + 1,
        RESTED_SESSION,
    );

    let mut problems = Vec::new();
    let reopened = open_persistent_test_mux(session, &root);
    reopened.stop_journal_maintenance();
    match listed_agents(&reopened).get(RESTED_SESSION) {
        None => problems.push("the list lost the session".to_owned()),
        Some(row) if row.get("terminal").and_then(Value::as_str) != Some(rested.as_str()) => {
            problems.push(format!("the session's terminal is {:?}", row.get("terminal")));
        }
        Some(_) => {}
    }
    // The next save is of this build's version and still holds the session.
    let folded = crate::history_ops::fold_for_retention(&reopened, Duration::from_secs(30), 1);
    assert!(folded.unwrap(), "the agent history fold reaches the journal head");
    {
        let registry = reopened.workspace_registry.lock().unwrap();
        let (version, _, snapshot) =
            registry.journal_reducer_state(AGENT_FOLD_STATE_ID).unwrap().unwrap();
        if version != AGENT_FOLD_STATE_VERSION {
            problems.push(format!("the saved fold is still of version {version}"));
        }
        if !snapshot.contains(RESTED_SESSION) {
            problems.push("the saved fold lost the session".to_owned());
        }
    }

    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        problems.is_empty(),
        "an agent history fold version bump after retention loses a session: {problems:#?}"
    );
}
