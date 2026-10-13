//! `_acpmux/stats` (hq#1920): the fold over session logs.

use acpmux::stats::{StatsOptions, civil_date, summarize};
use acpmux::store::{EventRecord, MemoryStore, SessionMeta, Store};
use serde_json::{Value, json};

const MIN: u64 = 60_000;
const HOUR: u64 = 60 * MIN;
const DAY: u64 = 24 * HOUR;
/// 2026-10-12T00:00:00Z.
const DAY0: u64 = 1_791_763_200_000;

fn meta(id: &str, family: &str, status: &str, updated_at: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": "acpmux.session.v1",
        "id": id,
        "name": id,
        "harness": format!("{family}-acp"),
        "family": family,
        "cwd": "/tmp/project",
        "status": status,
        "createdAt": DAY0 - 30 * DAY,
        "updatedAt": updated_at,
    }))
    .unwrap()
}

struct Log<'a> {
    store: &'a MemoryStore,
    id: String,
    seq: u64,
}

impl Log<'_> {
    fn push(&mut self, at: u64, dir: &str, kind: &str, msg: Value) {
        self.seq += 1;
        let record = EventRecord {
            seq: self.seq,
            at,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        self.store.append(&self.id, &record).unwrap();
    }

    fn prompt(&mut self, at: u64) {
        self.push(
            at,
            "mux",
            "user_message",
            json!({"text": "secret prompt text", "promptId": "p"}),
        );
    }

    fn started(&mut self, at: u64) {
        self.push(at, "mux", "turn_started", json!({"turnId": "t"}));
    }

    /// The current log shape: turn_end (or turn_error), then turn_result.
    fn result(&mut self, at: u64, status: &str) {
        if status == "failed" {
            self.push(at, "mux", "turn_error", json!({"error": "boom"}));
        } else {
            let stop = if status == "cancelled" { "cancelled" } else { "end_turn" };
            self.push(at, "mux", "turn_end", json!({"stopReason": stop}));
        }
        self.push(at, "mux", "turn_result", json!({"status": status}));
    }

    fn status(&mut self, at: u64, status: &str) {
        self.push(at, "mux", "status", json!({"status": status}));
    }
}

fn session(store: &MemoryStore, meta: SessionMeta) -> Log<'_> {
    store.save(&meta).unwrap();
    Log { store, id: meta.id, seq: 0 }
}

fn options(until: u64, days: u64) -> StatsOptions {
    StatsOptions { since: until - days * DAY, until, tz_offset_minutes: 0 }
}

#[test]
fn turns_working_time_and_harnesses() {
    let store = MemoryStore::default();
    let mut claude = session(&store, meta("a", "claude", "ready", DAY0 + 12 * HOUR));
    claude.prompt(DAY0 + 9 * HOUR);
    // Queued for a minute: working time starts when the agent starts.
    claude.started(DAY0 + 9 * HOUR + MIN);
    claude.push(DAY0 + 9 * HOUR + 2 * MIN, "in", "tool_call", json!({}));
    claude.push(DAY0 + 9 * HOUR + 3 * MIN, "in", "tool_call", json!({}));
    claude.push(DAY0 + 9 * HOUR + 4 * MIN, "mux", "user_message", json!({"steer": true}));
    claude.result(DAY0 + 9 * HOUR + 31 * MIN, "completed");
    claude.prompt(DAY0 + 10 * HOUR);
    claude.started(DAY0 + 10 * HOUR);
    claude.result(DAY0 + 10 * HOUR + 10 * MIN, "cancelled");

    let mut codex = session(&store, meta("b", "codex", "ready", DAY0 + 12 * HOUR));
    codex.prompt(DAY0 + 11 * HOUR);
    codex.started(DAY0 + 11 * HOUR);
    codex.result(DAY0 + 11 * HOUR + 5 * MIN, "failed");

    let s = summarize(&store, &options(DAY0 + DAY - 1, 7)).unwrap();
    assert_eq!(s.sessions, 2);
    assert_eq!(s.turns, 3);
    assert_eq!((s.turns_completed, s.turns_cancelled, s.turns_failed), (1, 1, 1));
    assert_eq!((s.prompts, s.steers, s.tool_calls), (3, 1, 2));
    assert_eq!(s.working_ms, 30 * MIN + 10 * MIN + 5 * MIN);
    assert_eq!(s.harnesses[0].harness, "claude");
    assert_eq!(s.harnesses[0].working_ms, 40 * MIN);
    assert_eq!(s.harnesses[1].harness, "codex");
    assert_eq!(s.hours[9], 30 * MIN);
    assert_eq!(s.days.len(), 1);
    assert_eq!(s.days[0].day, "2026-10-12");
    assert_eq!(s.days[0].turns, 3);
    assert_eq!(s.peak_parallel, 1);
    // Counts and times only: no prompt text reaches the answer.
    assert!(!serde_json::to_string(&s).unwrap().contains("secret"));
}

