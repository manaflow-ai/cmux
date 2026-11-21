//! The daemon's coalesced activity row moves a known session's last activity
//! and nothing else.

use std::collections::HashMap;

use cmux_history::{AgentSessionFold, EntryContext, HiddenHistory};
use serde_json::{Value, json};

fn hook(sequence: u64, kind: &str, session: &str, at_ms: u64) -> Value {
    json!({
        "sequence": sequence,
        "kind": kind,
        "occurred_at_ms": at_ms,
        "subjects": [{ "kind": "terminal", "id": "terminal-1" }],
        "payload": {
            "adapter": { "id": "claude", "version": 1 },
            "normalized": {
                "agent_session_id": session,
                "observed_at_ms": at_ms.to_string(),
            },
        },
    })
}

fn activity_row(sequence: u64, stamps: &[(&str, &str, u64)]) -> Value {
    let activity = stamps
        .iter()
        .map(|(adapter, session, at_ms)| {
            json!({
                "adapter": adapter,
                "agent_session_id": session,
                "terminal": "terminal-1",
                "observed_at_ms": at_ms.to_string(),
            })
        })
        .collect::<Vec<_>>();
    json!({
        "sequence": sequence,
        "kind": "agent.state.changed",
        "occurred_at_ms": 9_000_000,
        "subjects": [],
        "payload": {
            "adapter": { "id": "cmux", "version": 1 },
            "native_event": "AgentActivityObserved",
            "normalized": { "observed_at_ms": "9000000", "activity": activity },
        },
    })
}

#[test]
fn an_activity_row_moves_only_the_last_activity_of_known_sessions() {
    let mut fold = AgentSessionFold::new("local");
    fold.apply(&[
        hook(1, "agent.session.started", "long", 1_000),
        hook(2, "agent.turn.started", "long", 2_000),
        hook(3, "agent.session.started", "done", 1_000),
        hook(4, "agent.session.ended", "done", 3_000),
    ]);
    let before = fold.clone();
    fold.apply(&[activity_row(
        5,
        &[
            ("claude", "long", 600_000),
            // An older time never moves a session back.
            ("claude", "done", 2_500),
            // A stamp of a session the fold never saw makes no session.
            ("claude", "unknown", 600_000),
            // The same id of another provider is another session.
            ("codex", "long", 900_000),
        ],
    )]);
    assert_eq!(fold.len(), before.len(), "a stamp never makes a session");
    assert_eq!(fold.cursor(), 5);
    let sessions = fold.ordered();
    let long = sessions.iter().find(|session| session.session_id == "long").unwrap();
    assert_eq!(long.last_activity_ms, 600_000);
    assert_eq!(long.started_at_ms, 1_000);
    assert_eq!(long.ended_at_ms, None);
    let done = sessions.iter().find(|session| session.session_id == "done").unwrap();
    assert_eq!((done.last_activity_ms, done.ended_at_ms), (3_000, Some(3_000)));
}

#[test]
fn a_host_serves_the_newer_of_the_journal_and_its_live_time() {
    let mut fold = AgentSessionFold::new("local");
    fold.apply(&[
        hook(1, "agent.session.started", "long", 1_000),
        hook(2, "agent.session.started", "idle", 5_000),
    ]);
    let context = EntryContext { local_machine: "local", available: true };
    let live = HashMap::from([("claude/long".to_owned(), 700_000_i64)]);
    let entries = fold.entries_with_live(&context, &HiddenHistory::default(), &live);
    let times = entries
        .iter()
        .map(|entry| (entry.session_id.as_deref().unwrap(), entry.at_ms))
        .collect::<Vec<_>>();
    assert_eq!(times, [("long", 700_000), ("idle", 5_000)], "newest first, by the live time");
    assert_eq!(fold.entries(&context, &HiddenHistory::default()).len(), 2);
    assert_eq!(fold.ordered()[0].session_id, "idle", "the fold itself keeps the journal's time");
}
