//! Fixture logs for RFD 0161's replay: a clean session passes, and each seeded violation fails
//! the invariant it breaks.

use super::*;
use crate::store::MemoryStore;

fn rec(seq: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: seq * 1_000, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

fn init(seq: u64, model: &str, tools: &[&str]) -> EventRecord {
    rec(
        seq,
        "in",
        "claude.system.init",
        json!({"type": "system", "subtype": "init", "model": model, "tools": tools, "output_style": "default"}),
    )
}

fn start(seq: u64, model: &str) -> EventRecord {
    rec(
        seq,
        "in",
        "claude.stream_event",
        json!({"type": "stream_event", "parent_tool_use_id": null,
            "event": {"type": "message_start", "message": {"model": model, "usage": {}}}}),
    )
}

/// A main-loop call that read `read` tokens and left `context` behind, its cache good for an hour.
fn call(seq: u64, read: u64, context: u64) -> EventRecord {
    rec(
        seq,
        "in",
        "usage_update",
        json!({"method": "session/update", "params": {"sessionId": "c", "update": {
            "sessionUpdate": "usage_update", "inputTokens": 10, "cachedReadTokens": read,
            "cachedWriteTokens": 100, "outputTokens": 50, "used": context - 50,
            "contextTokens": context,
            "_meta": {"acpmux": {"call": true, "cacheExpiresAt": seq * 1_000 + 3_600_000}}}}}),
    )
}

fn store(log: &[EventRecord]) -> MemoryStore {
    let store = MemoryStore::default();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "c", "name": "fixture", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    for r in log {
        store.append("c", r).unwrap();
    }
    store
}

fn clean() -> Vec<EventRecord> {
    vec![
        init(1, "claude-opus-5-5", &["Bash", "Read"]),
        start(2, "claude-opus-5-5"),
        call(3, 0, 20_000),
        start(4, "claude-opus-5-5"),
        call(5, 19_000, 30_000),
        // A restart logs the init again, the same.
        init(6, "claude-opus-5-5", &["Bash", "Read"]),
        start(7, "claude-opus-5-5"),
        call(8, 29_000, 40_000),
    ]
}

fn run(log: &[EventRecord]) -> Replay {
    replay(&store(log), &["c".into()]).unwrap()
}

#[test]
fn a_clean_log_passes_and_counts() {
    let r = run(&clean());
    assert_eq!(r.violations, 0, "{r:#?}");
    assert_eq!(r.sessions[0].calls, 3);
    assert_eq!(r.sessions[0].inits, 2);
    assert_eq!(r.counters["harnessMagic.scorecard.replaySessions"], 1);
    assert_eq!(r.counters["harnessMagic.scorecard.violations.stableInputs"], 0);
    assert_eq!(r.counters["harnessMagic.scorecard.violations.cacheAgrees"], 0);
    assert_eq!(r.not_yet.len(), 3);
}

#[test]
fn a_tools_change_fails_invariant_2() {
    let mut log = clean();
    log[5] = init(6, "claude-opus-5-5", &["Bash", "Read", "Write"]);
    let r = run(&log);
    let v = &r.sessions[0].violations;
    assert_eq!(v.len(), 1, "{v:#?}");
    assert_eq!((v[0].invariant, v[0].name, v[0].seq), (2, STABLE_INPUTS, 6));
    assert!(v[0].detail.contains("+[Write]"), "{}", v[0].detail);
    assert_eq!(r.counters["harnessMagic.scorecard.violations.stableInputs"], 1);
}

#[test]
fn a_model_change_fails_invariant_2() {
    let mut log = clean();
    log[6] = start(7, "claude-sonnet-5-5");
    let r = run(&log);
    let v: Vec<_> = r.sessions[0].violations.iter().filter(|v| v.invariant == 2).collect();
    assert_eq!(v.len(), 1, "{:#?}", r.sessions[0].violations);
    assert!(v[0].detail.contains("claude-sonnet-5-5"));
}

#[test]
fn an_unexplained_cache_collapse_fails_invariant_5() {
    let mut log = clean();
    log[7] = call(8, 1_000, 40_000);
    let r = run(&log);
    let v = &r.sessions[0].violations;
    assert_eq!(v.len(), 1, "{v:#?}");
    assert_eq!((v[0].invariant, v[0].name, v[0].seq), (5, CACHE_AGREES, 8));
    assert_eq!(r.sessions[0].collapses["unknown"], 1);
    assert_eq!(r.counters["harnessMagic.scorecard.violations.cacheAgrees"], 1);
}

#[test]
fn a_declared_boundary_exempts_a_collapse() {
    let boundaries = [
        rec(6, "in", "claude.system.compact_boundary", json!({"subtype": "compact_boundary"})),
        rec(6, "mux", "harness_surgery", json!({"removed": 3})),
        rec(
            6,
            "in",
            "compaction",
            json!({"params": {"update": {"sessionUpdate": "compaction", "state": "done"}}}),
        ),
        rec(6, "in", "config_option_update", json!({"params": {"update": {}}})),
    ];
    for boundary in boundaries {
        let mut log = clean();
        log[5] = boundary.clone();
        log[7] = call(8, 1_000, 40_000);
        let r = run(&log);
        assert_eq!(r.violations, 0, "{} {:#?}", boundary.kind, r.sessions[0].violations);
        assert_eq!(r.sessions[0].collapses.values().sum::<u64>(), 1);
    }
}

#[test]
fn an_expired_cache_exempts_a_collapse() {
    let mut log = clean();
    // Two hours later: past the hour the call before named.
    let mut late = call(8, 1_000, 40_000);
    late.at = 5_000 + 7_200_000;
    log[7] = late;
    let r = run(&log);
    assert_eq!(r.violations, 0, "{:#?}", r.sessions[0].violations);
    assert_eq!(r.sessions[0].collapses["expired"], 1);
}

#[test]
fn a_subagent_call_is_not_judged() {
    let mut log = clean();
    let mut sub = call(8, 0, 40_000);
    sub.msg["params"]["update"].as_object_mut().unwrap().remove("contextTokens");
    log[7] = sub;
    assert_eq!(run(&log).violations, 0);
}

#[test]
fn a_fork_starts_fresh() {
    let mut log = vec![init(1, "claude-sonnet-5-5", &["Bash"]), call(2, 0, 90_000)];
    log.push(rec(3, "mux", "forked", json!({"from": "p"})));
    log.extend(clean().into_iter().map(|mut r| {
        r.seq += 3;
        r.at += 3_000;
        r
    }));
    let r = run(&log);
    assert_eq!(r.violations, 0, "{:#?}", r.sessions[0].violations);
    assert_eq!(r.sessions[0].calls, 3);
}

#[test]
fn sessions_resolve_by_prefix_or_name_and_name_the_missing() {
    let s = store(&clean());
    let r = replay(&s, &["fixture".into(), "zzz".into()]).unwrap();
    assert_eq!(r.sessions.len(), 1);
    assert_eq!(r.missing, vec!["zzz".to_owned()]);
    assert_eq!(replay(&s, &[]).unwrap().sessions.len(), 1);
}

#[test]
fn the_off_switch_names_scorecard() {
    use crate::hub::harness_magic::enabled_in;
    assert!(enabled_in("scorecard", None, &|_| None));
    assert!(!enabled_in("scorecard", None, &|k| (k == "ACPMUX_HM_SCORECARD").then(|| "0".into())));
    let doc = json!({"agents": {"harnessMagic": {"scorecard": {"enabled": false}}}});
    assert!(!enabled_in("scorecard", Some(&doc), &|_| None));
}
