//! `_acpmux/stats` (hq#1920): the fold over session logs.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::Config;
use acpmux::hub::Hub;
use acpmux::stats::{StatsOptions, civil_date, summarize};
use acpmux::store::{EventRecord, MemoryStore, SessionMeta, Store};
use serde_json::{Value, json};
use std::collections::HashSet;

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

    /// A turn from prompt to result, with the spend its `turn_result`
    /// recorded (`hub/turn_usage.rs`).
    fn turn(&mut self, start: u64, end: u64, usage: Value) {
        self.prompt(start);
        self.started(start);
        self.push(end, "mux", "turn_end", json!({"stopReason": "end_turn"}));
        let mut result = json!({"status": "completed"});
        if let (Some(result), Value::Object(usage)) = (result.as_object_mut(), usage) {
            result.extend(usage);
        }
        self.push(end, "mux", "turn_result", result);
    }

    fn status(&mut self, at: u64, status: &str) {
        self.push(at, "mux", "status", json!({"status": status}));
    }
}

/// A session started on `branch` in `cwd` (`git_state.rs`).
fn on_branch(id: &str, branch: Option<&str>, cwd: &str, updated_at: u64) -> SessionMeta {
    let mut meta = meta(id, "claude", "ready", updated_at);
    meta.git_branch = branch.map(str::to_owned);
    meta.cwd = cwd.into();
    meta
}

fn session(store: &MemoryStore, meta: SessionMeta) -> Log<'_> {
    store.save(&meta).unwrap();
    Log { store, id: meta.id, seq: 0 }
}

/// The sessions this daemon holds running or waiting now.
fn live_ids(ids: &[&str]) -> HashSet<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

fn options(until: u64, days: u64) -> StatsOptions {
    StatsOptions { since: until - days * DAY, until, tz_offset_minutes: 0 }
}

