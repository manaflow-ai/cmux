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
//! turns that overlap in time, across every session. Permission wait is
//! per question, from `permission_request` to its `permission_decision`
//! (`stats/attention.rs`), so two questions open at once wait twice.
//!
//! A turn or wait the daemon lost when it died ends at the session's last
//! record before the loss: at a restart's own record (`turn_result
//! outcome_unknown`, `status idle` with `detail: restart`), or at the end of
//! the log for a session this daemon does not hold running or waiting now.
//! A prompt that never got `turn_started` and was never settled has no
//! outcome: it counts as a prompt, not a turn.
//!
//! A fork's log starts with copies of its parent's prompts, tool calls and
//! turns, before its `forked` record (`hub/fork.rs`). They count once, in the
//! parent's log: in no total, day, hour, streak or parallel count of the
//! fork's. Once the parent's log is deleted or unreadable they count nowhere,
//! like the rest of that log.
//!
//! `branches` rolls the range's turns, working time and spend up by the git
//! branch each turn ended on, else the one its session started on
//! (`stats/branches.rs`).

mod attention;
mod branches;

pub use branches::{BranchStats, MAX_BRANCHES};

use crate::store::{EventRecord, SessionMeta, SessionStatus, Store, TurnUsage};
use anyhow::Result;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashSet};

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

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
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
    /// Questions asked in the range that got an answer (`permission_decision`,
    /// a cancel included) in it, and those that did not: still open, lost
    /// when the daemon that asked died, or cancelled by the remote floor
    /// after a restart (no decision record). The two sum to
    /// `permissionRequests`.
    pub permission_answered: u64,
    pub permission_unanswered: u64,
    /// Ask to answer, summed over the answered questions, and the longest
    /// one. A question shown again after a restart waits from its first ask.
    pub permission_wait_ms: u64,
    pub permission_wait_max_ms: u64,
    /// Times an agent could not serve on its account (`hub::is_limit_error`,
    /// the failover rule: usage, rate or credit limits, rejected credentials;
    /// not an overloaded provider, which retries in place): a turn that failed
    /// on one, or a failover to the fallback (which may fail too, and then
    /// counts again).
    pub limit_errors: u64,
    /// Agent turn time, summed over sessions (two agents for an hour = 2h).
    pub working_ms: u64,
    /// Time agents spent waiting on a permission answer.
    pub waiting_ms: u64,
    pub peak_parallel: u64,
    pub peak_parallel_at: Option<u64>,
    pub harnesses: Vec<HarnessStats>,
    /// Turns, working time and spend in the range per git branch, keyed by
    /// the branch and cwd a session started on; most working time first, at
    /// most `MAX_BRANCHES`. Sessions without a branch are left out
    /// (`stats/branches.rs`).
    pub branches: Vec<BranchStats>,
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

/// One pass over every session that changed in the range. `live` holds the
/// sessions running or waiting in this daemon now.
pub fn summarize(
    store: &dyn Store,
    options: &StatsOptions,
    live: &HashSet<String>,
) -> Result<StatsSummary> {
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
        session.finish(live.contains(&meta.id));
        fold.add(&meta, session);
    }
    Ok(fold.finish())
}

/// One session's turns and waits.
struct SessionFold {
    options: StatsOptions,
    /// The open turn's start.
    open: Option<u64>,
    /// The open turn got `turn_started`.
    open_started: bool,
    /// A `turn_end`/`turn_error` closed the last turn; the `turn_result`
    /// that follows it in current logs sets that turn's status.
    awaiting_result: bool,
    turns: Vec<Turn>,
    prompts: u64,
    steers: u64,
    /// Prompt ids of the steers counted.
    steered: HashSet<String>,
    tool_calls: u64,
    permission_requests: u64,
    permission_auto: u64,
    attention: attention::Attention,
    status: Option<SessionStatus>,
    waiting_since: Option<u64>,
    waiting_ms: u64,
    /// When the record before the current one was written: where a turn or
    /// a wait the daemon never closed (it died) really stopped. A restart's
    /// own records do not move it.
    last_at: Option<u64>,
    /// The open turn began before the log's `forked` record: a copy of the
    /// parent's.
    open_copied: bool,
}

struct Turn {
    start: Option<u64>,
    end: u64,
    status: TurnStatus,
    /// A fork's copy of its parent's turn (before its `forked` record).
    copied: bool,
    /// The spend its `turn_result` recorded.
    usage: TurnUsage,
    /// The branch its `turn_result` recorded it ended on (`hub/turn_git.rs`).
    branch: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum TurnStatus {
    Completed,
    Cancelled,
    Failed,
    Running,
    /// Lost when the daemon died: its working time counts, but it is not a
    /// turn (`Hub::history` leaves it running).
    Unknown,
}

impl SessionFold {
    fn new(options: &StatsOptions) -> Self {
        Self {
            options: *options,
            open: None,
            open_started: false,
            awaiting_result: false,
            turns: Vec::new(),
            prompts: 0,
            steers: 0,
            steered: HashSet::new(),
            tool_calls: 0,
            permission_requests: 0,
            permission_auto: 0,
            attention: attention::Attention::default(),
            status: None,
            waiting_since: None,
            waiting_ms: 0,
            last_at: None,
            open_copied: false,
        }
    }

