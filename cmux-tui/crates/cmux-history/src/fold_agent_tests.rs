use serde_json::{Value, json};

use super::{AgentSessionFold, agent_title, resume_command};
use crate::hidden::HiddenHistory;
use crate::journal::EntryContext;

fn record(sequence: u64, kind: &str, session: Option<&str>, provider: &str, ms: i64, cwd: Option<&str>, subjects: Value) -> Value {
    json!({
        "sequence": sequence, "kind": kind, "occurred_at_ms": ms, "subjects": subjects,
        "payload": {"adapter": {"id": provider}, "normalized": {"agent_session_id": session, "cwd": cwd}},
    })
}

fn simple(sequence: u64, kind: &str, session: &str, ms: i64) -> Value {
    record(sequence, kind, Some(session), "claude", ms, None, json!([]))
}

#[test]
fn start_turns_and_end_make_one_session() {
    let mut fold = AgentSessionFold::new("home");
    let subjects = json!([{"kind": "terminal", "id": "term_1"}, {"kind": "tab", "id": "tab_1"}, {"kind": "workspace", "id": "ws_1"}]);
    fold.apply(&[
        record(1, "agent.session.started", Some("s1"), "claude", 1_000, Some("/repo"), subjects),
        simple(2, "agent.turn.completed", "s1", 5_000),
        simple(3, "agent.session.ended", "s1", 9_000),
    ]);
    let ordered = fold.ordered();
    let session = ordered[0];
    assert_eq!(fold.len(), 1);
    assert_eq!(session.cwd.as_deref(), Some("/repo"));
    assert_eq!(session.terminal.as_deref(), Some("term_1"));
    assert_eq!(session.tab.as_deref(), Some("tab_1"));
    assert_eq!(session.workspace.as_deref(), Some("ws_1"));
    assert_eq!((session.started_at_ms, session.last_activity_ms, session.ended_at_ms), (1_000, 9_000, Some(9_000)));
    assert_eq!(fold.cursor(), 3);
}

#[test]
fn re_reading_old_records_does_not_double_count() {
    let mut fold = AgentSessionFold::new("home");
    let records = vec![simple(1, "agent.session.started", "s1", 1_000), simple(2, "agent.session.ended", "s1", 2_000)];
    fold.apply(&records);
    let mut again = records.clone();
    again.push(simple(3, "agent.session.started", "s1", 3_000));
    fold.apply(&again);
    assert_eq!(fold.len(), 1);
    // Resumed with the same id: running again.
    assert_eq!(fold.ordered()[0].ended_at_ms, None);
    assert_eq!(fold.cursor(), 3);
}

#[test]
fn activity_without_a_start_still_makes_a_session() {
    let mut fold = AgentSessionFold::new("box");
    fold.apply(&[record(7, "agent.turn.started", Some("x"), "codex", 4_000, None, json!([]))]);
    assert_eq!(fold.ordered()[0].provider, "codex");
    assert_eq!(fold.ordered()[0].machine, "box");
}

#[test]
fn records_without_a_session_id_are_ignored() {
    let mut fold = AgentSessionFold::new("home");
    fold.apply(&[record(1, "agent.state.changed", None, "claude", 1, None, json!([]))]);
    assert!(fold.is_empty());
    assert_eq!(fold.cursor(), 1);
}

#[test]
fn records_the_decoder_rejects_do_not_move_the_cursor() {
    let mut fold = AgentSessionFold::new("home");
    fold.apply(&[json!({"kind": "agent.session.started"}), json!({"sequence": "x", "kind": "agent.turn.started"})]);
    assert_eq!(fold.cursor(), 0);
}

#[test]
fn capacity_keeps_the_most_recently_active() {
    let mut fold = AgentSessionFold::with_capacity("home", 2);
    let records: Vec<Value> = (1..=4).map(|n| simple(n, "agent.session.started", &format!("s{n}"), n as i64 * 1000)).collect();
    fold.apply(&records);
    let ids: Vec<&str> = fold.ordered().iter().map(|session| session.session_id.as_str()).collect();
    assert_eq!(ids, ["s4", "s3"]);
}

#[test]
fn decodes_the_journal_envelope_with_string_numbers() {
    let record = json!({"sequence": "42", "kind": "agent.session.started", "occurred_at_ms": 1_785_715_200_000_i64, "class": "state",
        "subjects": [{"kind": "terminal", "id": "term_9"}, {"kind": "workspace", "id": "ws_2"}],
        "payload": {"format": "x", "adapter": {"id": "codex", "version": 1}, "native_event": "SessionStart",
            "normalized": {"agent_session_id": "abc", "cwd": "/tmp/p", "observed_at_ms": "1785715201000"}, "native": {}}});
    let mut fold = AgentSessionFold::new("home");
    fold.apply(&[record]);
    let session = fold.ordered()[0].clone();
    assert_eq!(fold.cursor(), 42);
    assert_eq!((session.provider.as_str(), session.session_id.as_str()), ("codex", "abc"));
    assert_eq!(session.cwd.as_deref(), Some("/tmp/p"));
    assert_eq!(session.started_at_ms, 1_785_715_201_000);
}

#[test]
fn string_occurrence_times_from_the_live_daemon() {
    let record = json!({"sequence": "30", "kind": "agent.session.started", "occurred_at_ms": "1790810388279",
        "subjects": [{"kind": "session", "id": "session_x"}],
        "payload": {"adapter": {"id": "claude", "version": 1}, "normalized": {"agent_session_id": "hist-test-1"}}});
    let mut fold = AgentSessionFold::new("home");
    fold.apply(&[record]);
    assert_eq!(fold.ordered()[0].started_at_ms, 1_790_810_388_279);
}

#[test]
fn entries_name_remote_machines_and_skip_hidden_sessions() {
    let mut fold = AgentSessionFold::new("box");
    fold.apply(&[
        record(1, "agent.session.started", Some("a"), "claude", 1_000, Some("/w/api"), json!([])),
        simple(2, "agent.session.started", "b", 2_000),
    ]);
    let mut hidden = HiddenHistory::new();
    hidden.hide_entry("box/claude/b");
    let entries = fold.entries(&EntryContext { local_machine: "home", available: false }, &hidden);
    assert_eq!(entries.len(), 1);
    let entry = &entries[0];
    assert_eq!(entry.id, "agent:box/claude/a");
    assert_eq!(entry.title, "Claude Code in api");
    assert_eq!(entry.machine.as_deref(), Some("box"));
    assert_eq!((entry.available, entry.running), (false, Some(true)));
    let local = fold.entries(&EntryContext { local_machine: "box", available: true }, &HiddenHistory::new());
    assert!(local.iter().all(|entry| entry.machine.is_none()));
}

#[test]
fn titles_and_resume_commands() {
    assert_eq!(agent_title("codex", None), "Codex");
    assert_eq!(agent_title("custom", Some("/a/b/")), "custom in b");
    assert_eq!(agent_title("amp", Some("/")), "Amp in /");
    assert_eq!(resume_command("claude", "0b1c-22").as_deref(), Some("claude --resume 0b1c-22"));
    assert_eq!(resume_command("codex", "a b'c").as_deref(), Some("codex resume 'a b'\\''c'"));
    assert_eq!(resume_command("unknown", "x"), None);
}