#[test]
fn stats_turns_working_time_and_harnesses() {
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

    let s = summarize(&store, &options(DAY0 + DAY - 1, 7), &live_ids(&[])).unwrap();
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
fn stats_overlapping_turns_are_parallel_but_back_to_back_ones_are_not() {
    let store = MemoryStore::default();
    for (id, start, end) in [("a", 0, 60), ("b", 10, 50), ("c", 20, 30), ("d", 60, 90)] {
        let mut log = session(&store, meta(id, "claude", "ready", DAY0 + DAY / 2));
        log.prompt(DAY0 + start * MIN);
        log.started(DAY0 + start * MIN);
        log.result(DAY0 + end * MIN, "completed");
    }
    let s = summarize(&store, &options(DAY0 + DAY / 2, 1), &live_ids(&[])).unwrap();
    assert_eq!(s.peak_parallel, 3);
    assert_eq!(s.peak_parallel_at, Some(DAY0 + 20 * MIN));
}

#[test]
fn stats_waiting_on_a_permission_answer() {
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
    let s = summarize(&store, &options(DAY0 + HOUR, 1), &live_ids(&[])).unwrap();
    assert_eq!(s.waiting_ms, 4 * MIN);
    assert_eq!((s.permission_requests, s.permission_auto), (1, 1));
}

#[test]
fn stats_a_running_turn_counts_until_now_and_a_dead_one_is_dropped() {
    let store = MemoryStore::default();
    let mut live = session(&store, meta("live", "claude", "running", DAY0 + HOUR));
    live.prompt(DAY0 + HOUR - 20 * MIN);
    live.started(DAY0 + HOUR - 20 * MIN);
    let mut dead = session(&store, meta("dead", "claude", "idle", DAY0 + HOUR));
    dead.prompt(DAY0);
    dead.started(DAY0);
    let s = summarize(&store, &options(DAY0 + HOUR, 1), &live_ids(&["live"])).unwrap();
    assert_eq!(s.working_ms, 20 * MIN);
    assert_eq!(s.sessions, 1);
    // A running turn has no outcome yet.
    assert_eq!(s.turns_completed + s.turns_cancelled + s.turns_failed, 0);
}

#[test]
fn stats_ranges_clip_and_old_sessions_are_skipped() {
    let store = MemoryStore::default();
    let mut old = session(&store, meta("old", "claude", "ready", DAY0 - 30 * DAY));
    old.prompt(DAY0 - 30 * DAY);
    old.result(DAY0 - 30 * DAY + HOUR, "completed");
    // Started before the range, ended inside it: only the inside counts.
    let mut edge = session(&store, meta("edge", "codex", "ready", DAY0 + HOUR));
    edge.prompt(DAY0 - HOUR);
    edge.started(DAY0 - HOUR);
    edge.result(DAY0 + HOUR, "completed");
    let s = summarize(
        &store,
        &StatsOptions { since: DAY0, until: DAY0 + DAY, tz_offset_minutes: 0 },
        &live_ids(&[]),
    )
    .unwrap();
    assert_eq!(s.sessions, 1);
    assert_eq!(s.working_ms, HOUR);
}

#[test]
fn stats_days_hours_and_streaks_follow_the_callers_offset() {
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
    let s = summarize(&store, &pacific, &live_ids(&[])).unwrap();
    assert_eq!(
        s.days.iter().map(|d| d.day.as_str()).collect::<Vec<_>>(),
        ["2026-10-12", "2026-10-13", "2026-10-14"]
    );
    assert_eq!(s.hours[15], 30 * MIN);
    assert_eq!((s.streak.current, s.streak.longest), (3, 3));
    // The same turns at UTC fall on the same three dates.
    let utc = StatsOptions { tz_offset_minutes: 0, ..pacific };
    let s = summarize(&store, &utc, &live_ids(&[])).unwrap();
    assert_eq!(s.days.first().map(|d| d.day.as_str()), Some("2026-10-12"));
}

#[test]
fn stats_options_from_params_clamp() {
    let now = DAY0;
    let o = StatsOptions::from_params(&json!({}), now);
    assert_eq!(o.since, now - 84 * DAY);
    let o = StatsOptions::from_params(&json!({"days": 10_000, "tzOffsetMinutes": 99_999}), now);
    assert_eq!(o.since, now - 366 * DAY);
    assert_eq!(o.tz_offset_minutes, 14 * 60);
}

#[test]
fn stats_civil_dates() {
    assert_eq!(civil_date(0), "1970-01-01");
    assert_eq!(civil_date((DAY0 / DAY) as i64), "2026-10-12");
    assert_eq!(civil_date(-1), "1969-12-31");
    assert_eq!(civil_date(11_016), "2000-02-29");
}

#[test]
fn stats_a_turn_cut_by_a_restart_ends_at_its_last_record() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "idle", DAY0 + DAY));
    log.prompt(DAY0 + 18 * HOUR);
    log.started(DAY0 + 18 * HOUR);
    log.push(DAY0 + 18 * HOUR + 10 * MIN, "in", "tool_call", json!({}));
    log.status(DAY0 + 18 * HOUR + 10 * MIN, "waiting");
    // The daemon died; its next start, the morning after, marks the turn.
    log.push(
        DAY0 + DAY + 9 * HOUR,
        "mux",
        "turn_result",
        json!({"status": "failed", "detail": "outcome_unknown"}),
    );
    let s = summarize(&store, &options(DAY0 + 2 * DAY, 7), &live_ids(&[])).unwrap();
    assert_eq!(s.working_ms, 10 * MIN);
    assert_eq!(s.waiting_ms, 0);
    assert_eq!(s.turns_failed, 1);
    assert_eq!(s.hours[2], 0, "nothing counted overnight");
}

#[test]
fn stats_a_prompt_after_a_dead_turn_ends_it_at_its_last_record() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + 3 * DAY));
    log.prompt(DAY0);
    log.started(DAY0);
    log.push(DAY0 + 5 * MIN, "in", "tool_call", json!({}));
    log.status(DAY0 + 5 * MIN, "waiting");
    // No turn end and no restart record: the next prompt is two days later.
    log.prompt(DAY0 + 2 * DAY);
    log.started(DAY0 + 2 * DAY);
    log.result(DAY0 + 2 * DAY + MIN, "completed");
    log.status(DAY0 + 2 * DAY + MIN, "ready");
    let s = summarize(&store, &options(DAY0 + 3 * DAY, 7), &live_ids(&[])).unwrap();
    assert_eq!(s.working_ms, 5 * MIN + MIN);
    assert_eq!(s.waiting_ms, 0);
}

