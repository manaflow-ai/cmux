//! The daemon's hang count (p12-perf-process-232): every watched scope of a
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
//! (server/request_watchdog.rs), which feeds this ledger from its own thread.
//! [`next_wake`] is that watcher's wake rule: unlike Chrome's fixed 10 s
//! monitoring period, it parks with no timer while no scope is armed, so an
//! idle daemon gets 0 hang-watch wakeups.
//!
//! Every time here is microseconds on the watcher's monotonic clock, passed
//! in by the caller, so the rule and the ledger run on a fake clock in tests.

use std::collections::VecDeque;
use std::sync::PoisonError;
use std::time::Duration;

use cmux_threads::sync::Mutex;
use serde::Serialize;

/// A scope busy this long is a hang (the lab's `over_250ms`).
pub const HANG_THRESHOLD: Duration = Duration::from_millis(250);

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
    /// How long the scope ran: its final duration once it ended, how long it
    /// had run when the watcher saw it while it still runs.
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
    records: VecDeque<HangRecord>,
}

impl HangLedger {
    /// Count one hang of `span`, busy `duration_ms` so far; returns its
    /// sequence for [`Self::finish`].
    pub fn record(&self, span: String, duration_ms: u64) -> u64 {
        let mut ledger = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        ledger.over = ledger.over.saturating_add(1);
        let sequence = ledger.over;
        if ledger.records.len() == HANG_RECORDS {
            ledger.records.pop_front();
        }
        ledger.records.push_back(HangRecord { sequence, span, duration_ms });
        sequence
    }

    /// The hang `sequence` ended after `duration_ms` in all. Nothing when its
    /// record already left the ring.
    pub fn finish(&self, sequence: u64, duration_ms: u64) {
        let mut ledger = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(record) = ledger.records.iter_mut().rev().find(|r| r.sequence == sequence) {
            record.duration_ms = duration_ms;
        }
    }

    pub fn snapshot(&self) -> HangsSnapshot {
        let ledger = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        HangsSnapshot { over_250ms: ledger.over, records: ledger.records.iter().cloned().collect() }
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
