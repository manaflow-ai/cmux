//! The waiting day over fixture transition logs (`hub/ledger/waiting_day.rs`).

use super::*;
use serde_json::json;

const MIN: u64 = 60_000;
/// A fixed day: 2026-11-08 00:00 UTC.
const DAY: u64 = 1_794_096_000_000;

fn rec(seq: u64, at: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

fn status(seq: u64, at: u64, s: &str) -> EventRecord {
    rec(seq, at, "status", json!({"status": s}))
}

/// Feeds `log` (a session's status and turn records) into a fresh day.
fn day_of(logs: &[(&str, Vec<EventRecord>)]) -> WaitingDay {
    let day = WaitingDay::open(None, DAY);
    for (id, log) in logs {
        for r in log {
            day.record(id, r);
        }
    }
    day
}

/// One chat: works 10 m, waits on the person 25 m, works 5 m, ready.
fn one_wait() -> Vec<EventRecord> {
    let t = DAY + 9 * 60 * MIN;
    vec![
        status(1, t, "running"),
        rec(2, t + 10, "turn_started", json!({"turnId": "turn-a"})),
        status(3, t + 10 * MIN, "waiting"),
        status(4, t + 35 * MIN, "running"),
        status(5, t + 40 * MIN, "ready"),
    ]
}

#[test]
fn a_permission_wait_is_a_blocked_stretch_that_opens_its_turn() {
    let day = day_of(&[("s1", one_wait())]);
    let reply = day.query(DAY, DAY + 24 * 60 * MIN);
    assert_eq!(reply.blocked_ms, 25 * MIN);
    assert_eq!(reply.working_ms, 15 * MIN);
    let lane = &reply.lanes[0];
    assert_eq!(lane.session_id, "s1");
    let states: Vec<_> = lane.spans.iter().map(|s| s.state).collect();
    assert_eq!(states, [State::Working, State::Blocked, State::Working]);
    let blocked = &lane.spans[1];
    assert_eq!(blocked.seq, 3);
    assert_eq!(blocked.turn_id.as_deref(), Some("turn-a"));
    // The first working mark came before turn_started and is named after it.
    assert_eq!(lane.spans[0].turn_id.as_deref(), Some("turn-a"));
}

#[test]
fn an_open_wait_runs_to_until_and_a_range_clips_it() {
    let t = DAY + 60 * MIN;
    let day = day_of(&[("s1", vec![status(1, t, "running"), status(2, t + 5 * MIN, "waiting")])]);
    let reply = day.query(t + 2 * MIN, t + 65 * MIN);
    assert_eq!(reply.working_ms, 3 * MIN);
    assert_eq!(reply.blocked_ms, 60 * MIN);
    assert_eq!(reply.lanes[0].spans[1].end, t + 65 * MIN);
}

#[test]
fn idle_chats_and_ranges_before_any_work_have_no_lane() {
    let day = day_of(&[("quiet", vec![status(1, DAY, "ready"), status(2, DAY + MIN, "idle")])]);
    assert!(day.query(DAY, DAY + 60 * MIN).lanes.is_empty());
    let day = day_of(&[("s1", one_wait())]);
    assert!(day.query(DAY, DAY + 60 * MIN).lanes.is_empty());
}

#[test]
fn lanes_sort_by_waiting_then_recency() {
    let t = DAY + 60 * MIN;
    let day = day_of(&[
        ("short", vec![status(1, t, "waiting"), status(2, t + MIN, "ready")]),
        ("long", vec![status(1, t, "waiting"), status(2, t + 9 * MIN, "ready")]),
        ("worker", vec![status(1, t + 20 * MIN, "running"), status(2, t + 30 * MIN, "ready")]),
    ]);
    let ids: Vec<_> =
        day.query(DAY, DAY + 24 * 60 * MIN).lanes.into_iter().map(|l| l.session_id).collect();
    assert_eq!(ids, ["long", "short", "worker"]);
}

#[test]
fn repeats_and_other_kinds_add_no_marks() {
    let t = DAY;
    let day = day_of(&[(
        "s1",
        vec![
            status(1, t, "running"),
            status(2, t + MIN, "running"),
            rec(3, t + 2 * MIN, "tool_call", json!({})),
            EventRecord { dir: "in".into(), ..status(4, t + 3 * MIN, "ready") },
            status(5, t + 4 * MIN, "unknown"),
            status(6, t + 5 * MIN, "closed"),
        ],
    )]);
    let reply = day.query(DAY, DAY + 60 * MIN);
    assert_eq!(reply.lanes[0].spans.len(), 1);
    assert_eq!(reply.working_ms, 5 * MIN);
}

#[test]
fn marks_are_bounded_per_chat_and_by_age() {
    let day = WaitingDay::open(None, DAY);
    let n = MAX_MARKS as u64 + 100;
    for i in 0..n {
        let s = if i % 2 == 0 { "running" } else { "ready" };
        day.record("s1", &status(i + 1, DAY + i * MIN, s));
    }
    assert_eq!(day.lock()["s1"].marks.len(), MAX_MARKS);
    // Two days later one new mark drops all the old ones but the last before the cut.
    day.record("s1", &status(n + 1, DAY + RETAIN_MS + n * MIN, "running"));
    assert_eq!(day.lock()["s1"].marks.len(), 2);
}

#[test]
fn chats_are_bounded_and_the_quietest_goes() {
    let day = WaitingDay::open(None, DAY);
    for i in 0..MAX_LANES as u64 {
        day.record(&format!("s{i}"), &status(1, DAY + i, "running"));
    }
    day.record("new", &status(1, DAY + MAX_LANES as u64, "running"));
    let lanes = day.lock();
    assert_eq!(lanes.len(), MAX_LANES);
    assert!(!lanes.contains_key("s0"));
    assert!(lanes.contains_key("new"));
}

#[test]
fn forget_drops_a_deleted_chat() {
    let day = day_of(&[("s1", one_wait())]);
    day.forget("s1");
    assert!(day.query(DAY, DAY + 24 * 60 * MIN).lanes.is_empty());
}

#[test]
fn a_saved_day_reopens_with_its_open_stretches_ended_at_the_save() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    let t = DAY + 60 * MIN;
    let day = WaitingDay::open(Some(path.clone()), t);
    day.record("s1", &status(1, t, "waiting"));
    day.save(t + 7 * MIN);
    let again = WaitingDay::open(Some(path), t + 30 * MIN);
    let reply = again.query(DAY, t + 30 * MIN);
    assert_eq!(reply.blocked_ms, 7 * MIN);
    assert_eq!(reply.lanes[0].spans[0].end, t + 7 * MIN);
}