#[test]
fn stats_an_unreadable_log_is_skipped() {
    struct Torn(MemoryStore);
    impl Store for Torn {
        fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
            self.0.list()
        }
        fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
            self.0.load(id)
        }
        fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
            self.0.save(meta)
        }
        fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
            self.0.append(id, record)
        }
        fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
            if id == "torn" {
                anyhow::bail!("stream did not contain valid UTF-8");
            }
            self.0.events(id, after, limit)
        }
        fn delete(&self, id: &str) -> anyhow::Result<()> {
            self.0.delete(id)
        }
    }
    let store = Torn(MemoryStore::default());
    for id in ["good", "torn"] {
        let mut log = session(&store.0, meta(id, "claude", "ready", DAY0 + HOUR));
        log.prompt(DAY0);
        log.started(DAY0);
        log.result(DAY0 + 10 * MIN, "completed");
    }
    let s = summarize(&store, &options(DAY0 + HOUR, 1), &live_ids(&[])).unwrap();
    assert_eq!((s.sessions, s.working_ms), (1, 10 * MIN));
}

#[test]
fn stats_the_streak_does_not_depend_on_the_range() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + 20 * DAY));
    for day in 0..=20 {
        let at = DAY0 + day * DAY + 12 * HOUR;
        log.prompt(at);
        log.started(at);
        log.result(at + MIN, "completed");
    }
    let until = DAY0 + 20 * DAY + 13 * HOUR;
    let week = summarize(&store, &options(until, 7), &live_ids(&[])).unwrap();
    assert_eq!((week.streak.current, week.streak.longest), (21, 21));
    assert_eq!(week.days.len(), 7);
}

#[test]
fn stats_a_wait_the_daemon_lost_ends_at_its_last_record() {
    let store = MemoryStore::default();
    // session.json still says waiting: a restarted daemon resets it in memory.
    let mut log = session(&store, meta("a", "claude", "waiting", DAY0 + 10 * MIN));
    log.prompt(DAY0);
    log.started(DAY0);
    log.result(DAY0 + 10 * MIN, "completed");
    // A subagent still asking keeps the chat waiting after its turn.
    log.status(DAY0 + 10 * MIN, "waiting");
    let s = summarize(&store, &options(DAY0 + 5 * HOUR, 1), &live_ids(&[])).unwrap();
    assert_eq!(s.waiting_ms, 0);
    // The same log in a daemon that holds the wait: it runs to now.
    let s = summarize(&store, &options(DAY0 + 5 * HOUR, 1), &live_ids(&["a"])).unwrap();
    assert_eq!(s.waiting_ms, 5 * HOUR - 10 * MIN);
}

#[test]
fn stats_a_status_after_a_restart_does_not_extend_the_lost_wait() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + DAY + 9 * HOUR));
    log.prompt(DAY0);
    log.started(DAY0);
    log.result(DAY0 + 10 * MIN, "completed");
    log.status(DAY0 + 10 * MIN, "waiting");
    // The daemon died; its next start marks the wait it lost, and the agent
    // respawns hours later.
    log.push(DAY0 + DAY, "mux", "status", json!({"status": "idle", "detail": "restart"}));
    log.status(DAY0 + DAY + 9 * HOUR, "ready");
    let s = summarize(&store, &options(DAY0 + 2 * DAY, 7), &live_ids(&[])).unwrap();
    assert_eq!(s.waiting_ms, 0);
    assert_eq!(s.working_ms, 10 * MIN);
}

#[test]
fn stats_a_prompt_the_daemon_lost_before_its_turn_started_is_not_running() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "running", DAY0));
    log.prompt(DAY0);
    let s = summarize(&store, &options(DAY0 + HOUR, 1), &live_ids(&[])).unwrap();
    assert_eq!((s.prompts, s.turns, s.sessions, s.working_ms), (1, 0, 0, 0));
}

