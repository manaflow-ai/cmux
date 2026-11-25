use super::*;
use crate::store::{EventRecord, MemoryStore, Store};
use serde_json::json;

fn rec(at: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq: at, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

fn prompt(at: u64, id: &str) -> EventRecord {
    rec(
        at,
        "mux",
        "user_message",
        json!({"promptId": id, "_meta": {"origin": {"actor": "person"}}}),
    )
}

fn steer(at: u64, id: &str) -> EventRecord {
    rec(at, "mux", "user_message", json!({"promptId": id, "steer": true}))
}

fn coordinator(at: u64, id: &str) -> EventRecord {
    rec(
        at,
        "mux",
        "user_message",
        json!({"promptId": id, "_meta": {"provenance": {"kind": "agent_message"}}}),
    )
}

fn notice(at: u64, id: &str) -> EventRecord {
    rec(
        at,
        "mux",
        "user_message",
        json!({"promptId": id, "_meta": {"provenance": {"kind": "inbox_notice"}}}),
    )
}

fn tool(at: u64, kind: &str, id: &str, extra: Value) -> EventRecord {
    let mut update = json!({"sessionUpdate": kind, "toolCallId": id});
    if let (Some(u), Some(e)) = (update.as_object_mut(), extra.as_object()) {
        u.extend(e.clone());
    }
    rec(at, "in", kind, json!({"params": {"update": update}}))
}

fn result(at: u64, extra: Value) -> EventRecord {
    let mut msg = json!({"status": "completed", "inputTokens": 10, "outputTokens": 5,
        "cacheReadTokens": 80, "cacheWriteTokens": 5, "inputExcludesCache": true,
        "costUsd": 0.5, "modelCalls": 3});
    if let (Some(m), Some(e)) = (msg.as_object_mut(), extra.as_object()) {
        m.extend(e.clone());
    }
    rec(at, "mux", "turn_result", msg)
}

fn store(log: &[EventRecord], meta_extra: Value) -> MemoryStore {
    let store = MemoryStore::default();
    let mut meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "c", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1_000_000,
    });
    if let (Some(m), Some(e)) = (meta.as_object_mut(), meta_extra.as_object()) {
        m.extend(e.clone());
    }
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    for r in log {
        store.append("c", r).unwrap();
    }
    store
}

fn card(store: &MemoryStore) -> Scorecard {
    let options =
        ScorecardOptions::from_params(&json!({"since": 0, "steerWindowS": 60}), 2_000_000);
    summarize_with(store, &options, &|_| true).unwrap()
}

#[test]
fn steers_are_corrections_from_the_person_or_a_coordinator_during_or_just_after_a_turn() {
    let log = [
        prompt(1_000, "p1"),
        steer(2_000, "s1"), // into the running turn
        result(10_000, json!({})),
        coordinator(30_000, "p2"), // 20 s after its end: a steer of turn 1, and turn 2's prompt
        notice(35_000, "n1"),      // automated, while turn 2 runs: no steer
        result(40_000, json!({})),
        prompt(200_000, "p3"), // long after: a new task, no steer
        result(210_000, json!({})),
        steer(211_000, "s2"), // after the end, re-sent as the next prompt under its id
        prompt(212_000, "s2"),
        result(220_000, json!({})),
    ];
    let c = card(&store(&log, json!({})));
    let t = &c.totals;
    assert_eq!(t.turns, 4);
    assert_eq!(t.steers, 3, "{t:?}");
    assert_eq!(t.steers_sent, 2);
    assert_eq!(t.prompts_person, 2, "s2's second message counts once");
    assert_eq!(t.prompts_coordinator, 1);
    assert_eq!(t.prompts_automated, 0, "a notice inside a turn opens none");
    assert_eq!(t.steering_rate, Some(0.75));
    assert_eq!(t.steers_per_100_prompts, Some(100.0));
    assert_eq!(t.model_calls, 12);
    assert_eq!(t.requests_per_turn, Some(3.0));
    assert_eq!(t.cache_hit_ratio, Some(80.0 / 95.0));
    assert!((t.leo_units - 2.0).abs() < 1e-9);
}

