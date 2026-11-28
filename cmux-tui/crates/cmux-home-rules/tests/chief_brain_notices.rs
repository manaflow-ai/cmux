//! `ChiefReplyWatchdog`, `ChiefSettleNotice`, `HomeEngineTurn`, `ModelRouterLease`,
//! `ChiefProfilePageRelay` and `PageCallDeadline` parity (HomeEngineTurnFieldsTests,
//! ChiefProfileRelayRoutingTests and the watchdog and settle suites).

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("chief_brain.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

/// 2026-10-21T10:00:00Z.
const SENT: f64 = 1_792_576_800.0;

fn summary(author: &str, kind: &str, client: &str, retracted: Value) -> Value {
    json!({
        "participants": [{"id": "agent_mux", "kind": "agent"}, {"id": author, "kind": kind}],
        "lastMessage": {"author": author, "clientMsgID": client, "createdAt": "2026-10-21T10:00:00Z", "retractedAt": retracted}
    })
}

fn watchdog(summary: Value, now: f64, running: bool) -> Value {
    op("reply_watchdog", json!({"summary": summary, "nowSecs": now, "brainRunning": running}))
}

#[test]
fn the_notice_shows_after_two_minutes_with_no_brain() {
    let s = summary("u1", "human", "c1", Value::Null);
    let r = watchdog(s.clone(), SENT + 119.0, false);
    assert_eq!(r["notice"], Value::Null);
    assert_eq!(r["nextCheckSecs"], json!(SENT + 120.0));
    let r = watchdog(s.clone(), SENT + 200.0, false);
    assert_eq!(r["notice"], json!("chiefNotRunning"));
    assert_eq!(r["nextCheckSecs"], json!(SENT + 240.0));
    assert_eq!(watchdog(s.clone(), SENT + 600.0, true)["notice"], Value::Null);
    let r = op("reply_watchdog", json!({"summary": s, "nowSecs": SENT + 200.0}));
    assert_eq!(r["pastLimit"], json!(true));
    assert_eq!(r["notice"], Value::Null, "no answer until the keeper is asked");
}

#[test]
fn agents_and_retracted_messages_wait_for_nothing() {
    let late = SENT + 600.0;
    let s = summary("u1", "human", "agent~claude-sr2-coord~result~~abc123", Value::Null);
    assert_eq!(watchdog(s, late, false)["notice"], Value::Null);
    let s = summary("agent_mux", "agent", "c1", Value::Null);
    assert_eq!(watchdog(s, late, false)["notice"], Value::Null);
    let s = summary("a9", "agent", "c1", Value::Null);
    assert_eq!(watchdog(s, late, false)["notice"], Value::Null);
    let s = summary("u1", "human", "c1", json!("2026-10-21T10:01:00Z"));
    assert_eq!(watchdog(s, late, false)["notice"], Value::Null);
    assert_eq!(watchdog(json!({}), late, false)["nextCheckSecs"], Value::Null);
}

#[test]
fn fractional_seconds_and_offsets_parse_alike() {
    let at = |created: &str| {
        let s = json!({"participants": [], "lastMessage": {"author": "u", "createdAt": created}});
        op("reply_watchdog", json!({"summary": s, "nowSecs": 0.0}))["waitingSinceSecs"].clone()
    };
    assert_eq!(at("2026-10-21T10:00:00Z"), json!(SENT));
    assert_eq!(at("2026-10-21T10:00:00.000Z"), json!(SENT));
    assert_eq!(at("2026-10-21T12:00:00+02:00"), json!(SENT));
    assert_eq!(at("yesterday"), Value::Null);
}

fn settle(json: Value, paused: bool) -> Value {
    op("settle_notice", json!({"json": json, "compactorPaused": paused}))["notice"].clone()
}

#[test]
fn the_settle_line_says_starting_then_organizing() {
    assert_eq!(
        settle(json!(r#"{"startingSecs":40}"#), false),
        json!({"kind": "stillStarting", "seconds": 40})
    );
    assert_eq!(
        settle(json!(r#"{"built":2,"total":5}"#), false),
        json!({"kind": "organizing", "built": 2, "total": 5})
    );
    assert_eq!(settle(json!(r#"{"built":2.0,"total":5}"#), false)["kind"], json!("organizing"));
    assert_eq!(settle(json!(r#"{"built":5,"total":5}"#), false), Value::Null);
    assert_eq!(settle(json!(r#"{"startingSecs":-1}"#), false), Value::Null);
    assert_eq!(settle(json!("not json"), false), Value::Null);
    assert_eq!(settle(Value::Null, true), json!({"kind": "memoryPaused"}));
    assert_eq!(settle(json!(r#"{"startingSecs":3}"#), true)["kind"], json!("stillStarting"));
}

#[test]
fn a_report_turn_carries_its_time_tokens_and_error() {
    let newer = json!({"turn": 7, "ts": 1_792_600_000_000_u64, "status": "error", "harness": "claude-sr2-pipe",
        "harness_profile": null, "model": "claude-opus-5-5", "effort": "high", "ms": 7840, "tools": 3,
        "tool_errors": 1, "cost_usd": null,
        "usage": {"input": 1000, "cache_read": 8000, "cache_write": 1000, "output": 2345},
        "reply": "Both subagents are done", "error": "harness exited"});
    let older = json!({"status": "ok", "harness": "claude", "model": "opus", "ms": 1200, "tools": 0,
        "tool_errors": 0, "cost_usd": 0.1442, "usage": {"input": 10, "cache_read": 10, "cache_write": 0}, "reply": "Done."});
    let r = op("engine_turns_from_report", json!({"turns": [newer, older]}));
    let t = &r["turns"][0];
    assert_eq!(t["endedSecs"], json!(1_792_600_000.0));
    assert_eq!(t["tokens"], json!(12_345.0));
    assert_eq!(t["hitRate"], json!(0.8));
    assert_eq!(t["effort"], json!("high"));
    assert_eq!(t["error"], json!("harness exited"));
    assert_eq!(t["seconds"], json!(7.84));
    assert_eq!(t["toolErrors"], json!(1));
    let o = &r["turns"][1];
    assert_eq!(o["endedSecs"], Value::Null);
    assert_eq!(o["cost"], json!(0.1442));
    assert_eq!(o["tokens"], json!(20.0));
    assert_eq!(o["hitRate"], json!(0.5));
}

const LINE: &str = r#"{"ev":"turn.end","ts":1792600000000,"harness":"claude","effort":"low","ms":900,"error":{"prefix":"boom"},"usage":{"input":5,"cache_read":0,"cache_write":5,"output":10}}"#;

#[test]
fn a_trace_line_carries_the_same_fields() {
    let t = op("engine_turn_from_line", json!({"line": LINE}))["turn"].clone();
    assert_eq!(t["endedSecs"], json!(1_792_600_000.0));
    assert_eq!(t["tokens"], json!(20.0));
    assert_eq!(t["hitRate"], json!(0.0));
    assert_eq!(t["effort"], json!("low"));
    assert_eq!(t["error"], json!("boom"));
    let none = op("engine_turn_from_line", json!({"line": r#"{"ev":"turn.start"}"#}));
    assert_eq!(none["turn"], Value::Null);
}

#[test]
fn recent_turns_are_the_last_turn_ends_newest_first() {
    let line = |n: u32| format!(r#"{{"ev":"turn.end","harness":"h{n}","ms":1}}"#);
    let today = format!("{}\n{{\"ev\":\"turn.start\"}}\n{}\n\n", line(1), line(2));
    let yesterday = format!("{}\n{}\n", line(3), line(4));
    let r = op("engine_turns_from_traces", json!({"texts": [today, null, yesterday], "limit": 3}));
    let harnesses: Vec<&str> =
        r["turns"].as_array().unwrap().iter().map(|t| t["harness"].as_str().unwrap()).collect();
    assert_eq!(harnesses, ["h2", "h1", "h4"]);
}

#[test]
fn usage_with_no_counts_is_unknown() {
    let r = op("engine_turn_usage", json!({"present": false, "input": 5}));
    assert_eq!(r, json!({"hitRate": null, "tokens": null}));
    let r = op("engine_turn_usage", json!({}));
    assert_eq!(r, json!({"hitRate": null, "tokens": null}));
    let r = op("engine_turn_usage", json!({"cacheRead": 3, "input": 1}));
    assert_eq!(r, json!({"hitRate": 0.75, "tokens": 4.0}));
}

#[test]
fn the_lease_renews_before_expiry_and_backs_off_on_failure() {
    let r = op(
        "lease_step",
        json!({"event": {"kind": "set", "expiresAtMs": 3_600_000, "pid": 10, "nowSecs": 0.0}}),
    );
    assert_eq!(r["expiresAt"], json!(3600));
    assert_eq!(r["waitSecs"], json!(3510.0));
    assert_eq!(r["state"]["forceRefresh"], json!(false));
    assert_eq!(r["log"], Value::Null);
    // A short token: wait at least 10 s and force a refresh next pass.
    let r2 = op(
        "lease_step",
        json!({"state": r["state"], "event": {"kind": "set", "expiresAtMs": 60_000, "pid": 11, "nowSecs": 0.0}}),
    );
    assert_eq!(r2["waitSecs"], json!(10.0));
    assert_eq!(r2["state"]["forceRefresh"], json!(true));
    assert!(r2["log"].as_str().unwrap().contains("pid 10 -> 11"));
    let mut state = r2["state"].clone();
    let mut waits = Vec::new();
    let mut logs = 0;
    for _ in 0..8 {
        let f = op(
            "lease_step",
            json!({"state": state, "event": {"kind": "failed", "error": "offline"}}),
        );
        waits.push(f["waitSecs"].as_f64().unwrap());
        logs += usize::from(!f["log"].is_null());
        state = f["state"].clone();
    }
    assert_eq!(waits, [2.0, 5.0, 15.0, 30.0, 60.0, 120.0, 120.0, 120.0]);
    assert_eq!(logs, 1, "only the first failure logs");
    let ok = op(
        "lease_step",
        json!({"state": state, "event": {"kind": "set", "expiresAtMs": 3_600_000, "pid": 11, "nowSecs": 0.0}}),
    );
    assert_eq!(ok["state"]["failures"], json!(0));
}

fn route(operation: &str, params: Value, gesture: Value, spent: Value) -> Value {
    op(
        "profile_relay_route",
        json!({"operation": operation, "params": params, "gestureEvent": gesture, "spentGesture": spent}),
    )
}

#[test]
fn undo_and_backend_fields_go_with_the_gesture_once() {
    let chief = json!({"chief": "agent_chief"});
    let r = route("chief.profile.undo", chief.clone(), json!(5.0), Value::Null);
    assert_eq!(
        r,
        json!({"known": true, "gesture": true, "spentGesture": 5.0, "deadlineSecs": 16.0})
    );
    let r = route("chief.profile.undo", chief.clone(), json!(5.0), json!(5.0));
    assert_eq!(r["gesture"], json!(false), "a spent gesture is not reused");
    assert_eq!(
        route(
            "chief.profile.undo",
            json!({"chief": "agent_chief", "to_rev": 2}),
            json!(6.0),
            Value::Null
        )["gesture"],
        json!(true)
    );
    assert_eq!(
        route("chief.profile.history", chief, json!(5.0), Value::Null)["gesture"],
        json!(false)
    );
    for field in ["locked", "harness", "model", "effort"] {
        let r = route(
            "chief.profile.update",
            json!({"chief": "agent_chief", field: "x"}),
            json!(1.0),
            Value::Null,
        );
        assert_eq!(r["gesture"], json!(true), "{field}");
    }
    let r = route(
        "chief.profile.update",
        json!({"chief": "agent_chief", "display_name": "Ship"}),
        json!(1.0),
        Value::Null,
    );
    assert_eq!(r["gesture"], json!(false));
    assert_eq!(
        route("chief.profile.update", json!({"locked": true}), Value::Null, Value::Null)["gesture"],
        json!(false)
    );
    assert_eq!(
        route("chief.profile.history", json!({}), Value::Null, Value::Null)["known"],
        json!(true)
    );
    assert_eq!(route("chief.other", json!({}), Value::Null, Value::Null)["known"], json!(false));
}

#[test]
fn a_lost_connection_retries_once_on_a_new_connection() {
    let retry = |attempt: u32, error: &str, current: bool| {
        op(
            "profile_relay_retry",
            json!({"attempt": attempt, "error": error, "usedCurrent": current}),
        )
    };
    assert_eq!(retry(1, "connectionClosed", true), json!({"retry": true, "dropRelay": true}));
    assert_eq!(retry(1, "notConnected", false), json!({"retry": true, "dropRelay": false}));
    assert_eq!(retry(2, "daemonShutdown", true), json!({"retry": false, "dropRelay": false}));
    assert_eq!(retry(1, "timedOut", true), json!({"retry": false, "dropRelay": false}));
}

#[test]
fn the_relay_connection_is_reused_only_for_the_same_owner() {
    let owner = json!({"socket": "/s", "pid": 4, "generation": "g1"});
    let reuse = |relay: Value, starting: Value| {
        op("profile_relay_reuse", json!({"owner": owner, "relay": relay, "starting": starting}))["reuse"].clone()
    };
    let ready = json!({"owner": owner, "ready": true, "identity": {"pid": 4, "generation": "g1"}});
    assert_eq!(reuse(ready, Value::Null), json!("reuse"));
    let other = json!({"owner": owner, "ready": true, "identity": {"pid": 4, "generation": "g2"}});
    assert_eq!(reuse(other.clone(), Value::Null), json!("connect"));
    assert_eq!(reuse(other, owner.clone()), json!("joinStarting"));
    let restarted = json!({"socket": "/s", "pid": 5, "generation": "g1"});
    assert_eq!(reuse(Value::Null, restarted), json!("connect"));
}

#[test]
fn a_page_call_answers_once() {
    let step =
        |state: Value, event: &str| op("page_call_step", json!({"state": state, "event": event}));
    let r = step(json!({}), "deadline");
    assert_eq!(r["answer"], json!("timedOut"));
    assert_eq!(r["state"]["answered"], json!(true));
    assert_eq!(
        step(r["state"].clone(), "finished")["answer"],
        Value::Null,
        "the late result is dropped"
    );
    assert_eq!(step(json!({}), "finished")["answer"], json!("result"));
    assert_eq!(step(json!({}), "cancelled")["answer"], json!("cancelled"));
}
