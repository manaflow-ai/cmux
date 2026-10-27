//! The counting rule, the ledger and the watcher's wake rule on a fake
//! clock: a 300 ms scope is one hang, a 200 ms one none, a scope that still
//! runs reports its time so far, and a watcher with no armed scope never
//! wakes. The request watchdog calls the same [`hang_step`] and
//! [`next_wake`]; its own fake-clock tests are cmux-tui-core's
//! `request_watchdog_ledger_tests.rs`.

use super::*;

const PERIOD_US: u64 = 250_000;

/// A fake monotonic clock in µs, moved only by the test.
struct FakeClock(u64);

/// A watcher driven by [`hang_step`] and [`next_wake`] on the fake clock: it
/// watches at most one scope (start, end, counted sequence) and counts its
/// wakes.
struct Watcher {
    clock: FakeClock,
    ledger: HangLedger,
    scope: Option<(u64, u64)>,
    counted: Option<u64>,
    wakeups: u64,
}

impl Watcher {
    fn new() -> Self {
        Self {
            clock: FakeClock(0),
            ledger: HangLedger::default(),
            scope: None,
            counted: None,
            wakeups: 0,
        }
    }

    /// Arm one scope that starts now and runs `busy_us`, then run the
    /// watcher until it parks or `until_us`.
    fn run_scope(&mut self, busy_us: u64, until_us: u64) {
        let start = self.clock.0;
        self.scope = Some((start, start + busy_us));
        self.run(until_us, true);
    }

    /// Run the watcher from now to `until_us`: scan, then sleep to the next
    /// wake, each sleep's end one wake; return when it parks.
    fn run(&mut self, until_us: u64, mut after_arm: bool) {
        loop {
            let now = self.clock.0;
            let watching = self.scan(now);
            match next_wake(now, PERIOD_US, after_arm, watching) {
                Wake::Park => return,
                Wake::At(at) => {
                    assert!(at > now, "a wake is always later than the scan: {at} <= {now}");
                    if at > until_us {
                        return;
                    }
                    self.clock.0 = at;
                    self.wakeups += 1;
                    after_arm = false;
                }
            }
        }
    }

    /// Apply [`hang_step`] to the scope: busy while `now` is before its end,
    /// ended (at its end) after. Returns whether a scope is still to watch.
    fn scan(&mut self, now: u64) -> bool {
        let Some((start, end)) = self.scope else { return false };
        let ended = now >= end;
        let at = if ended { end } else { now };
        match hang_step(start, at, ended, self.counted.is_some()) {
            HangStep::CountBusy => {
                self.counted =
                    Some(self.ledger.record("mux-conn:workspace.create".into(), start, None));
            }
            HangStep::Settle => self.ledger.finish(self.counted.unwrap_or_default(), end),
            HangStep::CountEnded => {
                self.ledger.record("mux-conn:workspace.create".into(), start, Some(end));
            }
            HangStep::Wait => {}
        }
        if ended {
            self.scope = None;
            self.counted = None;
        }
        !ended
    }

    fn hangs(&self) -> HangsSnapshot {
        self.ledger.snapshot(self.clock.0)
    }
}

#[test]
fn hang_watch_300ms_scope_is_one_hang_with_its_span_and_duration() {
    let mut watcher = Watcher::new();
    watcher.clock.0 = 10_000; // a scope that starts between ticks
    watcher.run_scope(300_000, 10_000_000);

    let hangs = watcher.hangs();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    assert_eq!(
        hangs.records,
        vec![HangRecord {
            sequence: 1,
            span: "mux-conn:workspace.create".into(),
            duration_ms: 300
        }]
    );
    // One wake per tick while the scope runs: the skipped tick after the
    // arm, then the 500 ms tick, which sees it ended and parks.
    assert_eq!(watcher.wakeups, 1, "{hangs:?}");
}

#[test]
fn hang_watch_300ms_scope_seen_busy_is_one_hang_with_its_final_duration() {
    let mut watcher = Watcher::new();
    watcher.run_scope(300_000, 10_000_000); // seen busy on the 250 ms tick
    let hangs = watcher.hangs();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    assert_eq!(hangs.records[0].duration_ms, 300, "{hangs:?}");
}

#[test]
fn hang_watch_200ms_scope_is_no_hang() {
    let mut watcher = Watcher::new();
    watcher.run_scope(200_000, 10_000_000);
    assert_eq!(watcher.hangs(), HangsSnapshot::default());
}