#[test]
fn overlapping_turns_are_parallel_but_back_to_back_ones_are_not() {
    let store = MemoryStore::default();
    for (id, start, end) in [("a", 0, 60), ("b", 10, 50), ("c", 20, 30), ("d", 60, 90)] {
        let mut log = session(&store, meta(id, "claude", "ready", DAY0 + DAY / 2));
        log.prompt(DAY0 + start * MIN);
        log.started(DAY0 + start * MIN);
        log.result(DAY0 + end * MIN, "completed");
    }
    let s = summarize(&store, &options(DAY0 + DAY / 2, 1)).unwrap();
    assert_eq!(s.peak_parallel, 3);
    assert_eq!(s.peak_parallel_at, Some(DAY0 + 20 * MIN));
}

#[test]
fn waiting_on_a_permission_answer() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + HOUR));
    log.prompt(DAY0);
    log.status(DAY0, "running");
    log.push(DAY0 + MIN, "mux", "permission_request", json!({"permissionId": "x"}));
    log.status(DAY0 + MIN, "waiting");
    // A read receipt repeats the status: not a transition.
    log.push(DAY0 + 2 * MIN, "mux", "status", json!({"status": "waiting", "read": true}));
    log.status(DAY0 + 5 * MIN, "running");
    log.push(DAY0 + 6 * MIN, "mux", "permission_auto", json!({}));
    log.result(DAY0 + 10 * MIN, "completed");
    log.status(DAY0 + 10 * MIN, "ready");
    let s = summarize(&store, &options(DAY0 + HOUR, 1)).unwrap();
    assert_eq!(s.waiting_ms, 4 * MIN);
    assert_eq!((s.permission_requests, s.permission_auto), (1, 1));
}

#[test]
fn a_running_turn_counts_until_now_and_a_dead_one_is_dropped() {
    let store = MemoryStore::default();
    let mut live = session(&store, meta("live", "claude", "running", DAY0 + HOUR));
    live.prompt(DAY0 + HOUR - 20 * MIN);
    live.started(DAY0 + HOUR - 20 * MIN);
    let mut dead = session(&store, meta("dead", "claude", "idle", DAY0 + HOUR));
    dead.prompt(DAY0);
    dead.started(DAY0);
    let s = summarize(&store, &options(DAY0 + HOUR, 1)).unwrap();
    assert_eq!(s.working_ms, 20 * MIN);
    assert_eq!(s.sessions, 1);
    // A running turn has no outcome yet.
    assert_eq!(s.turns_completed + s.turns_cancelled + s.turns_failed, 0);
}

#[test]
fn ranges_clip_and_old_sessions_are_skipped() {
    let store = MemoryStore::default();
    let mut old = session(&store, meta("old", "claude", "ready", DAY0 - 30 * DAY));
    old.prompt(DAY0 - 30 * DAY);
    old.result(DAY0 - 30 * DAY + HOUR, "completed");
    // Started before the range, ended inside it: only the inside counts.
    let mut edge = session(&store, meta("edge", "codex", "ready", DAY0 + HOUR));
    edge.prompt(DAY0 - HOUR);
    edge.started(DAY0 - HOUR);
    edge.result(DAY0 + HOUR, "completed");
    let s =
        summarize(&store, &StatsOptions { since: DAY0, until: DAY0 + DAY, tz_offset_minutes: 0 })
            .unwrap();
    assert_eq!(s.sessions, 1);
    assert_eq!(s.working_ms, HOUR);
}

#[test]
fn days_hours_and_streaks_follow_the_callers_offset() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + 3 * DAY));
    // 23:30 UTC on three days running; at UTC-8 that is 15:30 the same day.
    for day in 0..3 {
        let at = DAY0 + day * DAY + 23 * HOUR + 30 * MIN;
        log.prompt(at);
        log.started(at);
        log.result(at + 10 * MIN, "completed");
    }
    let pacific =
        StatsOptions { since: DAY0 - DAY, until: DAY0 + 3 * DAY, tz_offset_minutes: -8 * 60 };
    let s = summarize(&store, &pacific).unwrap();
    assert_eq!(
        s.days.iter().map(|d| d.day.as_str()).collect::<Vec<_>>(),
        ["2026-10-12", "2026-10-13", "2026-10-14"]
    );
    assert_eq!(s.hours[15], 30 * MIN);
    assert_eq!((s.streak.current, s.streak.longest), (3, 3));
    // The same turns at UTC fall on the same three dates.
    let utc = StatsOptions { tz_offset_minutes: 0, ..pacific };
    let s = summarize(&store, &utc).unwrap();
    assert_eq!(s.days.first().map(|d| d.day.as_str()), Some("2026-10-12"));
}

#[test]
fn options_from_params_clamp() {
    let now = DAY0;
    let o = StatsOptions::from_params(&json!({}), now);
    assert_eq!(o.since, now - 84 * DAY);
    let o = StatsOptions::from_params(&json!({"days": 10_000, "tzOffsetMinutes": 99_999}), now);
    assert_eq!(o.since, now - 366 * DAY);
    assert_eq!(o.tz_offset_minutes, 14 * 60);
}

#[test]
fn civil_dates() {
    assert_eq!(civil_date(0), "1970-01-01");
    assert_eq!(civil_date((DAY0 / DAY) as i64), "2026-10-12");
    assert_eq!(civil_date(-1), "1969-12-31");
    assert_eq!(civil_date(11_016), "2000-02-29");
}
