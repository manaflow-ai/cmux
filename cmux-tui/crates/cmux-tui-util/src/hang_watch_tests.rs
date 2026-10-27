//! The hang ledger and the watcher's wake rule on a fake clock: a 300 ms
//! scope is one hang, a 200 ms one none, and a watcher with no armed scope
//! never wakes.

use super::*;

const PERIOD_US: u64 = 250_000;

/// A fake monotonic clock in µs, moved only by the test.
struct FakeClock(u64);

/// A watcher driven by [`next_wake`] on the fake clock: it watches at most
/// one scope (start, end, counted sequence) and counts its wakes.
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

    /// Count the scope once it ran past the threshold; settle it once it
    /// ended. Returns whether a scope is still to watch.
    fn scan(&mut self, now: u64) -> bool {
        let Some((start, end)) = self.scope else { return false };
        let threshold = u64::try_from(HANG_THRESHOLD.as_micros()).unwrap();
        let busy = now.min(end) - start;
        if self.counted.is_none() && busy >= threshold {
            self.counted =
                Some(self.ledger.record("mux-conn:workspace.create".into(), busy / 1000));
        }
        if now >= end {
            if let Some(sequence) = self.counted {
                self.ledger.finish(sequence, (end - start) / 1000);
            }
            self.scope = None;
            return false;
        }
        true
    }
}

#[test]
fn hang_watch_300ms_scope_is_one_hang_with_its_span_and_duration() {
    let mut watcher = Watcher::new();
    watcher.clock.0 = 10_000; // a scope that starts between ticks
    watcher.run_scope(300_000, 10_000_000);

    let hangs = watcher.ledger.snapshot();
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
fn hang_watch_200ms_scope_is_no_hang() {
    let mut watcher = Watcher::new();
    watcher.run_scope(200_000, 10_000_000);
    assert_eq!(watcher.ledger.snapshot(), HangsSnapshot::default());
}

#[test]
fn hang_watch_still_busy_scope_is_counted_once_with_its_time_so_far() {
    let mut watcher = Watcher::new();
    watcher.run_scope(3_000_000, 1_000_000);
    let hangs = watcher.ledger.snapshot();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    assert_eq!(hangs.records[0].duration_ms, 250, "seen on the first tick: {hangs:?}");
    watcher.run(10_000_000, false);
    let hangs = watcher.ledger.snapshot();
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
        ledger.record("journal-writer:commit-batch".into(), 260);
    }
    let hangs = ledger.snapshot();
    assert_eq!(hangs.over_250ms, (HANG_RECORDS + 5) as u64);
    assert_eq!(hangs.records.len(), HANG_RECORDS);
    assert_eq!(hangs.records[0].sequence, 6);
    assert_eq!(hangs.records.last().map(|r| r.sequence), Some((HANG_RECORDS + 5) as u64));
    ledger.finish(1, 9_999); // left the ring: nothing to fill in
    assert_eq!(ledger.snapshot(), hangs);
}

#[test]
fn hang_watch_snapshot_wire_shape() {
    let ledger = HangLedger::default();
    ledger.record("mux-conn:workspace.create".into(), 300);
    let value = serde_json::to_value(ledger.snapshot()).unwrap();
    assert_eq!(
        value,
        serde_json::json!({
            "over_250ms": 1,
            "records": [{"sequence": 1, "span": "mux-conn:workspace.create", "duration_ms": 300}],
        })
    );
}