    fn in_range(&self, at: u64) -> bool {
        at >= self.options.since && at <= self.options.until
    }

    fn record(&mut self, record: &EventRecord) {
        let at = record.at;
        // A restarted daemon's marks of what it lost (`mark_unknown_outcomes`,
        // `mark_lost_waits`).
        let detail = record.msg.get("detail").and_then(Value::as_str);
        let restart = matches!(
            (record.kind.as_str(), detail),
            ("turn_result", Some("outcome_unknown")) | ("status", Some("restart"))
        );
        let last = if restart {
            self.last_at.unwrap_or(at)
        } else {
            self.last_at.replace(at).unwrap_or(at)
        };
        if record.dir == "mux" {
            self.attention.record(record, self.in_range(at));
        }
        match record.kind.as_str() {
            "user_message" => {
                let steer = record.msg.get("steer").and_then(Value::as_bool) == Some(true);
                let prompt_id =
                    record.msg.get("promptId").and_then(Value::as_str).filter(|id| !id.is_empty());
                if steer {
                    if self.in_range(at) {
                        self.steers += 1;
                        if let Some(id) = prompt_id {
                            self.steered.insert(id.to_owned());
                        }
                    }
                } else {
                    // A steer that found no running turn is sent again as
                    // the next prompt under its id (`steer_turn`): one
                    // message, counted as the prompt.
                    if let Some(id) = prompt_id
                        && self.steered.remove(id)
                    {
                        self.steers -= 1;
                    }
                    self.awaiting_result = false;
                    // A prompt while a turn is open (an older log without its
                    // end, or a daemon that died mid-turn) closes that turn at
                    // its last record, and so any wait it left open; one that
                    // never started has no outcome and is not a turn. A wait
                    // after a turn ended was live up to this prompt.
                    let wait_end = if self.open.is_some() { last } else { at };
                    if let Some((start, true)) = self.take_open() {
                        self.push_turn(Some(start), last.max(start), TurnStatus::Completed);
                    }
                    self.end_wait(wait_end);
                    self.open = Some(at);
                    self.open_copied = false;
                    if self.in_range(at) {
                        self.prompts += 1;
                    }
                }
            }
            "turn_started" if record.dir == "mux" && self.open.is_some() => {
                self.open = Some(at);
                self.open_started = true;
            }
            "turn_result" if record.dir == "mux" => {
                let status = match record.msg.get("status").and_then(Value::as_str) {
                    Some("cancelled") => TurnStatus::Cancelled,
                    Some("failed") => TurnStatus::Failed,
                    _ => TurnStatus::Completed,
                };
                // A restarted daemon marks the turn it lost (`mark_unknown_outcomes`):
                // the turn and its wait stopped at the last record before it.
                if restart {
                    self.end_wait(last);
                    let end = self.open.map_or(last, |start| last.max(start));
                    self.close(end, status);
                } else {
                    self.close(at, status);
                }
                if let Some(turn) = self.turns.last_mut() {
                    turn.usage = branches::turn_usage(&record.msg);
                    turn.branch = branches::turn_branch(&record.msg);
                }
            }
            // Everything before it in a fork's log is a copy of the parent's:
            // its prompts, steers, tool calls and turns count there.
            "forked" if record.dir == "mux" => {
                for turn in &mut self.turns {
                    turn.copied = true;
                }
                self.open_copied = self.open.is_some();
                self.prompts = 0;
                self.steers = 0;
                self.steered.clear();
                self.tool_calls = 0;
            }
            // Older logs end a turn here; current ones follow with a
            // turn_result that sets the status (`awaiting_result`).
            "turn_end" | "turn_error" if record.dir == "mux" && self.open.is_some() => {
                let status = if record.kind == "turn_error" {
                    TurnStatus::Failed
                } else if record.msg.get("stopReason").and_then(Value::as_str) == Some("cancelled")
                {
                    TurnStatus::Cancelled
                } else {
                    TurnStatus::Completed
                };
                self.close_pending(at, status);
            }
            "tool_call" if record.dir == "in" && self.in_range(at) => self.tool_calls += 1,
            "permission_request" if record.dir == "mux" && self.in_range(at) => {
                self.permission_requests += 1;
            }
            "permission_auto" if record.dir == "mux" && self.in_range(at) => {
                self.permission_auto += 1;
            }
            "status" if record.dir == "mux" => {
                let status = record
                    .msg
                    .get("status")
                    .cloned()
                    .and_then(|value| serde_json::from_value::<SessionStatus>(value).ok());
                if let Some(status) = status {
                    // A restarted daemon marks the wait it lost
                    // (`mark_lost_waits`): it stopped at the record before.
                    if restart {
                        self.end_wait(last);
                    }
                    self.set_status(status, at);
                }
            }
            _ => {}
        }
    }