#[test]
fn stats_a_prompt_ends_a_wait_after_the_turn_at_its_own_time() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + 4 * HOUR));
    log.prompt(DAY0);
    log.started(DAY0);
    log.result(DAY0 + 10 * MIN, "completed");
    log.status(DAY0 + 10 * MIN, "waiting");
    // Nothing logged for three hours, then the person's next prompt.
    let next = DAY0 + 10 * MIN + 3 * HOUR;
    log.prompt(next);
    log.status(next, "running");
    log.started(next);
    log.result(next + 10 * MIN, "completed");
    log.status(next + 10 * MIN, "ready");
    let s = summarize(&store, &options(DAY0 + 4 * HOUR, 1), &live_ids(&[])).unwrap();
    assert_eq!(s.waiting_ms, 3 * HOUR);
}

#[test]
fn stats_a_steer_sent_again_as_a_prompt_counts_once() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + HOUR));
    log.prompt(DAY0);
    log.started(DAY0);
    log.result(DAY0 + MIN, "completed");
    // The steer found the turn over (`STEER_NO_TURN`): the same message,
    // under the same id, runs as the next prompt.
    log.push(DAY0 + 2 * MIN, "mux", "user_message", json!({"steer": true, "promptId": "s"}));
    log.push(DAY0 + 2 * MIN, "mux", "user_message", json!({"promptId": "s"}));
    log.started(DAY0 + 2 * MIN);
    log.result(DAY0 + 3 * MIN, "completed");
    let s = summarize(&store, &options(DAY0 + HOUR, 1), &live_ids(&[])).unwrap();
    assert_eq!((s.prompts, s.steers), (2, 0));
    assert_eq!(s.turns_completed, 2);
}

#[test]
fn stats_a_prompt_that_never_started_is_not_a_finished_turn() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + 3 * DAY));
    // Lost before its turn started; the next prompt runs two days later.
    log.prompt(DAY0 + 12 * HOUR);
    let next = DAY0 + 2 * DAY + 12 * HOUR;
    log.prompt(next);
    log.started(next);
    log.result(next + MIN, "completed");
    let s = summarize(&store, &options(DAY0 + 3 * DAY, 7), &live_ids(&[])).unwrap();
    assert_eq!((s.prompts, s.turns, s.turns_completed), (2, 1, 1));
    assert_eq!(s.working_ms, MIN);
    assert_eq!(s.days.len(), 1);
    assert_eq!(s.streak.longest, 1);
}

/// A session waiting when the daemon died (a subagent still asking after its
/// turn) gets a restart status record, so the log and session.json stop
/// saying `waiting` and the stats end the wait at its last record.
#[tokio::test]
async fn restart_ends_a_lost_wait_for_stats() {
    let store = MemoryStore::default();
    session(&store, meta("w", "claude", "waiting", DAY0)).status(DAY0, "waiting");
    let hub = Hub::new(Config::default(), Box::new(store));
    let events = hub.events("w", 0, 100).unwrap();
    let last = events.last().unwrap();
    assert_eq!(last.kind, "status", "{events:?}");
    assert_eq!(last.msg, json!({"status": "idle", "detail": "restart"}));
    let range = options(acpmux::store::now_ms(), 366);
    assert_eq!(hub.stats(&range).unwrap().waiting_ms, 0);
}

#[test]
fn stats_permission_wait_runs_from_request_to_decision() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + HOUR));
    log.prompt(DAY0);
    log.started(DAY0);
    log.push(DAY0 + MIN, "mux", "permission_request", json!({"permissionId": "x"}));
    log.push(DAY0 + 5 * MIN, "mux", "permission_decision", json!({"permissionId": "x"}));
    log.push(DAY0 + 6 * MIN, "mux", "permission_request", json!({"permissionId": "y"}));
    // A rule's answer is no wait on the person.
    log.push(DAY0 + 6 * MIN, "mux", "permission_auto", json!({"permissionId": "r"}));
    log.push(DAY0 + 7 * MIN, "mux", "permission_decision", json!({"permissionId": "y"}));
    // Asked, and the daemon died before anyone answered: no decision.
    log.push(DAY0 + 8 * MIN, "mux", "permission_request", json!({"permissionId": "z"}));
    let s = summarize(&store, &options(DAY0 + HOUR, 1), &live_ids(&[])).unwrap();
    assert_eq!(s.permission_requests, 3);
    assert_eq!((s.permission_answered, s.permission_unanswered), (2, 1));
    assert_eq!(s.permission_wait_ms, 4 * MIN + MIN);
    assert_eq!(s.permission_wait_max_ms, 4 * MIN);
}

