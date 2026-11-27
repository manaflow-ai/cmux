//! An agent that works for hours stays current in History.
//!
//! A hook report that changes no durable state gets no journal row
//! (`agent_hooks_at_rest.rs`). The history folds took a session's last
//! activity from its newest `agent.*` row, so during a long turn that time
//! stopped at the turn's start: an agent at work for 3 hours sorted as 3
//! hours old. The time is live state: the daemon keeps it in memory and
//! serves it to every reader of History. The journal gets at most one
//! coalesced row each 5 minutes for the whole session, with the times of the
//! terminals that reported, so a reader of the journal alone (another
//! machine's fold, this daemon after a kill) is right to 5 minutes and one
//! report gap, and a clean stop writes the last times.
//!
//! The guard runs a 3-hour turn on a real on-disk registry. The clock is
//! driven, nothing sleeps; rows are counted, not timed.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;

/// Lawrence's daemon had 170 agents in 826 workspaces (2026-11-10).
const MAX_AGENTS: usize = 170;
const TURN_MS: u64 = 3 * 60 * 60 * 1000;
/// One tool report of each agent per simulated 30 s.
const REPORT_GAP_MS: u64 = 30_000;
/// The journal gets at most one activity row per this long.
const ACTIVITY_ROW_INTERVAL_MS: u64 = 5 * 60 * 1000;
/// The native event of the daemon's coalesced activity row.
const ACTIVITY_NATIVE_EVENT: &str = "AgentActivityObserved";
const CWD: &str = "/work/project";
const SESSION: &str = "agent-activity";

struct Agent {
    terminal: TerminalPublicId,
    session: String,
}

fn wall_clock_ms() -> u64 {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
    u64::try_from(now.as_millis()).unwrap()
}

/// One hook of `agent`, observed at `at_ms`, through the real journal ingress
/// path.
fn send_at(
    mux: &Arc<Mux>,
    agent: &Agent,
    event: &str,
    mut native: Value,
    at_ms: u64,
) -> crate::JournalAppendCommit {
    native["session_id"] = json!(agent.session);
    native["cwd"] = json!(CWD);
    let mut ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(agent.terminal.as_str()),
        native,
    )
    .unwrap();
    crate::agent_hooks::stamp_agent_hook_observed_at(&mut ingress, at_ms);
    let key = format!("agent-activity-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap()
}

/// A session of `workspaces` workspaces with one agent terminal in each (at
/// most `MAX_AGENTS`), every agent in a turn that started at `start_ms`.
fn session_in_a_turn(workspaces: usize, root: &Path, start_ms: u64) -> (Arc<Mux>, Vec<Agent>) {
    let mux = open_persistent_test_mux(SESSION, root);
    mux.stop_journal_maintenance();
    mux.set_agent_activity_clock_for_test(start_ms);
    let keys = (0..workspaces)
        .map(|_| mux.create_empty_workspace(None, None, None).unwrap().key)
        .collect::<Vec<_>>();
    let agents = (0..workspaces.min(MAX_AGENTS))
        .map(|index| {
            let raw = format!("00000000000040008000{:012x}", index + 1);
            let incarnation = format!("10000000000040008000{:012x}", index + 1);
            mux.seed_running_terminal_for_test(&raw, &incarnation, &keys[index % workspaces])
                .unwrap();
            let terminal =
                mux.workspace_registry.lock().unwrap().terminal_resource_id(&raw).unwrap().unwrap();
            Agent { terminal, session: format!("activity-session-{index}") }
        })
        .collect::<Vec<_>>();
    for agent in &agents {
        send_at(&mux, agent, "SessionStart", json!({}), start_ms);
        send_at(&mux, agent, "UserPromptSubmit", json!({ "prompt": "go on" }), start_ms);
    }
    assert!(mux.settle_agent_roster_for_test(), "the agent roster's owner settles");
    (mux, agents)
}