#[test]
fn hang_watch_still_busy_scope_reports_its_time_so_far_and_is_counted_once() {
    let mut watcher = Watcher::new();
    watcher.run_scope(3_000_000, 1_000_000);
    let hangs = watcher.hangs();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    assert_eq!(hangs.records[0].duration_ms, 1_000, "busy up to the snapshot: {hangs:?}");

    // No tick between: the snapshot alone moves the duration.
    watcher.clock.0 = 2_000_000;
    let hangs = watcher.hangs();
    assert!(hangs.records[0].duration_ms >= 2_000, "still running at 2 s: {hangs:?}");

    watcher.run(10_000_000, false);
    watcher.clock.0 = 9_000_000;
    let hangs = watcher.hangs();
    assert_eq!(hangs.over_250ms, 1, "counted once: {hangs:?}");
    assert_eq!(hangs.records[0].duration_ms, 3_000, "its final duration: {hangs:?}");
}

#[test]
fn hang_watch_no_armed_scope_wakes_zero_times() {
    let mut watcher = Watcher::new();
    watcher.run(60_000_000, false);
    assert_eq!(watcher.wakeups, 0);
    assert_eq!(watcher.clock.0, 0, "parked with no timer");

    // After a hang ends, an idle watcher parks again.
    watcher.run_scope(300_000, 60_000_000);
    let after_hang = watcher.wakeups;
    watcher.clock.0 = 30_000_000;
    watcher.run(60_000_000, false);
    assert_eq!(watcher.wakeups, after_hang, "no wake once nothing is armed");
}

#[test]
fn hang_watch_step_counts_each_scope_once_at_the_threshold() {
    let threshold = HANG_THRESHOLD_US;
    assert_eq!(hang_step(10, 10 + threshold - 1, false, false), HangStep::Wait);
    assert_eq!(hang_step(10, 10 + threshold, false, false), HangStep::CountBusy);
    assert_eq!(hang_step(10, 10 + threshold * 40, false, true), HangStep::Wait);
    assert_eq!(hang_step(10, 10 + threshold - 1, true, false), HangStep::Wait);
    assert_eq!(hang_step(10, 10 + threshold, true, false), HangStep::CountEnded);
    assert_eq!(hang_step(10, 10 + threshold, true, true), HangStep::Settle);
    assert_eq!(u64::try_from(HANG_THRESHOLD.as_micros()), Ok(threshold));
}

#[test]
fn hang_watch_wake_rule_ticks_on_the_grid() {
    assert_eq!(next_wake(10, PERIOD_US, true, false), Wake::At(PERIOD_US * 2));
    assert_eq!(next_wake(PERIOD_US, PERIOD_US, true, true), Wake::At(PERIOD_US * 2));
    assert_eq!(next_wake(10, PERIOD_US, false, true), Wake::At(PERIOD_US));
    assert_eq!(next_wake(PERIOD_US, PERIOD_US, false, true), Wake::At(PERIOD_US * 2));
    assert_eq!(next_wake(10, PERIOD_US, false, false), Wake::Park);
}

#[test]
fn hang_watch_ring_keeps_the_newest_and_the_count_never_resets() {
    let ledger = HangLedger::default();
    for _ in 0..HANG_RECORDS + 5 {
        ledger.record("journal-writer:commit-batch".into(), 0, Some(260_000));
    }
    let hangs = ledger.snapshot(1_000_000);
    assert_eq!(hangs.over_250ms, (HANG_RECORDS + 5) as u64);
    assert_eq!(hangs.records.len(), HANG_RECORDS);
    assert_eq!(hangs.records[0].sequence, 6);
    assert_eq!(hangs.records[0].duration_ms, 260, "an ended hang keeps its duration");
    assert_eq!(hangs.records.last().map(|r| r.sequence), Some((HANG_RECORDS + 5) as u64));
    ledger.finish(1, 9_999_000); // left the ring: nothing to fill in
    assert_eq!(ledger.snapshot(1_000_000), hangs);
}

#[test]
fn hang_watch_snapshot_wire_shape() {
    let ledger = HangLedger::default();
    ledger.record("mux-conn:workspace.create".into(), 1_000, Some(301_000));
    let value = serde_json::to_value(ledger.snapshot(400_000)).unwrap();
    assert_eq!(
        value,
        serde_json::json!({
            "over_250ms": 1,
            "records": [{"sequence": 1, "span": "mux-conn:workspace.create", "duration_ms": 300}],
        })
    );
}