#[test]
fn stats_permission_wait_counts_questions_asked_in_the_range() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + 2 * HOUR));
    // Asked before the range, answered inside it: not this range's question.
    log.push(DAY0 - 10 * MIN, "mux", "permission_request", json!({"permissionId": "old"}));
    log.push(DAY0 + MIN, "mux", "permission_decision", json!({"permissionId": "old"}));
    // Asked by a daemon that died, shown again under the same id by the
    // next one, answered then: one question, one wait.
    log.push(DAY0 + 10 * MIN, "mux", "permission_request", json!({"permissionId": "p"}));
    log.push(DAY0 + 30 * MIN, "mux", "permission_reissued", json!({"permissionId": "p"}));
    log.push(DAY0 + 32 * MIN, "mux", "permission_decision", json!({"permissionId": "p"}));
    // A decision for a question this log never asked.
    log.push(DAY0 + 40 * MIN, "mux", "permission_decision", json!({"permissionId": "ghost"}));
    // Answered after the range ends: still open as of the range.
    log.push(DAY0 + 50 * MIN, "mux", "permission_request", json!({"permissionId": "late"}));
    log.push(DAY0 + 2 * HOUR, "mux", "permission_decision", json!({"permissionId": "late"}));
    let range = StatsOptions { since: DAY0, until: DAY0 + HOUR, tz_offset_minutes: 0 };
    let s = summarize(&store, &range, &live_ids(&[])).unwrap();
    assert_eq!(s.permission_requests, 2);
    assert_eq!((s.permission_answered, s.permission_unanswered), (1, 1));
    assert_eq!((s.permission_wait_ms, s.permission_wait_max_ms), (22 * MIN, 22 * MIN));
}

#[test]
fn stats_limit_errors_count_failed_turns_and_failovers_on_a_limit() {
    let store = MemoryStore::default();
    let mut log = session(&store, meta("a", "claude", "ready", DAY0 + 2 * HOUR));
    fn error(at: u64, log: &mut Log<'_>, text: &str) {
        log.prompt(at);
        log.started(at);
        log.push(at + MIN, "mux", "turn_error", json!({"error": text}));
        log.push(at + MIN, "mux", "turn_result", json!({"status": "failed", "error": text}));
    }
    // Before the range.
    error(DAY0 - HOUR, &mut log, "You've reached your usage limit");
    error(DAY0, &mut log, "You've reached your usage limit");
    error(DAY0 + 10 * MIN, &mut log, "boom");
    // A failover carried this turn on: the account still hit its limit.
    log.prompt(DAY0 + 20 * MIN);
    log.started(DAY0 + 20 * MIN);
    log.push(
        DAY0 + 21 * MIN,
        "mux",
        "failover",
        json!({"from": "claude", "to": "claude-pool", "reason": "429 rate limit"}),
    );
    // A pool launcher that died fails over too, but is not a limit.
    log.push(
        DAY0 + 22 * MIN,
        "mux",
        "failover",
        json!({"from": "claude-pool", "to": "claude", "reason": "agent process closed"}),
    );
    log.result(DAY0 + 25 * MIN, "completed");
    let range = StatsOptions { since: DAY0, until: DAY0 + HOUR, tz_offset_minutes: 0 };
    let s = summarize(&store, &range, &live_ids(&[])).unwrap();
    assert_eq!(s.turns_failed, 2);
    assert_eq!(s.limit_errors, 2);
}