/// The last-activity time of each agent session as `history.entries.list`
/// answers it.
fn listed_times(mux: &Arc<Mux>) -> BTreeMap<String, u64> {
    let mut fields = Map::new();
    fields.insert("kinds".into(), json!(["agent"]));
    fields.insert("limit".into(), json!(crate::history_ops::MAX_LIST));
    let listed = crate::history_ops::list_for_test(mux, &fields).expect("history list answers");
    assert!(listed.get("pending_kinds").is_none(), "the list folded the whole journal");
    listed["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .filter_map(|entry| {
            Some((entry["session_id"].as_str()?.to_owned(), entry["at_ms"].as_str()?.parse().ok()?))
        })
        .collect()
}

/// What a reader of the journal alone gets: the agent fold over a bounded
/// read of every record, and the rows after `after` by what they are.
struct JournalRead {
    times: BTreeMap<String, u64>,
    /// Coalesced activity rows.
    activity_rows: usize,
    /// `agent.state.changed` rows of single reports.
    report_rows: usize,
}

fn read_journal(mux: &Mux, after: u64) -> JournalRead {
    let mut fold = cmux_history::AgentSessionFold::with_capacity("local", 5000);
    let (mut activity_rows, mut report_rows) = (0, 0);
    let mut sequence = 0;
    loop {
        let page = mux.session_journal_after(sequence, 500).unwrap();
        let Some(last) = page.records.last() else { break };
        sequence = last.sequence;
        let mut agent_records = Vec::new();
        for record in &page.records {
            if !record.kind.starts_with("agent.") {
                continue;
            }
            if record.sequence > after && record.kind == "agent.state.changed" {
                if record.payload["native_event"] == ACTIVITY_NATIVE_EVENT {
                    activity_rows += 1;
                } else {
                    report_rows += 1;
                }
            }
            agent_records.push(serde_json::to_value(record).unwrap());
        }
        fold.apply(&agent_records);
    }
    let times = fold
        .ordered()
        .into_iter()
        .map(|session| {
            (session.session_id.clone(), u64::try_from(session.last_activity_ms).unwrap_or(0))
        })
        .collect();
    JournalRead { times, activity_rows, report_rows }
}

/// The age at `now_ms` of the oldest last-activity time among `agents`
/// (`now_ms` itself for a session the reader does not have).
fn oldest_age_ms(times: &BTreeMap<String, u64>, agents: &[Agent], now_ms: u64) -> u64 {
    agents
        .iter()
        .map(|agent| now_ms.saturating_sub(times.get(&agent.session).copied().unwrap_or(0)))
        .max()
        .unwrap_or(0)
}

