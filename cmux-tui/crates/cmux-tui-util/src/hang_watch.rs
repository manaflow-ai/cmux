//! The daemon's hang count: every watched scope of a
//! request or mux thread that stays busy past [`HANG_THRESHOLD`] is counted
//! once, and its span and duration are kept in a bounded ring. `server-stats`
//! `include: ["hangs"]` reports both; the perf lab's
//! `daemon.hangs_over_250ms` is the difference of `over_250ms` over a window.
//!
//! This is the report half of Chrome's HangWatcher
//! (base/threading/hang_watcher.h): threads arm a per-thread deadline in
//! `WatchHangsInScope`, and one watcher thread compares the deadlines with
//! the clock and reports a hang, never killing anything. In the daemon the
//! scopes and the watcher thread are cmux-tui-core's request watchdog
//! (server/request_watchdog.rs), which feeds this ledger from its own thread
//! with [`hang_step`]'s decisions. [`next_wake`] is that watcher's wake rule:
//! unlike Chrome's fixed 10 s monitoring period, it parks with no timer while
//! no scope is armed, so an idle daemon gets 0 hang-watch wakeups.
//!
//! Every time here is microseconds on the watcher's monotonic clock, passed
//! in by the caller, so the rules and the ledger run on a fake clock in tests.

use std::collections::VecDeque;
use std::sync::PoisonError;
use std::time::Duration;

use cmux_threads::sync::Mutex;
use serde::Serialize;

/// A scope busy this long is a hang (the lab's `over_250ms`).
pub const HANG_THRESHOLD: Duration = Duration::from_micros(HANG_THRESHOLD_US);

/// [`HANG_THRESHOLD`] in µs, the unit of every time here.
pub const HANG_THRESHOLD_US: u64 = 250_000;

/// Hang records `server-stats` keeps, newest last. Older ones leave the ring
/// but stay counted in `over_250ms`; a gap in `sequence` shows them.
pub const HANG_RECORDS: usize = 64;

/// One hang: a scope seen busy past the threshold.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct HangRecord {
    /// The hang's ordinal since daemon start (1 for the first), so a reader
    /// takes the records after the last sequence it saw.
    pub sequence: u64,
    /// The scope and what it ran, `<scope>:<method>` (`mux-conn:workspace.create`,
    /// `journal-writer:commit-batch`): catalog names, never a person's text.
    pub span: String,
    /// How long the scope ran: its final duration once it ended, and its
    /// duration up to the snapshot while it still runs.
    pub duration_ms: u64,
}

/// The `hangs` section of `server-stats`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct HangsSnapshot {
    /// Hangs since daemon start; never reset.
    pub over_250ms: u64,
    /// The newest [`HANG_RECORDS`] hangs, oldest first.
    pub records: Vec<HangRecord>,
}

/// What the watcher does with one scope's hang count when it looks at it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HangStep {
    /// Nothing: under the threshold, or counted and still busy.
    Wait,
    /// Busy past the threshold and not counted yet: [`HangLedger::record`]
    /// it with no end.
    CountBusy,
    /// Ended after it was counted busy: [`HangLedger::finish`] its record.
    Settle,
    /// Ended past the threshold and never seen busy: [`HangLedger::record`]
    /// it with its end.
    CountEnded,
}

/// The counting rule for a scope that began at `start_us`, looked at at
/// `at_us`: the watcher's clock while it runs (`ended` false), its end once
/// it ended. `counted`: already recorded busy. A scope over the threshold is
/// counted exactly once, by the first look that sees it past it.
pub fn hang_step(start_us: u64, at_us: u64, ended: bool, counted: bool) -> HangStep {
    match (ended, counted) {
        (true, true) => HangStep::Settle,
        (false, true) => HangStep::Wait,
        _ if at_us.saturating_sub(start_us) < HANG_THRESHOLD_US => HangStep::Wait,
        (true, false) => HangStep::CountEnded,
        (false, false) => HangStep::CountBusy,
    }
}

/// The count and ring behind [`HangsSnapshot`]. The watcher thread writes
/// it; `server-stats` reads it.
#[derive(Default)]
pub struct HangLedger {
    /// Lock carve-out: written only by the watcher thread when a scope
    /// crosses the threshold or a counted one ends, and read by
    /// `server-stats`; never taken by a watched thread, and each hold is a
    /// push, an update of one record or a copy of at most 64 records.
    inner: Mutex<Ledger>,
}

#[derive(Default)]
struct Ledger {
    over: u64,
    records: VecDeque<Entry>,
}

/// A hang in the ring. Its duration is taken at the snapshot, so one that
/// still runs reads longer at every snapshot with no watcher wake.
struct Entry {
    sequence: u64,
    span: String,
    start_us: u64,
    /// `None` while the scope still runs.
    end_us: Option<u64>,
}

impl HangLedger {
    /// Count one hang of `span`, which began at `start_us` and ended at
    /// `end_us` (`None`: it still runs); returns its sequence for
    /// [`Self::finish`].
    pub fn record(&self, span: String, start_us: u64, end_us: Option<u64>) -> u64 {
        let mut ledger = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        ledger.over = ledger.over.saturating_add(1);
        let sequence = ledger.over;
        if ledger.records.len() == HANG_RECORDS {
            ledger.records.pop_front();
        }
        ledger.records.push_back(Entry { sequence, span, start_us, end_us });
        sequence
    }

    /// The hang `sequence` ended at `end_us`. Nothing when its record
    /// already left the ring.
    pub fn finish(&self, sequence: u64, end_us: u64) {
        let mut ledger = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(entry) = ledger.records.iter_mut().rev().find(|e| e.sequence == sequence) {
            entry.end_us = Some(end_us);
        }
    }

    /// The count and the ring at `now_us`: a hang that still runs reports
    /// its duration up to `now_us`.
    pub fn snapshot(&self, now_us: u64) -> HangsSnapshot {
        let ledger = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let records = ledger
            .records
            .iter()
            .map(|entry| HangRecord {
                sequence: entry.sequence,
                span: entry.span.clone(),
                duration_ms: entry.end_us.unwrap_or(now_us).saturating_sub(entry.start_us) / 1000,
            })
            .collect();
        HangsSnapshot { over_250ms: ledger.over, records }
    }
}

/// What the watcher thread does after a scan.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wake {
    /// Sleep until this time (µs), a tick of the watcher's grid.
    At(u64),
    /// Disarm and park with no timer until a scope arms the watcher again.
    Park,
}

/// The watcher's next wake after a scan at `now_us`, on a grid of
/// `period_us` (the threshold) since the watcher's epoch.
///
/// - `after_arm`: the scan right after a scope armed the watcher. That scope
///   began after the last tick, so it cannot cross the threshold before the
///   tick one period on: the next tick is skipped.
/// - `watching`: a scope is still to be counted or written, or one began
///   since the previous scan: wake on the next tick.
/// - Otherwise park: no timer while nothing is armed.
pub fn next_wake(now_us: u64, period_us: u64, after_arm: bool, watching: bool) -> Wake {
    let period = period_us.max(1);
    if after_arm {
        return Wake::At(now_us.saturating_add(period).div_ceil(period).saturating_mul(period));
    }
    if watching {
        return Wake::At((now_us / period).saturating_add(1).saturating_mul(period));
    }
    Wake::Park
}

#[cfg(test)]
#[path = "hang_watch_tests.rs"]
mod tests;