#[test]
fn stats_branches_roll_up_turns_time_and_spend_in_range() {
    let store = MemoryStore::default();
    let updated = DAY0 + 12 * HOUR;
    let mut a = session(&store, on_branch("a", Some("feat-x"), "/tmp/project", updated));
    // Before the range: neither its time nor its spend counts.
    a.turn(
        DAY0 - 2 * HOUR,
        DAY0 - HOUR,
        json!({"costUsd": 100.0, "inputTokens": 9_000, "outputTokens": 900}),
    );
    a.turn(
        DAY0 + HOUR,
        DAY0 + HOUR + 30 * MIN,
        json!({"model": "opus", "costUsd": 0.5, "inputTokens": 100, "outputTokens": 10}),
    );
    // Tokens without a cost.
    let mut b = session(&store, on_branch("b", Some("feat-x"), "/tmp/project", updated));
    b.turn(
        DAY0 + 2 * HOUR,
        DAY0 + 2 * HOUR + 20 * MIN,
        json!({"inputTokens": 50, "outputTokens": 5}),
    );
    let mut c = session(&store, on_branch("c", Some("main"), "/tmp/project", updated));
    c.turn(
        DAY0 + 3 * HOUR,
        DAY0 + 3 * HOUR + 10 * MIN,
        json!({"costUsd": 0.25, "inputTokens": 10, "outputTokens": 1}),
    );
    // No branch (a detached HEAD, no repository, or an older session).
    let mut d = session(&store, on_branch("d", None, "/tmp/project", updated));
    d.turn(DAY0 + 4 * HOUR, DAY0 + 4 * HOUR + 40 * MIN, json!({"costUsd": 2.0}));
    // The same branch name in another checkout is another row; a harness
    // that reports no spend leaves the spend fields out.
    let mut e = session(&store, on_branch("e", Some("feat-x"), "/tmp/other", updated));
    e.turn(DAY0 + 5 * HOUR, DAY0 + 5 * HOUR + 5 * MIN, json!({"model": "gpt"}));

    let s = summarize(&store, &options(DAY0 + DAY, 1), &live_ids(&[])).unwrap();
    assert_eq!(s.working_ms, 105 * MIN);
    let v = serde_json::to_value(&s).unwrap();
    assert_eq!(
        v["branches"],
        json!([
            {"cwd": "/tmp/project", "branch": "feat-x", "sessions": 2, "turns": 2,
             "workingMs": 50 * MIN, "costUsd": 0.5, "inputTokens": 150, "outputTokens": 15},
            {"cwd": "/tmp/project", "branch": "main", "sessions": 1, "turns": 1,
             "workingMs": 10 * MIN, "costUsd": 0.25, "inputTokens": 10, "outputTokens": 1},
            {"cwd": "/tmp/other", "branch": "feat-x", "sessions": 1, "turns": 1,
             "workingMs": 5 * MIN},
        ])
    );
}

#[test]
fn stats_branches_follow_the_branch_each_turn_ended_on() {
    let store = MemoryStore::default();
    let updated = DAY0 + 12 * HOUR;
    // Started on main; the agent switched to feat-y before its second turn ended.
    let mut a = session(&store, on_branch("a", Some("main"), "/tmp/p", updated));
    a.turn(DAY0 + HOUR, DAY0 + HOUR + 10 * MIN, json!({"gitBranch": "main", "costUsd": 0.25}));
    a.turn(
        DAY0 + 2 * HOUR,
        DAY0 + 2 * HOUR + 30 * MIN,
        json!({"gitBranch": "feat-y", "gitHead": "0123456789abcdef0123456789abcdef01234567",
               "costUsd": 0.5}),
    );
    a.turn(DAY0 + 3 * HOUR, DAY0 + 3 * HOUR + 20 * MIN, json!({"gitBranch": "feat-y"}));
    // An older log's turns carry no branch: they stay on the start branch.
    let mut old = session(&store, on_branch("old", Some("main"), "/tmp/p", updated));
    old.turn(DAY0 + 4 * HOUR, DAY0 + 4 * HOUR + 5 * MIN, json!({"costUsd": 1.0}));
    // Started with no branch (a detached HEAD), its turn ended on one.
    let mut d = session(&store, on_branch("d", None, "/tmp/p", updated));
    d.turn(DAY0 + 5 * HOUR, DAY0 + 5 * HOUR + 15 * MIN, json!({"gitBranch": "feat-y"}));

    let s = summarize(&store, &options(DAY0 + DAY, 1), &live_ids(&[])).unwrap();
    assert_eq!((s.sessions, s.turns, s.working_ms), (3, 5, 80 * MIN));
    let v = serde_json::to_value(&s).unwrap();
    assert_eq!(
        v["branches"],
        json!([
            {"cwd": "/tmp/p", "branch": "feat-y", "sessions": 2, "turns": 3,
             "workingMs": 65 * MIN, "costUsd": 0.5},
            {"cwd": "/tmp/p", "branch": "main", "sessions": 2, "turns": 2,
             "workingMs": 15 * MIN, "costUsd": 1.25},
        ])
    );
}

