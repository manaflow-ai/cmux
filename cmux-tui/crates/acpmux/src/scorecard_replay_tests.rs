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
    call_rw(seq, read, 100, context)
}

/// [`call`], writing `write` tokens to the cache: a collapse that wrote the prompt again.
fn call_rw(seq: u64, read: u64, write: u64, context: u64) -> EventRecord {
    rec(
        seq,
        "in",
        "usage_update",
        json!({"method": "session/update", "params": {"sessionId": "c", "update": {
            "sessionUpdate": "usage_update", "inputTokens": 10, "cachedReadTokens": read,
            "cachedWriteTokens": write, "outputTokens": 50, "used": context - 50,
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
    assert!(r.not_yet.is_empty());
    assert_eq!(r.checked.len(), 5);
    for name in [CONTEXT_EXTENDS, STABLE_INPUTS, OUTPUT_CAPPED, REREADS_BOUNDED, CACHE_AGREES] {
        assert_eq!(r.counters[&format!("harnessMagic.scorecard.violations.{name}")], 0);
    }
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
    // The prompt is whole (written to the cache again), so invariant 1 holds.
    log[7] = call_rw(8, 1_000, 29_000, 40_000);
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
    let mut late = call_rw(8, 1_000, 29_000, 40_000);
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

// Invariant 1: each call's context extends the one before.

#[test]
fn a_shrunk_prompt_fails_invariant_1() {
    let mut log = clean();
    // Read and wrote 20k of the 30k the call before left, the cache not collapsed.
    log[7] = call_rw(8, 16_000, 4_000, 40_000);
    let r = run(&log);
    let v = &r.sessions[0].violations;
    assert_eq!(v.len(), 1, "{v:#?}");
    assert_eq!((v[0].invariant, v[0].name, v[0].seq), (1, CONTEXT_EXTENDS, 8));
    assert!(v[0].detail.contains("20110 tokens"), "{}", v[0].detail);
    assert_eq!(r.counters["harnessMagic.scorecard.violations.contextExtends"], 1);
}

#[test]
fn a_small_shrink_is_within_the_slack() {
    let mut log = clean();
    // 1,500 short of 30,000: what Claude Code drops of a spent notice.
    log[7] = call_rw(8, 28_000, 400, 40_000);
    assert_eq!(run(&log).violations, 0);
}

#[test]
fn a_declared_boundary_exempts_a_shrink() {
    for boundary in [
        rec(6, "in", "claude.system.compact_boundary", json!({"subtype": "compact_boundary"})),
        rec(6, "mux", "harness_surgery", json!({"applied": true, "maskedResults": 0})),
        rec(6, "in", "config_option_update", json!({"params": {"update": {}}})),
    ] {
        let mut log = clean();
        log[5] = boundary.clone();
        log[7] = call(8, 1_000, 10_000);
        let r = run(&log);
        assert_eq!(r.violations, 0, "{} {:#?}", boundary.kind, r.sessions[0].violations);
    }
}

// Invariant 3: no tool result over the output cap.

fn tool(seq: u64, id: &str, kind: &str, tool: &str, input: Value) -> EventRecord {
    rec(
        seq,
        "in",
        "tool_call",
        json!({"params": {"update": {"sessionUpdate": "tool_call", "toolCallId": id,
            "kind": kind, "status": "pending", "rawInput": input,
            "_meta": {"claude": {"tool": tool}}}}}),
    )
}

fn done(seq: u64, id: &str, chars: usize) -> EventRecord {
    rec(
        seq,
        "in",
        "tool_call_update",
        json!({"params": {"update": {"sessionUpdate": "tool_call_update", "toolCallId": id,
            "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "x".repeat(chars)}}]}}}),
    )
}

fn turn(seq: u64) -> EventRecord {
    rec(seq, "mux", "turn_started", json!({}))
}

#[test]
fn results_under_the_caps_pass() {
    let log = vec![
        turn(1),
        tool(2, "a", "execute", "Bash", json!({"command": "make"})),
        done(3, "a", SHELL_CAP_CHARS),
        tool(4, "b", "read", "Read", json!({"file_path": "/f"})),
        done(5, "b", 90_000),
    ];
    let r = run(&log);
    assert_eq!(r.violations, 0, "{:#?}", r.sessions[0].violations);
    assert_eq!(r.sessions[0].tool_results, 2);
}

#[test]
fn a_result_over_the_cap_fails_invariant_3() {
    let log = vec![
        turn(1),
        tool(2, "a", "execute", "Bash", json!({"command": "cat big.log"})),
        done(3, "a", SHELL_CAP_CHARS + 1),
        tool(4, "b", "other", "mcp__x__get", json!({"url": "https://e"})),
        done(5, "b", TOKEN_CAP * CHARS_PER_TOKEN + 1),
        // A later update of the same call is not a second result.
        done(6, "b", TOKEN_CAP * CHARS_PER_TOKEN + 1),
    ];
    let r = run(&log);
    let v = &r.sessions[0].violations;
    assert_eq!(v.len(), 2, "{v:#?}");
    assert_eq!((v[0].invariant, v[0].name, v[0].seq), (3, OUTPUT_CAPPED, 3));
    assert!(v[0].detail.contains("Bash result of 30001"), "{}", v[0].detail);
    assert_eq!((v[1].invariant, v[1].seq), (3, 5));
    assert_eq!(r.counters["harnessMagic.scorecard.violations.outputCapped"], 2);
}

// Invariant 4: re-reads after a compaction or surgery stay bounded.

/// Four turns, one large read each, then `boundary`, then a turn that reads `again` of them.
fn reread_log(boundary: EventRecord, again: &[usize]) -> Vec<EventRecord> {
    let mut log = vec![];
    let mut seq = 0;
    let mut next = || {
        seq += 1;
        seq
    };
    for i in 0..4 {
        log.push(turn(next()));
        let id = format!("r{i}");
        log.push(tool(next(), &id, "read", "Read", json!({"file_path": format!("/f{i}")})));
        log.push(done(next(), &id, MIN_CHARS + 10));
    }
    // A small result is never counted as removed.
    log.push(tool(next(), "small", "read", "Read", json!({"file_path": "/small"})));
    log.push(done(next(), "small", 10));
    let mut b = boundary;
    b.seq = next();
    log.push(b);
    log.push(turn(next()));
    for i in again {
        let id = format!("again{i}");
        log.push(tool(next(), &id, "read", "Read", json!({"file_path": format!("/f{i}")})));
        log.push(done(next(), &id, MIN_CHARS + 10));
    }
    log.push(tool(next(), "s2", "read", "Read", json!({"file_path": "/small"})));
    log
}

fn compact_boundary() -> EventRecord {
    rec(0, "in", "claude.system.compact_boundary", json!({"subtype": "compact_boundary"}))
}

#[test]
fn a_few_rereads_after_a_compaction_pass() {
    let r = run(&reread_log(compact_boundary(), &[0, 1]));
    assert_eq!(r.violations, 0, "{:#?}", r.sessions[0].violations);
    assert_eq!((r.sessions[0].removals, r.sessions[0].refetched), (1, 2));
}

#[test]
fn rereading_most_of_a_compaction_fails_invariant_4() {
    let r = run(&reread_log(compact_boundary(), &[0, 1, 2, 3, 3]));
    let v = &r.sessions[0].violations;
    assert_eq!(v.len(), 1, "{v:#?}");
    assert_eq!((v[0].invariant, v[0].name), (4, REREADS_BOUNDED));
    assert!(v[0].detail.starts_with("4 of the 4 results"), "{}", v[0].detail);
    // The same path twice is one refetch.
    assert_eq!(r.sessions[0].refetched, 4);
    assert_eq!(r.counters["harnessMagic.scorecard.violations.rereadsBounded"], 1);
}

#[test]
fn a_compactions_two_records_are_one_removal() {
    let mut log = reread_log(compact_boundary(), &[0, 1, 2, 3]);
    let at = log.iter().position(|r| r.kind == "claude.system.compact_boundary").unwrap();
    let done_update =
        json!({"params": {"update": {"sessionUpdate": "compaction", "state": "done"}}});
    log.insert(at, rec(log[at].seq, "in", "compaction", done_update));
    let r = run(&log);
    assert_eq!(r.sessions[0].removals, 1);
    assert_eq!(r.sessions[0].violations.len(), 1, "{:#?}", r.sessions[0].violations);
}

#[test]
fn a_surgery_removes_only_what_is_past_its_keep_window() {
    // Keeping the last two turns: f2 and f3 stay, so reading them again is no refetch.
    let surgery = rec(
        0,
        "mux",
        "harness_surgery",
        json!({"applied": true, "keepTurns": 2, "minChars": 2048}),
    );
    let r = run(&reread_log(surgery.clone(), &[2, 3]));
    assert_eq!(r.violations, 0, "{:#?}", r.sessions[0].violations);
    assert_eq!(r.sessions[0].refetched, 0);
    let r = run(&reread_log(surgery, &[0, 1]));
    assert_eq!(r.sessions[0].refetched, 2);
}

#[test]
fn rereads_after_the_watch_ends_are_not_counted() {
    let mut log = reread_log(compact_boundary(), &[]);
    let mut seq = log.last().unwrap().seq;
    for _ in 0..=REFETCH_TURNS {
        seq += 1;
        log.push(turn(seq));
    }
    for i in 0..4 {
        seq += 1;
        log.push(tool(
            seq,
            &format!("late{i}"),
            "read",
            "Read",
            json!({"file_path": format!("/f{i}")}),
        ));
    }
    let r = run(&log);
    assert_eq!(r.violations, 0, "{:#?}", r.sessions[0].violations);
    assert_eq!(r.sessions[0].refetched, 0);
}

// The CI job: the checked-in fixture set, recorded chat logs scrubbed by
// `scripts/scorecard-replay-fixture.py`, replays clean through the store `--home` opens. The
// `cmux_next_` prefix puts it in the `cmux_next_ daemon tests` CI step.

#[test]
fn cmux_next_scorecard_replay_fixtures_hold_every_invariant() {
    let fixtures =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/scorecard-replay");
    // The store may write beside what it opens: a copy, never the checked-in tree.
    let home = tempfile::tempdir().unwrap();
    crate::lost_home_race_tests::copy_tree(&fixtures, home.path());
    let store = crate::store::open(&crate::config::StoreConfig::default(), home.path()).unwrap();
    let r = replay(&*store, &[]).unwrap();
    let names: Vec<&str> = r.sessions.iter().map(|s| s.session.as_str()).collect();
    assert_eq!(r.sessions.len(), 3, "{names:?} missing {:?}", r.missing);
    assert!(r.missing.is_empty(), "{:?}", r.missing);
    assert_eq!(
        r.violations,
        0,
        "{:#?}",
        r.sessions.iter().flat_map(|s| &s.violations).collect::<Vec<_>>()
    );
    assert!(r.not_yet.is_empty());
    // Each invariant had something to judge: calls (1, 5), inits (2), results (3) and a
    // compaction's watch (4).
    let sum = |f: fn(&SessionReplay) -> u64| r.sessions.iter().map(f).sum::<u64>();
    assert!(sum(|s| s.calls) >= 20, "calls {}", sum(|s| s.calls));
    assert!(sum(|s| s.inits) >= 3);
    assert!(sum(|s| s.tool_results) >= 30);
    assert!(sum(|s| s.removals) >= 2, "removals {}", sum(|s| s.removals));
    assert_eq!(r.counters["harnessMagic.scorecard.replaySessions"], 3);
}

/// A fixture with one seeded break of each kind fails exactly those invariants: the fixtures
/// are read the way the checks expect, so a clean pass above means something.
#[test]
fn cmux_next_scorecard_replay_fixture_with_seeded_breaks_fails() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/scorecard-replay/sessions/compacted-short/events/000001.ndjson");
    let mut log: Vec<EventRecord> = std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let last_seq = log.last().unwrap().seq;
    let at = log.last().unwrap().at;
    let mut extra = vec![
        // 3: a shell result over the cap.
        tool(last_seq + 1, "seeded", "execute", "Bash", json!({"command": "seeded"})),
        done(last_seq + 2, "seeded", SHELL_CAP_CHARS * 2),
        // 2: the tools change.
        init(last_seq + 3, "claude-opus-5-5", &["Seeded"]),
    ];
    for r in &mut extra {
        r.at = at + 1;
    }
    log.extend(extra);
    let r = run(&log);
    let mut hit: Vec<u8> = r.sessions[0].violations.iter().map(|v| v.invariant).collect();
    hit.dedup();
    assert_eq!(hit, vec![3, 2], "{:#?}", r.sessions[0].violations);
}
