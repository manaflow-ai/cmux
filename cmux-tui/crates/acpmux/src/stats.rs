//! Personal agent stats (`_acpmux/stats`, hq#1920 first slice): one pass over
//! this machine's session logs, folded into totals, per-harness and per-day
//! rollups for the Stats page. Local only: nothing here leaves the machine,
//! and no prompt or tool text is read into the answer.
//!
//! A turn follows `Hub::history`: it starts at a prompt (`user_message`
//! that is not a steer; `turn_started` moves the start to when the agent
//! began, so time in the queue is not working time) and ends at
//! `turn_result` (older logs: `turn_end` or `turn_error`). Waiting is time
//! in status `waiting` (a permission question open). Parallel agents count
//! turns that overlap in time, across every session.

use crate::store::{EventRecord, SessionMeta, SessionStatus, Store};
use anyhow::Result;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

const HOUR_MS: u64 = 3_600_000;
const DAY_MS: u64 = 24 * HOUR_MS;
/// The widest range one request may ask for.
pub const MAX_RANGE_DAYS: u64 = 366;
/// The range a request without `days` gets: the page's twelve-week heatmap.
pub const DEFAULT_RANGE_DAYS: u64 = 84;

/// What one `_acpmux/stats` request asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StatsOptions {
    /// Unix ms; activity before it is left out.
    pub since: u64,
    /// Unix ms; activity after it is left out (the request's now).
    pub until: u64,
    /// The asking page's UTC offset in minutes (east positive), for days,
    /// hours and streaks in the person's own calendar.
    pub tz_offset_minutes: i32,
}