#[test]
fn a_deleted_chat_is_not_read_back_after_a_crash() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    let t = DAY + 60 * MIN;
    let day = WaitingDay::open(Some(path.clone()), t);
    day.record("s1", &status(1, t, "waiting"));
    day.save(t + 7 * MIN);
    let again = WaitingDay::open(Some(path.clone()), t + 30 * MIN);
    again.forget("s1");
    // No save: the daemon crashed.
    let after = WaitingDay::open(Some(path), t + 40 * MIN);
    assert!(after.query(DAY, t + 40 * MIN).lanes.is_empty());
}

#[test]
fn a_missing_or_garbled_file_opens_empty() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    assert!(WaitingDay::open(Some(path.clone()), DAY).lock().is_empty());
    std::fs::write(&path, b"{not json").unwrap();
    assert!(WaitingDay::open(Some(path), DAY).lock().is_empty());
}

#[test]
fn the_range_defaults_to_a_day_and_reaches_back_two_at_most() {
    let now = DAY + 12 * 60 * MIN;
    assert_eq!(range(&json!({}), now), (now - 24 * 60 * MIN, now));
    assert_eq!(range(&json!({"since": DAY}), now), (DAY, now));
    assert_eq!(range(&json!({"since": 0}), now), (now - RETAIN_MS, now));
    assert_eq!(range(&json!({"until": now + 1000}), now).1, now);
    assert_eq!(range(&json!({"since": now + 5, "until": now}), now), (now, now));
}

/// Fifty chats, a full day of turns each: one query stays a walk over the kept marks.
#[test]
fn fifty_chats_answer_in_one_pass() {
    let day = WaitingDay::open(None, DAY);
    for c in 0..50 {
        let id = format!("chat-{c}");
        for i in 0..200u64 {
            let s = ["running", "waiting", "running", "ready"][(i % 4) as usize];
            day.record(&id, &status(i + 1, DAY + i * 5 * MIN + c, s));
        }
    }
    let reply = day.query(DAY, DAY + 24 * 60 * MIN);
    assert_eq!(reply.lanes.len(), 50);
    assert!(reply.lanes.iter().all(|l| l.spans.len() <= MAX_MARKS));
    assert!(reply.blocked_ms > 0);
}

/// The turn record comes before the chat's first `running` status (`turns.rs`): the first wait
/// still opens its turn.
#[test]
fn a_new_chats_first_wait_carries_its_turn() {
    let t = DAY + 60 * MIN;
    let day = day_of(&[(
        "new",
        vec![
            rec(1, t, "turn_started", json!({"turnId": "turn-1"})),
            status(2, t + 1, "running"),
            status(3, t + MIN, "waiting"),
            status(4, t + 2 * MIN, "ready"),
        ],
    )]);
    let reply = day.query(DAY, t + 60 * MIN);
    let spans = &reply.lanes[0].spans;
    assert_eq!(spans[0].turn_id.as_deref(), Some("turn-1"));
    assert_eq!(spans[1].state, State::Blocked);
    assert_eq!(spans[1].turn_id.as_deref(), Some("turn-1"));
}

#[test]
fn a_reply_carries_at_most_its_lane_cap_and_counts_every_chat() {
    let day = WaitingDay::open(None, DAY);
    let n = MAX_REPLY_LANES as u64 + 20;
    for i in 0..n {
        let id = format!("s{i}");
        day.record(&id, &status(1, DAY + i, "waiting"));
        day.record(&id, &status(2, DAY + i + MIN, "ready"));
    }
    let reply = day.query(DAY, DAY + 60 * MIN);
    assert_eq!(reply.lanes.len(), MAX_REPLY_LANES);
    assert_eq!(reply.blocked_ms, n * MIN);
}