#[test]
fn first_useful_result_is_a_completed_edit_a_commit_or_a_moved_head() {
    let log = [
        prompt(1_000, "p1"),
        rec(1_500, "out", "session/prompt", json!({})),
        rec(3_500, "in", "claude.stream_event", json!({})),
        tool(4_000, "tool_call", "e1", json!({"kind": "edit"})),
        tool(5_000, "tool_call_update", "e1", json!({"status": "failed"})),
        tool(6_000, "tool_call", "e2", json!({"kind": "edit"})),
        tool(9_000, "tool_call_update", "e2", json!({"status": "completed"})),
        result(10_000, json!({"gitHead": "aaa"})),
        prompt(20_000, "p2"),
        tool(
            21_000,
            "tool_call",
            "x1",
            json!({"kind": "execute", "rawInput": {"command": "git commit -m x"}}),
        ),
        tool(25_000, "tool_call_update", "x1", json!({"status": "completed"})),
        result(30_000, json!({"gitHead": "bbb"})),
        prompt(40_000, "p3"),
        result(50_000, json!({"gitHead": "ccc"})), // a head moved with no tool call seen
        prompt(60_000, "p4"),
        result(70_000, json!({"gitHead": "ccc"})), // nothing useful
    ];
    let c = card(&store(&log, json!({})));
    let t = &c.totals;
    assert_eq!(t.useful_turns, 3);
    assert_eq!(t.ttfu.count, 3);
    assert_eq!(t.ttfu.median_ms, Some(8_000));
    assert_eq!(t.session_ttfu.median_ms, Some(8_000));
    assert_eq!(t.first_model.median_ms, Some(2_000));
}

#[test]
fn turns_split_by_the_features_they_ran_with_and_counters_sum() {
    let log = [
        prompt(1_000, "p1"),
        result(2_000, json!({})), // an older build: no harnessMagic
        prompt(3_000, "p2"),
        result(4_000, json!({"harnessMagic": {"enabled": []}})),
        prompt(5_000, "p3"),
        result(6_000, json!({"harnessMagic": {"enabled": ["verify"], "verify": {"runs": 2}}})),
        prompt(7_000, "p4"),
        result(
            8_000,
            json!({"harnessMagic": {"enabled": ["verify", "prefetch"]},
            "harnessMagic.prefetch.files": 4}),
        ),
    ];
    let c = card(&store(&log, json!({})));
    assert_eq!(c.by_enabled_set["none"].turns, 2);
    assert_eq!(c.by_enabled_set["verify"].turns, 1);
    assert_eq!(c.by_enabled_set["prefetch,verify"].turns, 1);
    assert_eq!(c.by_feature["verify"].on.turns, 2);
    assert_eq!(c.by_feature["verify"].off.turns, 2);
    assert_eq!(c.by_feature["prefetch"].on.turns, 1);
    assert_eq!(c.totals.harness_magic["verify.runs"], 2);
    assert_eq!(c.totals.harness_magic["prefetch.files"], 4);
    assert_eq!(c.totals.sessions, 1);
}

#[test]
fn pull_requests_count_on_the_turn_that_opened_them_and_settle_from_any_session() {
    let pr = "https://github.com/o/r/pull/5";
    let log =
        [prompt(1_000, "p1"), result(10_000, json!({"harnessMagic": {"enabled": ["verify"]}}))];
    let s = store(
        &log,
        json!({"pullRequests": [pr], "pullRequestTimes": {pr: 5_000},
            "closedPullRequests": [pr]}),
    );
    let c = card(&s);
    assert_eq!(c.totals.prs_opened, 1);
    assert_eq!(c.totals.prs_settled, 1);
    assert_eq!(c.by_enabled_set["verify"].prs_settled, 1);
    assert_eq!(c.totals.tokens_per_settled_pr, Some(100.0));
    assert_eq!(c.attributed_tokens_per_settled_pr, Some(100.0));
    assert_eq!(c.sessions[0].settled_pull_requests, vec![pr.to_owned()]);
}

#[test]
fn a_forks_copies_count_in_its_parent_only_and_the_range_cuts_turns() {
    let log = [
        prompt(1_000, "p1"),
        result(2_000, json!({})),
        rec(3_000, "mux", "forked", json!({})),
        prompt(4_000, "p2"),
        result(5_000, json!({})),
    ];
    let c = card(&store(&log, json!({})));
    assert_eq!(c.totals.turns, 1);
    let options = ScorecardOptions::from_params(&json!({"since": 4_500}), 2_000_000);
    let late = summarize_with(&store(&log, json!({})), &options, &|_| true).unwrap();
    assert_eq!(late.totals.turns, 1);
    let options = ScorecardOptions::from_params(&json!({"since": 6_000}), 2_000_000);
    let none = summarize_with(&store(&log, json!({})), &options, &|_| true).unwrap();
    assert_eq!(none.totals.turns, 0);
    assert!(none.sessions.is_empty());
}
