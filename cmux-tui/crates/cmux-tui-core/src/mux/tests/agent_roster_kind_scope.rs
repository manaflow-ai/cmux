//! An agent roster replay costs the records the roster folds, not the
//! journal's history around them.
//!
//! Leo's restore on 2026-11-08 took 26 min: the agent roster's reducer
//! version changed, so the daemon's start replayed the journal from its
//! first record, about 12M rows other than terminal output, 96.6% of them
//! `personal.session.put`, which the roster discards. These tests count
//! SQLite VM steps (deterministic, unlike wall time).

use std::time::{Duration, Instant};

use serde_json::json;

use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
use crate::mux::agent_roster_restore::restore_agent_roster;
use crate::workspace_registry::WorkspaceRegistry;
use crate::workspace_registry::session_journal::kind_read::TestJournalRecord;
use crate::{JournalProducer, JournalSubject};

/// Terminals with an agent in the cost test; each has a fixed lifecycle.
const AGENT_TERMINALS: usize = 8;

fn terminal_id(index: usize) -> String {
    format!("term_{index:032x}")
}

fn terminal_subjects(terminal: &str) -> Vec<JournalSubject> {
    vec![JournalSubject { kind: "terminal".into(), id: terminal.into() }]
}

fn hook_producer() -> JournalProducer {
    JournalProducer { kind: "agent_adapter".into(), id: crate::AGENT_HOOK_PRODUCER_ID.into() }
}

/// An agent hook event as `agent_hook_journal_ingress` builds it.
fn hook_record(terminal: &str, native_event: &str, session: &str) -> TestJournalRecord {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        native_event,
        Some(terminal),
        json!({ "session_id": session }),
    )
    .unwrap();
    TestJournalRecord {
        kind: ingress.kind,
        producer: hook_producer(),
        subjects: ingress.subjects,
        payload: ingress.payload,
    }
}

/// The presentation store's record of one `personal.session.put`: a peer
/// session announcing itself, the journal's churn on a long-lived machine.
fn session_put(index: usize) -> TestJournalRecord {
    let session = format!("sess_{:032x}", index % 64);
    TestJournalRecord {
        kind: "personal.session.put".into(),
        producer: JournalProducer { kind: "presentation".into(), id: "cmux-tui".into() },
        subjects: vec![JournalSubject { kind: "session".into(), id: session.clone() }],
        payload: json!({
            "session": {"session_id": session, "last_seen_ms": index},
            "created": false,
            "personal_revision": index,
        }),
    }
}

/// Each agent terminal starts a session and a turn.
fn agent_lifecycles() -> Vec<TestJournalRecord> {
    (0..AGENT_TERMINALS)
        .flat_map(|index| {
            let terminal = terminal_id(index);
            let session = format!("agent-{index}");
            [
                hook_record(&terminal, "SessionStart", &session),
                hook_record(&terminal, "UserPromptSubmit", &session),
            ]
        })
        .collect()
}

/// `agents` spread evenly through `churn` session puts.
fn interleave(agents: Vec<TestJournalRecord>, churn: usize) -> Vec<TestJournalRecord> {
    let stride = churn / agents.len().max(1) + 1;
    let mut agents = agents.into_iter();
    let mut records = Vec::with_capacity(churn + agents.len());
    for index in 0..churn {
        if index % stride == 0
            && let Some(agent) = agents.next()
        {
            records.push(agent);
        }
        records.push(session_put(index));
    }
    records.extend(agents);
    records
}

/// What one roster restore after a reducer version change cost.
struct ReplayCost {
    steps: u64,
    elapsed: Duration,
}

/// A registry whose journal holds the agent lifecycles among `churn`
/// session puts, and a roster snapshot of the previous reducer version at
/// the head: the start replays from the first record.
fn replay_after_version_bump(churn: usize) -> ReplayCost {
    let registry = WorkspaceRegistry::in_memory("roster-kind-scope-cost").unwrap();
    registry.append_journal_records_for_test(&interleave(agent_lifecycles(), churn));
    let head = registry.session_journal_head().unwrap();
    registry
        .put_journal_reducer_state(
            AGENT_ROSTER_REDUCER_ID,
            AGENT_ROSTER_REDUCER_VERSION - 1,
            head,
            "{}",
        )
        .unwrap();
    let mut restored = None;
    let started = Instant::now();
    let steps = registry.vm_steps_for_test(|| {
        restored = Some(restore_agent_roster(&registry));
    });
    let elapsed = started.elapsed();
    let restored = restored.unwrap().unwrap();
    assert_eq!(restored.host.cursor, head, "the replay reaches the head");
    let working =
        restored.host.roster.entries.values().filter(|entry| entry.state == "working").count();
    assert_eq!(working, AGENT_TERMINALS, "every agent's turn is folded");
    ReplayCost { steps, elapsed }
}

/// A roster replay after a version bump costs its agent events: 50x the
/// session churn adds less than one VM step per churn record. Reading every
/// record other than terminal output cost tens of steps for each one.
#[test]
fn roster_replay_after_a_version_bump_skips_session_churn() {
    let sizes = [1_000, 10_000, 50_000, 200_000];
    let costs = sizes.map(replay_after_version_bump);
    let table = sizes
        .iter()
        .zip(&costs)
        .map(|(churn, cost)| {
            format!(
                "{churn} session puts + {} agent events: {} VM steps, {:?}",
                AGENT_TERMINALS * 2,
                cost.steps,
                cost.elapsed
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    panic!("MEASURE\n{table}");
    #[allow(unreachable_code)]
    let (small, large) = (&costs[0], &costs[2]);
    let added = (sizes[2] - sizes[0]) as u64;
    let per_record = large.steps.saturating_sub(small.steps) / added;
    assert!(
        per_record < 1,
        "a roster replay costs {per_record} VM steps per session put it skips:\n{table}"
    );
}