#[test]
fn stats_branches_count_a_forks_copied_turns_once() {
    let store = MemoryStore::default();
    let updated = DAY0 + 12 * HOUR;
    let spend = json!({"costUsd": 0.5, "inputTokens": 100, "outputTokens": 10});
    let mut parent = session(&store, on_branch("parent", Some("feat-x"), "/tmp/p", updated));
    parent.turn(DAY0 + HOUR, DAY0 + HOUR + 30 * MIN, spend.clone());
    // A fork's log starts with copies of its parent's turns, at their times.
    let mut fork = session(&store, on_branch("fork", Some("feat-x"), "/tmp/p", updated));
    fork.turn(DAY0 + HOUR, DAY0 + HOUR + 30 * MIN, spend);
    fork.push(DAY0 + 6 * HOUR, "mux", "forked", json!({"parentId": "parent", "forkSeq": 4}));
    fork.turn(DAY0 + 6 * HOUR, DAY0 + 6 * HOUR + 15 * MIN, json!({"costUsd": 0.125}));
    // A fork with nothing of its own is no session of the branch.
    let mut idle = session(&store, on_branch("idle", Some("feat-x"), "/tmp/p", updated));
    idle.turn(DAY0 + HOUR, DAY0 + HOUR + 30 * MIN, json!({"costUsd": 0.5}));
    idle.push(DAY0 + 7 * HOUR, "mux", "forked", json!({"parentId": "parent", "forkSeq": 4}));

    let s = summarize(&store, &options(DAY0 + DAY, 1), &live_ids(&[])).unwrap();
    let v = serde_json::to_value(&s).unwrap();
    assert_eq!(
        v["branches"],
        json!([{"cwd": "/tmp/p", "branch": "feat-x", "sessions": 2, "turns": 2,
                "workingMs": 45 * MIN, "costUsd": 0.625, "inputTokens": 100, "outputTokens": 10}])
    );
}

#[test]
fn stats_branches_keep_the_fifty_with_the_most_working_time() {
    let store = MemoryStore::default();
    for n in 1..=55u64 {
        let id = format!("s{n}");
        let branch = format!("b{n}");
        let mut log = session(&store, on_branch(&id, Some(&branch), "/tmp/p", DAY0 + DAY));
        log.turn(DAY0 + HOUR, DAY0 + HOUR + n * MIN, json!({}));
    }
    let s = summarize(&store, &options(DAY0 + DAY, 1), &live_ids(&[])).unwrap();
    let v = serde_json::to_value(&s).unwrap();
    let names: Vec<&str> =
        v["branches"].as_array().unwrap().iter().map(|b| b["branch"].as_str().unwrap()).collect();
    assert_eq!(names.len(), 50);
    assert_eq!((names[0], names[49]), ("b55", "b6"));
}