    /// A `turn_end`/`turn_error` ends the open turn; a `turn_result` after
    /// it only sets the status.
    fn close_pending(&mut self, at: u64, status: TurnStatus) {
        if let Some((start, _)) = self.take_open() {
            self.push_turn(Some(start), at, status);
            self.awaiting_result = true;
        }
    }

    /// Records a turn that ended, with or without a start: a fork's copy
    /// when the open turn began before its `forked` record.
    fn push_turn(&mut self, start: Option<u64>, end: u64, status: TurnStatus) {
        let copied = std::mem::take(&mut self.open_copied);
        let usage = TurnUsage::default();
        self.turns.push(Turn { start, end, status, copied, usage, branch: None });
    }

    fn take_open(&mut self) -> Option<(u64, bool)> {
        let started = std::mem::take(&mut self.open_started);
        self.open.take().map(|start| (start, started))
    }

    fn close(&mut self, at: u64, status: TurnStatus) {
        if let Some((start, _)) = self.take_open() {
            self.push_turn(Some(start), at, status);
        } else if std::mem::take(&mut self.awaiting_result)
            && let Some(last) = self.turns.last_mut()
        {
            last.status = status;
        } else {
            // A turn that never started (the agent could not spawn).
            self.push_turn(None, at, status);
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

    /// A turn or wait still open at the end of the log runs to now when
    /// this daemon holds the session running or waiting (`live`); otherwise
    /// the daemon that ran it died and it ended at the last record. The disk
    /// status cannot tell: a restart resets it in memory only.
    fn finish(&mut self, live: bool) {
        let end =
            if live { self.options.until } else { self.last_at.unwrap_or(self.options.until) };
        match self.take_open() {
            Some((start, _)) if live => {
                self.push_turn(Some(start), end, TurnStatus::Running);
            }
            // A prompt that never started has no outcome and is not a turn.
            Some((start, true)) => {
                self.push_turn(Some(start), end.max(start), TurnStatus::Unknown);
            }
            _ => {}
        }
        if let Some(since) = self.waiting_since.take() {
            self.waiting_ms += clipped(since, end.max(since), &self.options);
        }
    }
}

/// Everything summed across sessions.
struct Fold {
    options: StatsOptions,
    summary: StatsSummary,
    harnesses: BTreeMap<String, HarnessStats>,
    branches: branches::Branches,
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
            branches: branches::Branches::default(),
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
        s.permission_answered += session.attention.answered;
        s.permission_unanswered += session.attention.unanswered();
        s.permission_wait_ms += session.attention.wait_ms;
        s.permission_wait_max_ms = s.permission_wait_max_ms.max(session.attention.wait_max_ms);
        s.limit_errors += session.attention.limit_errors;
        s.waiting_ms += session.waiting_ms;

        // A fork's copies of its parent's turns count in the parent's log.
        let (mut turns, mut working) = (0, 0);
        let mut shares = branches::BranchShares::default();
        for turn in session.turns.iter().filter(|turn| !turn.copied) {
            // A turn's working time may reach into the range whether or not
            // the turn itself counts in it.
            let work = turn.start.map_or(0, |start| self.work(start, turn.end));
            let counted = self.count_turn(turn);
            (turns, working) = (turns + u64::from(counted), working + work);
            // The branch the turn ended on; an older log's, the session's start.
            let branch = turn.branch.as_deref().or(meta.git_branch.as_deref());
            shares.add(branch, work, counted.then_some(&turn.usage));
        }
        self.branches.add(meta, shares);
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

    /// Counts a turn's outcome and day, and its day in the streak: whether
    /// it is a turn of the range. A turn counts on the day it ended; a turn
    /// the daemon lost is no turn.
    fn count_turn(&mut self, turn: &Turn) -> bool {
        if turn.status == TurnStatus::Unknown {
            return false;
        }
        if turn.status != TurnStatus::Running
            && turn.status != TurnStatus::Failed
            && turn.end >= self.streak_since()
            && turn.end <= self.options.until
        {
            let day = self.local_day(turn.end);
            self.turn_days.insert(day);
        }
        if turn.end < self.options.since || turn.end > self.options.until {
            return false;
        }
        match turn.status {
            TurnStatus::Completed => self.summary.turns_completed += 1,
            TurnStatus::Cancelled => self.summary.turns_cancelled += 1,
            TurnStatus::Failed => self.summary.turns_failed += 1,
            TurnStatus::Running | TurnStatus::Unknown => {}
        }
        if turn.status != TurnStatus::Running {
            let day = self.local_day(turn.end);
            self.day(day).turns += 1;
        }
        true
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
        self.summary.branches = self.branches.finish();
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
    let (year, month, day) = crate::server::civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}")
}