impl StatsOptions {
    /// From request params `{days?, tzOffsetMinutes?}` at `now`.
    pub fn from_params(params: &Value, now: u64) -> Self {
        let days = params
            .get("days")
            .and_then(Value::as_u64)
            .unwrap_or(DEFAULT_RANGE_DAYS)
            .clamp(1, MAX_RANGE_DAYS);
        let tz_offset_minutes = params
            .get("tzOffsetMinutes")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .clamp(-14 * 60, 14 * 60) as i32;
        Self { since: now.saturating_sub(days * DAY_MS), until: now, tz_offset_minutes }
    }
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StatsSummary {
    pub since: u64,
    pub until: u64,
    pub tz_offset_minutes: i32,
    /// Sessions with at least one turn in the range.
    pub sessions: u64,
    pub turns: u64,
    pub turns_completed: u64,
    pub turns_cancelled: u64,
    pub turns_failed: u64,
    /// Prompts that started a turn, and steers sent into a running one.
    pub prompts: u64,
    pub steers: u64,
    pub tool_calls: u64,
    /// Permission questions asked, and those the rules answered.
    pub permission_requests: u64,
    pub permission_auto: u64,
    /// Agent turn time, summed over sessions (two agents for an hour = 2h).
    pub working_ms: u64,
    /// Time agents spent waiting on a permission answer.
    pub waiting_ms: u64,
    pub peak_parallel: u64,
    pub peak_parallel_at: Option<u64>,
    pub harnesses: Vec<HarnessStats>,
    /// Days with activity, oldest first, in the person's calendar.
    pub days: Vec<DayStats>,
    /// Working time per hour of the day (0 to 23), in the person's calendar.
    pub hours: Vec<u64>,
    pub streak: Streak,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HarnessStats {
    pub harness: String,
    pub sessions: u64,
    pub turns: u64,
    pub working_ms: u64,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DayStats {
    /// `YYYY-MM-DD`.
    pub day: String,
    pub turns: u64,
    pub working_ms: u64,
}

#[derive(Debug, Clone, Copy, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Streak {
    /// Days in a row with a finished turn, ending today (or yesterday, so a
    /// streak does not read 0 before the day's first turn).
    pub current: u64,
    pub longest: u64,
}

/// One pass over every session that changed in the range.
pub fn summarize(store: &dyn Store, options: &StatsOptions) -> Result<StatsSummary> {
    let mut fold = Fold::new(*options);
    for meta in store.list()? {
        // The streak looks back the longest range whatever range was asked.
        if meta.updated_at < fold.streak_since() {
            continue;
        }
        let mut session = SessionFold::new(options);
        let scanned = store.scan(&meta.id, 0, &mut |record| {
            session.record(&record);
            true
        });
        // One torn or vanished log costs that session, not the answer.
        if let Err(error) = scanned {
            tracing::warn!(session = %meta.id, "stats: skipping an unreadable log: {error:#}");
            continue;
        }
        session.finish(&meta);
        fold.add(&meta, session);
    }
    Ok(fold.finish())
}

/// One session's turns and waits.
struct SessionFold {
    options: StatsOptions,
    /// The open turn's start.
    open: Option<u64>,
    /// A `turn_end`/`turn_error` closed the last turn; the `turn_result`
    /// that follows it in current logs sets that turn's status.
    awaiting_result: bool,
    turns: Vec<Turn>,
    prompts: u64,
    steers: u64,
    tool_calls: u64,
    permission_requests: u64,
    permission_auto: u64,
    status: Option<SessionStatus>,
    waiting_since: Option<u64>,
    waiting_ms: u64,
    /// When the record before the current one was written: where a turn or
    /// a wait the daemon never closed (it died) really stopped.
    last_at: Option<u64>,
}

struct Turn {
    start: Option<u64>,
    end: u64,
    status: TurnStatus,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum TurnStatus {
    Completed,
    Cancelled,
    Failed,
    Running,
}

impl SessionFold {
    fn new(options: &StatsOptions) -> Self {
        Self {
            options: *options,
            open: None,
            awaiting_result: false,
            turns: Vec::new(),
            prompts: 0,
            steers: 0,
            tool_calls: 0,
            permission_requests: 0,
            permission_auto: 0,
            status: None,
            waiting_since: None,
            waiting_ms: 0,
            last_at: None,
        }
    }

    fn in_range(&self, at: u64) -> bool {
        at >= self.options.since && at <= self.options.until
    }

    fn record(&mut self, record: &EventRecord) {
        let at = record.at;
        let last = self.last_at.replace(at).unwrap_or(at);
        match record.kind.as_str() {
            "user_message" => {
                let steer = record.msg.get("steer").and_then(Value::as_bool) == Some(true);
                if steer {
                    if self.in_range(at) {
                        self.steers += 1;
                    }
                } else {
                    self.awaiting_result = false;
                    // A prompt while a turn is open (an older log without its
                    // end, or a daemon that died mid-turn) closes that turn at
                    // its last record, and so any wait it left open.
                    if let Some(start) = self.open.take() {
                        self.turns.push(Turn {
                            start: Some(start),
                            end: last.max(start),
                            status: TurnStatus::Completed,
                        });
                    }
                    self.end_wait(last);
                    self.open = Some(at);
                    if self.in_range(at) {
                        self.prompts += 1;
                    }
                }
            }
            "turn_started" if record.dir == "mux" => {
                if self.open.is_some() {
                    self.open = Some(at);
                }
            }
            "turn_result" if record.dir == "mux" => {
                let status = match record.msg.get("status").and_then(Value::as_str) {
                    Some("cancelled") => TurnStatus::Cancelled,
                    Some("failed") => TurnStatus::Failed,
                    _ => TurnStatus::Completed,
                };
                // A restarted daemon marks the turn it lost (`mark_unknown_outcomes`):
                // the turn and its wait stopped at the last record before it.
                if record.msg.get("detail").and_then(Value::as_str) == Some("outcome_unknown") {
                    self.end_wait(last);
                    let end = self.open.map_or(last, |start| last.max(start));
                    self.close(end, status);
                } else {
                    self.close(at, status);
                }
            }
            "turn_end" | "turn_error" if record.dir == "mux" => {
                // Older logs end a turn here; current ones follow with a
                // turn_result that sets the status (`awaiting_result`).
                if self.open.is_some() {
                    let status = if record.kind == "turn_error" {
                        TurnStatus::Failed
                    } else if record.msg.get("stopReason").and_then(Value::as_str)
                        == Some("cancelled")
                    {
                        TurnStatus::Cancelled
                    } else {
                        TurnStatus::Completed
                    };
                    self.close_pending(at, status);
                }
            }
            "tool_call" if record.dir == "in" => {
                if self.in_range(at) {
                    self.tool_calls += 1;
                }
            }
            "permission_request" if record.dir == "mux" => {
                if self.in_range(at) {
                    self.permission_requests += 1;
                }
            }
            "permission_auto" if record.dir == "mux" => {
                if self.in_range(at) {
                    self.permission_auto += 1;
                }
            }
            "status" if record.dir == "mux" => {
                let status = record
                    .msg
                    .get("status")
                    .cloned()
                    .and_then(|value| serde_json::from_value::<SessionStatus>(value).ok());
                if let Some(status) = status {
                    self.set_status(status, at);
                }
            }
            _ => {}
        }
    }

    /// A `turn_end`/`turn_error` ends the open turn; a `turn_result` after
    /// it only sets the status.
    fn close_pending(&mut self, at: u64, status: TurnStatus) {
        if let Some(start) = self.open.take() {
            self.turns.push(Turn { start: Some(start), end: at, status });
            self.awaiting_result = true;
        }
    }

    fn close(&mut self, at: u64, status: TurnStatus) {
        if let Some(start) = self.open.take() {
            self.turns.push(Turn { start: Some(start), end: at, status });
        } else if std::mem::take(&mut self.awaiting_result)
            && let Some(last) = self.turns.last_mut()
        {
            last.status = status;
        } else {
            // A turn that never started (the agent could not spawn).
            self.turns.push(Turn { start: None, end: at, status });
        }
        self.awaiting_result = false;
    }

    /// Ends an open wait at `at`; the next status record starts afresh.
    fn end_wait(&mut self, at: u64) {
        if let Some(since) = self.waiting_since.take() {
            self.waiting_ms += clipped(since, at.max(since), &self.options);
            self.status = None;
        }
    }

    fn set_status(&mut self, status: SessionStatus, at: u64) {
        if self.status == Some(status) {
            return;
        }
        if let Some(since) = self.waiting_since.take() {
            self.waiting_ms += clipped(since, at, &self.options);
        }
        if status == SessionStatus::Waiting {
            self.waiting_since = Some(at);
        }
        self.status = Some(status);
    }

    /// A turn still open at the end of the log is running now when the
    /// session says so; otherwise the daemon stopped mid-turn and it is
    /// dropped.
    fn finish(&mut self, meta: &SessionMeta) {
        let live = matches!(meta.status, SessionStatus::Running | SessionStatus::Waiting);
        if let Some(start) = self.open.take()
            && live
        {
            self.turns.push(Turn {
                start: Some(start),
                end: self.options.until,
                status: TurnStatus::Running,
            });
        }
        if let Some(since) = self.waiting_since.take()
            && live
        {
            self.waiting_ms += clipped(since, self.options.until, &self.options);
        }
    }
}

/// Everything summed across sessions.
struct Fold {
    options: StatsOptions,
    summary: StatsSummary,
    harnesses: BTreeMap<String, HarnessStats>,
    days: BTreeMap<i64, DayStats>,
    hours: [u64; 24],
    /// Local days with a finished turn, over the longest range.
    turn_days: BTreeSet<i64>,
    /// (time, +1 start / -1 end) of every working interval.
    edges: Vec<(u64, i8)>,
}

impl Fold {
    fn new(options: StatsOptions) -> Self {
        Self {
            options,
            summary: StatsSummary {
                since: options.since,
                until: options.until,
                tz_offset_minutes: options.tz_offset_minutes,
                ..StatsSummary::default()
            },
            harnesses: BTreeMap::new(),
            days: BTreeMap::new(),
            hours: [0; 24],
            turn_days: BTreeSet::new(),
            edges: Vec::new(),
        }
    }

    fn streak_since(&self) -> u64 {
        self.options.until.saturating_sub(MAX_RANGE_DAYS * DAY_MS).min(self.options.since)
    }

    fn offset_ms(&self) -> i64 {
        i64::from(self.options.tz_offset_minutes) * 60_000
    }

    fn local_day(&self, at: u64) -> i64 {
        (at as i64 + self.offset_ms()).div_euclid(DAY_MS as i64)
    }

    fn day(&mut self, day: i64) -> &mut DayStats {
        self.days
            .entry(day)
            .or_insert_with(|| DayStats { day: civil_date(day), ..DayStats::default() })
    }

    fn add(&mut self, meta: &SessionMeta, session: SessionFold) {
        let s = &mut self.summary;
        s.prompts += session.prompts;
        s.steers += session.steers;
        s.tool_calls += session.tool_calls;
        s.permission_requests += session.permission_requests;
        s.permission_auto += session.permission_auto;
        s.waiting_ms += session.waiting_ms;

        let mut turns = 0;
        let mut working = 0;
        for turn in &session.turns {
            if turn.status != TurnStatus::Running
                && turn.status != TurnStatus::Failed
                && turn.end >= self.streak_since()
                && turn.end <= self.options.until
            {
                let day = self.local_day(turn.end);
                self.turn_days.insert(day);
            }
            if turn.end < self.options.since || turn.end > self.options.until {
                // A turn counts on the day it ended; its working time may
                // still reach into the range.
                if let Some(start) = turn.start {
                    working += self.work(start, turn.end);
                }
                continue;
            }
            turns += 1;
            match turn.status {
                TurnStatus::Completed => self.summary.turns_completed += 1,
                TurnStatus::Cancelled => self.summary.turns_cancelled += 1,
                TurnStatus::Failed => self.summary.turns_failed += 1,
                TurnStatus::Running => {}
            }
            if turn.status != TurnStatus::Running {
                let day = self.local_day(turn.end);
                self.day(day).turns += 1;
            }
            if let Some(start) = turn.start {
                working += self.work(start, turn.end);
            }
        }
        if turns == 0 && working == 0 {
            return;
        }
        self.summary.sessions += 1;
        self.summary.turns += turns;
        self.summary.working_ms += working;
        let name = meta.family.clone().unwrap_or_else(|| meta.harness.clone());
        let harness = self
            .harnesses
            .entry(name.clone())
            .or_insert_with(|| HarnessStats { harness: name, ..HarnessStats::default() });
        harness.sessions += 1;
        harness.turns += turns;
        harness.working_ms += working;
    }

    /// Adds one working interval (clipped to the range) to the day and hour
    /// buckets and the parallel-agents sweep; answers its length.
    fn work(&mut self, start: u64, end: u64) -> u64 {
        let start = start.max(self.options.since);
        let end = end.min(self.options.until);
        if end <= start {
            return 0;
        }
        self.edges.push((start, 1));
        self.edges.push((end, -1));
        let offset = self.offset_ms();
        let mut at = start;
        while at < end {
            let local = at as i64 + offset;
            let next_hour = (local.div_euclid(HOUR_MS as i64) + 1) * HOUR_MS as i64 - offset;
            let piece_end = end.min(next_hour as u64);
            let piece = piece_end - at;
            let hour = local.div_euclid(HOUR_MS as i64).rem_euclid(24) as usize;
            self.hours[hour] += piece;
            let day = local.div_euclid(DAY_MS as i64);
            self.day(day).working_ms += piece;
            at = piece_end;
        }
        end - start
    }

    fn finish(mut self) -> StatsSummary {
        // Ends sort before starts at the same instant: back-to-back turns
        // are not parallel.
        self.edges.sort_by_key(|&(at, delta)| (at, delta));
        let mut live: i64 = 0;
        for (at, delta) in &self.edges {
            live += i64::from(*delta);
            if live > 0 && live as u64 > self.summary.peak_parallel {
                self.summary.peak_parallel = live as u64;
                self.summary.peak_parallel_at = Some(*at);
            }
        }
        let today = self.local_day(self.options.until);
        self.summary.streak = streak(&self.turn_days, today);
        let mut harnesses: Vec<HarnessStats> = self.harnesses.into_values().collect();
        harnesses.sort_by(|a, b| b.working_ms.cmp(&a.working_ms).then(b.turns.cmp(&a.turns)));
        self.summary.harnesses = harnesses;
        self.summary.days = self.days.into_values().collect();
        self.summary.hours = self.hours.to_vec();
        self.summary
    }
}

fn clipped(start: u64, end: u64, options: &StatsOptions) -> u64 {
    end.min(options.until).saturating_sub(start.max(options.since))
}

fn streak(days: &BTreeSet<i64>, today: i64) -> Streak {
    let mut longest = 0;
    let mut run = 0;
    let mut previous: Option<i64> = None;
    for &day in days {
        run = if previous == Some(day - 1) { run + 1 } else { 1 };
        longest = longest.max(run);
        previous = Some(day);
    }
    let end = if days.contains(&today) { today } else { today - 1 };
    let mut current = 0;
    let mut day = end;
    while days.contains(&day) {
        current += 1;
        day -= 1;
    }
    Streak { current, longest }
}

/// `YYYY-MM-DD` for a count of days since 1970-01-01 (Howard Hinnant's
/// civil-from-days).
pub fn civil_date(days: i64) -> String {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}