#[test]
fn stats_branches_skip_a_turn_a_fork_copied_while_it_ran() {
    let store = MemoryStore::default();
    let updated = DAY0 + 12 * HOUR;
    // Forked mid-turn: the copied prompt and start have no result before
    // `forked`, and the fork's own prompt closes that copy.
    let mut fork = session(&store, on_branch("fork", Some("feat-x"), "/tmp/p", updated));
    fork.prompt(DAY0 + HOUR);
    fork.started(DAY0 + HOUR);
    fork.push(DAY0 + 2 * HOUR, "mux", "forked", json!({"parentId": "parent", "forkSeq": 2}));
    fork.turn(DAY0 + 3 * HOUR, DAY0 + 3 * HOUR + 10 * MIN, json!({"costUsd": 0.25}));
    let s = summarize(&store, &options(DAY0 + DAY, 1), &live_ids(&[])).unwrap();
    let v = serde_json::to_value(&s).unwrap();
    assert_eq!(
        v["branches"],
        json!([{"cwd": "/tmp/p", "branch": "feat-x", "sessions": 1, "turns": 1,
                "workingMs": 10 * MIN, "costUsd": 0.25}])
    );
}

#[test]
fn stats_totals_count_a_forks_copied_turns_once() {
    let store = MemoryStore::default();
    let updated = DAY0 + 12 * HOUR;
    let mut parent = session(&store, meta("parent", "claude", "ready", updated));
    let mut fork = session(&store, meta("fork", "claude", "ready", updated));
    // A fork's log starts with copies of its parent's prompts, tool calls
    // and turns, at their times, then its `forked` record.
    for log in [&mut parent, &mut fork] {
        log.turn(DAY0 + HOUR, DAY0 + HOUR + 30 * MIN, json!({}));
        log.push(DAY0 + HOUR + MIN, "in", "tool_call", json!({}));
        log.turn(DAY0 + 2 * HOUR, DAY0 + 2 * HOUR + 20 * MIN, json!({}));
    }
    fork.push(DAY0 + 5 * HOUR, "mux", "forked", json!({"parentId": "parent", "forkSeq": 9}));
    fork.turn(DAY0 + 6 * HOUR, DAY0 + 6 * HOUR + 15 * MIN, json!({}));

    let s = summarize(&store, &options(DAY0 + DAY, 1), &live_ids(&[])).unwrap();
    assert_eq!(s.sessions, 2);
    assert_eq!((s.turns, s.turns_completed), (3, 3));
    assert_eq!((s.prompts, s.steers, s.tool_calls), (3, 0, 1));
    assert_eq!(s.working_ms, 65 * MIN);
    assert_eq!((s.hours[1], s.hours[2], s.hours[6]), (30 * MIN, 20 * MIN, 15 * MIN));
    assert_eq!(s.days.len(), 1);
    assert_eq!((s.days[0].turns, s.days[0].working_ms), (3, 65 * MIN));
    assert_eq!((s.harnesses[0].sessions, s.harnesses[0].turns), (2, 3));
    assert_eq!(s.harnesses[0].working_ms, 65 * MIN);
    // The copies overlap the parent's turns in time, but no agent ran them.
    assert_eq!(s.peak_parallel, 1);
}

#[test]
fn stats_a_forks_copies_do_not_count_once_its_parent_is_gone() {
    let store = MemoryStore::default();
    // The parent's log was deleted: its turn the day before is gone from the
    // stats, the fork's copy of it included, so it lengthens no streak.
    let mut fork = session(&store, meta("fork", "claude", "ready", DAY0 + 12 * HOUR));
    fork.turn(DAY0 - DAY + HOUR, DAY0 - DAY + 2 * HOUR, json!({}));
    fork.push(DAY0 + HOUR, "mux", "forked", json!({"parentId": "gone", "forkSeq": 4}));
    fork.turn(DAY0 + 2 * HOUR, DAY0 + 2 * HOUR + 10 * MIN, json!({}));

    let s = summarize(&store, &options(DAY0 + 12 * HOUR, 7), &live_ids(&[])).unwrap();
    assert_eq!((s.sessions, s.turns, s.prompts), (1, 1, 1));
    assert_eq!(s.working_ms, 10 * MIN);
    assert_eq!(s.days.iter().map(|d| d.day.as_str()).collect::<Vec<_>>(), ["2026-10-12"]);
    assert_eq!((s.streak.current, s.streak.longest), (1, 1));
}