/// A turn of 3 simulated hours: every agent reports a tool call each 30 s.
fn a_long_turn_stays_current_in_history(workspaces: usize) {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-activity-{}", crate::workspace_registry::new_uuid_v4()));
    // In the past, so no time is ahead of the registry's own commit times.
    let end_ms = wall_clock_ms() - 60 * 60 * 1000;
    let start_ms = end_ms - TURN_MS;
    let (mux, agents) = session_in_a_turn(workspaces, &root, start_ms);
    let before = mux.session_journal_head().unwrap();

    let mut now_ms = start_ms;
    let mut round = 0_usize;
    while now_ms + REPORT_GAP_MS <= end_ms {
        now_ms += REPORT_GAP_MS;
        mux.set_agent_activity_clock_for_test(now_ms);
        for (index, agent) in agents.iter().enumerate() {
            // Each agent starts a tool call in one round and completes it in
            // the next. Neighbours are half a call apart, so the report that
            // comes right after an activity row is a completed call: no wait
            // for the roster's owner here, the row must not make that report
            // (or any other) a journal row.
            let event =
                if (round + index).is_multiple_of(2) { "PreToolUse" } else { "PostToolUse" };
            let tool = json!({ "tool_name": "Read", "tool_input": { "file_path": "/a.rs" } });
            let answer = send_at(&mux, agent, event, tool, now_ms);
            assert!(answer.sequence > 0, "the hook's caller gets a receipt: {answer:?}");
        }
        round += 1;
    }
    let reports = round * agents.len();
    let arm = format!(
        "{} agents in {workspaces} workspaces, a turn of {} minutes, {reports} tool reports",
        agents.len(),
        TURN_MS / 60_000,
    );

    // (i) A reader of History in the running daemon.
    let listed_age = oldest_age_ms(&listed_times(&mux), &agents, now_ms);
    assert!(
        listed_age < ACTIVITY_ROW_INTERVAL_MS,
        "{arm}: history.entries.list shows a last activity {} s old; an agent at work must \
         show one under {} s old",
        listed_age / 1000,
        ACTIVITY_ROW_INTERVAL_MS / 1000,
    );

    // (ii) The journal alone, as a reader has it after the daemon was killed
    // now: right to one row interval and one report gap, and the turn cost at
    // most one row per interval for all terminals.
    let journal = read_journal(&mux, before);
    let journal_age = oldest_age_ms(&journal.times, &agents, now_ms);
    let most_rows = usize::try_from(TURN_MS / ACTIVITY_ROW_INTERVAL_MS).unwrap();
    println!(
        "AGENT-ACTIVITY {arm}: list age {} s, journal-only age {} s, {} activity rows, {} \
         report rows, {} journal rows in all",
        listed_age / 1000,
        journal_age / 1000,
        journal.activity_rows,
        journal.report_rows,
        mux.session_journal_head().unwrap() - before,
    );
    assert!(
        journal_age < ACTIVITY_ROW_INTERVAL_MS + REPORT_GAP_MS,
        "{arm}: a fold of the journal alone shows a last activity {} s old",
        journal_age / 1000,
    );
    assert_eq!(journal.report_rows, 0, "{arm}: a report that changes nothing durable is no row");
    assert!(
        (1..=most_rows).contains(&journal.activity_rows),
        "{arm}: {} activity rows; at most one per {} s for all terminals is {most_rows}",
        journal.activity_rows,
        ACTIVITY_ROW_INTERVAL_MS / 1000,
    );

    // (iii) A clean stop writes the last times: after a restart both readers
    // have them.
    mux.shutdown();
    drop(mux);
    let reopened = open_persistent_test_mux(SESSION, &root);
    reopened.stop_journal_maintenance();
    let journal = read_journal(&reopened, before);
    let journal_age = oldest_age_ms(&journal.times, &agents, now_ms);
    let listed_age = oldest_age_ms(&listed_times(&reopened), &agents, now_ms);
    println!(
        "AGENT-ACTIVITY {arm}: after a restart, list age {} s, journal age {} s, {} activity rows",
        listed_age / 1000,
        journal_age / 1000,
        journal.activity_rows,
    );
    assert!(
        journal_age < ACTIVITY_ROW_INTERVAL_MS && listed_age < ACTIVITY_ROW_INTERVAL_MS,
        "{arm}: after a restart the last activity is {} s old in the journal and {} s old in \
         history.entries.list",
        journal_age / 1000,
        listed_age / 1000,
    );
    assert!(
        journal.activity_rows <= most_rows + 1,
        "{arm}: {} activity rows with the one of the stop",
        journal.activity_rows,
    );
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn agent_activity_a_long_turn_stays_current_in_a_light_session() {
    a_long_turn_stays_current_in_history(1);
}

#[test]
fn agent_activity_a_long_turn_stays_current_in_a_large_session() {
    a_long_turn_stays_current_in_history(60);
}

#[test]
fn agent_activity_a_long_turn_stays_current_in_a_real_session() {
    a_long_turn_stays_current_in_history(826);
}

/// Agents that report nothing cost nothing: 3 hours with no report, and a
/// clean stop, write no activity row.
#[test]
fn agent_activity_no_report_writes_no_row() {
    let root = std::env::temp_dir()
        .join(format!("cmux-agent-activity-idle-{}", crate::workspace_registry::new_uuid_v4()));
    let end_ms = wall_clock_ms() - 60 * 60 * 1000;
    let (mux, _agents) = session_in_a_turn(60, &root, end_ms - TURN_MS);
    let before = mux.session_journal_head().unwrap();
    mux.set_agent_activity_clock_for_test(end_ms);
    assert_eq!(read_journal(&mux, before).activity_rows, 0);
    mux.shutdown();
    drop(mux);
    let reopened = open_persistent_test_mux(SESSION, &root);
    reopened.stop_journal_maintenance();
    assert_eq!(read_journal(&reopened, before).activity_rows, 0, "the stop wrote no row");
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}
