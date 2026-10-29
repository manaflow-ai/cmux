//! The hang ledger behind server-stats `hangs`: a
//! scope of any kind busy past 250 ms is counted once with its span and
//! duration, whether the watchdog saw it busy or it ended between ticks; a
//! shorter one is not; one still busy reports its time up to the read; an
//! idle watchdog does not wake.
//!
//! The fake-clock tests drive the watchdog's own `tick` (scan, counting,
//! wake rule, disarm) the way its thread does, with no thread; the last
//! tests run the real thread on the real clock with wide margins.

use std::time::{Duration, Instant};

use super::*;

const CREATE: WatchedMethod =
    WatchedMethod(RESOURCE_TAG | ResourceOperation::WorkspaceCreate as u32);

/// The watchdog thread on a fake clock: the watchdog never starts a thread,
/// and the test runs its `tick` at each wake the thread would sleep to.
struct FakeClockWatcher {
    shared: Arc<Shared>,
    clock: Arc<AtomicU64>,
    /// The watcher's previous look.
    since: u64,
    /// The next wake; `None` while parked.
    next: Option<u64>,
    wakes: u64,
}

impl FakeClockWatcher {
    /// `hang`: every kind's hang tier but an echo item's (`None`: each
    /// kind's own). Returns the watchdog and its watcher.
    fn new(hang: Option<Duration>) -> (RequestWatchdog, Self) {
        fn no_thread(_body: Box<dyn FnOnce() + Send>) -> std::io::Result<supervised::Unparker> {
            Ok(supervised::Unparker::current_for_test())
        }
        let clock = Arc::new(AtomicU64::new(0));
        let mut watchdog = RequestWatchdog::build(
            REQUEST_WATCHDOG_THRESHOLD,
            no_thread,
            Box::new(|_thread| Err(BacktraceError::Unsupported)),
            Box::new(|_record| {}),
        );
        let shared = Arc::get_mut(&mut watchdog.shared).expect("not shared yet");
        shared.clock_for_test = Some(clock.clone());
        shared.hang_for_test = hang;
        let shared = watchdog.shared.clone();
        (watchdog, Self { shared, clock, since: 0, next: None, wakes: 0 })
    }

    fn now(&self) -> u64 {
        self.clock.load(Ordering::SeqCst)
    }

    /// Run the watcher up to `until_us`, then leave the clock there. A
    /// parked watcher that a run armed meanwhile looks at once (the arm's
    /// wake); then it looks at each wake on its grid until it parks.
    fn advance(&mut self, until_us: u64) {
        if self.next.is_none() && self.shared.armed.load(Ordering::SeqCst) {
            self.wakes += 1;
            self.tick(true);
        }
        while let Some(at) = self.next.filter(|at| *at <= until_us) {
            self.clock.store(at, Ordering::SeqCst);
            self.wakes += 1;
            self.tick(false);
        }
        self.clock.store(until_us.max(self.now()), Ordering::SeqCst);
    }

    fn tick(&mut self, after_arm: bool) {
        let now = self.now();
        let wake = self.shared.tick(now, self.since, after_arm);
        self.since = now;
        self.next = match wake {
            Wake::At(at) => Some(at),
            Wake::Park => None,
        };
    }

    fn parked(&self) -> bool {
        self.next.is_none() && !self.shared.armed.load(Ordering::SeqCst)
    }
}

#[test]
fn request_watchdog_ledger_counts_a_300ms_request_that_ends_between_ticks() {
    let (watchdog, mut watcher) = FakeClockWatcher::new(None);
    watcher.advance(10_000);
    let scope = watchdog.begin(7, CREATE).expect("a free slot");
    watcher.advance(310_000); // the tick after the arm is skipped: 500 ms
    assert_eq!(watchdog.hangs().over_250ms, 0, "not seen busy yet");
    drop(scope);
    watcher.advance(10_000_000);

    let hangs = watchdog.hangs();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    let [record] = hangs.records.as_slice() else { panic!("one record: {hangs:?}") };
    assert_eq!((record.sequence, record.span.as_str()), (1, "mux-conn:workspace.create"));
    assert_eq!(record.duration_ms, 300, "its final duration: {record:?}");
    assert!(watcher.parked(), "parked once it ended");
}

#[test]
fn request_watchdog_ledger_counts_a_300ms_request_seen_busy_once() {
    let (watchdog, mut watcher) = FakeClockWatcher::new(None);
    let scope = watchdog.begin(7, CREATE).expect("a free slot");
    watcher.advance(300_000); // seen busy on the 250 ms tick
    let hangs = watchdog.hangs();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    assert_eq!(hangs.records[0].duration_ms, 300, "busy up to the read: {hangs:?}");
    drop(scope);
    watcher.advance(10_000_000);

    let hangs = watchdog.hangs();
    assert_eq!(hangs.over_250ms, 1, "counted once: {hangs:?}");
    assert_eq!(hangs.records[0].duration_ms, 300, "its final duration: {hangs:?}");
    assert!(watcher.parked());
}

#[test]
fn request_watchdog_ledger_skips_requests_under_250ms() {
    for busy_us in [200_000, 249_999] {
        let (watchdog, mut watcher) = FakeClockWatcher::new(None);
        watcher.advance(10_000);
        let scope = watchdog.begin(7, CREATE).expect("a free slot");
        watcher.advance(10_000 + busy_us);
        drop(scope);
        watcher.advance(10_000_000);
        assert_eq!(watchdog.hangs(), HangsSnapshot::default(), "{busy_us} µs");
        assert!(watcher.parked());
    }
}

/// A run stuck past its hang tier leaves the watcher parked: the read still
/// reports its whole time so far, not the time it was first seen.
#[test]
fn request_watchdog_ledger_still_busy_request_reports_its_time_up_to_the_read() {
    let (watchdog, mut watcher) = FakeClockWatcher::new(Some(Duration::from_secs(10)));
    let scope = watchdog.begin(7, CREATE).expect("a free slot");
    watcher.advance(2_000_000);
    let hangs = watchdog.hangs();
    assert!(hangs.records[0].duration_ms >= 2_000, "still busy at 2 s: {hangs:?}");

    watcher.advance(12_000_000);
    assert!(watcher.parked(), "written as a hang and counted: nothing left to watch");
    let wakes = watcher.wakes;
    let hangs = watchdog.hangs();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    assert_eq!(hangs.records[0].duration_ms, 12_000, "busy up to the read: {hangs:?}");

    watcher.advance(13_000_000);
    assert_eq!(watcher.wakes, wakes, "no wake to keep the duration current");
    drop(scope);
    watcher.advance(20_000_000);
    let hangs = watchdog.hangs();
    assert_eq!(hangs.over_250ms, 1, "counted once: {hangs:?}");
    assert_eq!(hangs.records[0].duration_ms, 13_000, "its final duration: {hangs:?}");
}

/// A journal commit's hang tier (2 s) is past the ledger's 250 ms: a 300 ms
/// commit hands its end to the watchdog and is counted, not logged.
#[test]
fn request_watchdog_ledger_counts_a_300ms_journal_commit_under_its_hang_tier() {
    let (watchdog, mut watcher) = FakeClockWatcher::new(None);
    watcher.advance(10_000);
    let scope = watchdog.watch(WatchKind::JournalWriter, 0).expect("a free slot");
    watcher.advance(310_000);
    drop(scope);
    watcher.advance(10_000_000);
    let hangs = watchdog.hangs();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    assert_eq!(hangs.records[0].span, "journal-writer:commit-batch", "{hangs:?}");
    assert_eq!(watchdog.snapshot().hangs, 0, "under its hang tier: not in the hang log");
    assert!(watcher.parked());
}

/// An echo item's hang tier (100 ms) is under the ledger's 250 ms: written
/// to the hang log on one tick, it stays watched and is counted on a later
/// one.
#[test]
fn request_watchdog_ledger_counts_an_echo_item_after_its_hang_log_record() {
    let (watchdog, mut watcher) = FakeClockWatcher::new(None);
    let request = watchdog.begin(1, CREATE).expect("a free slot");
    watcher.advance(100_000);
    let echo = watchdog.echo_watch();
    let item = echo.item(WatchKind::LineOut).expect("a free slot");
    watcher.advance(250_000);
    assert_eq!(watchdog.snapshot().hangs, 1, "the echo item's hang-log record");
    assert_eq!(watchdog.hangs().over_250ms, 1, "only the request so far");
    drop(request);
    watcher.advance(500_000);
    let hangs = watchdog.hangs();
    assert_eq!(hangs.over_250ms, 2, "{hangs:?}");
    assert_eq!(hangs.records[1].span, "mux-line-out:write-item", "{hangs:?}");
    assert_eq!(hangs.records[1].duration_ms, 400, "busy up to the read: {hangs:?}");
    drop(item);
    watcher.advance(10_000_000);
    assert_eq!(watchdog.hangs().over_250ms, 2, "each counted once");
    assert!(watcher.parked());
}

#[test]
fn request_watchdog_ledger_idle_watchdog_wakes_zero_times() {
    let (watchdog, mut watcher) = FakeClockWatcher::new(None);
    watcher.advance(60_000_000);
    assert_eq!(watcher.wakes, 0, "nothing armed: no wake");

    let scope = watchdog.begin(1, CREATE).expect("a free slot");
    watcher.advance(60_300_000);
    drop(scope);
    watcher.advance(61_000_000);
    assert_eq!(watchdog.hangs().over_250ms, 1);
    assert!(watcher.parked());
    let wakes = watcher.wakes;
    watcher.advance(120_000_000);
    assert_eq!(watcher.wakes, wakes, "no wake once nothing is armed");
}

/// Waits (bounded) until the ledger has `count` hangs.
fn wait_hangs(watchdog: &RequestWatchdog, count: u64) -> HangsSnapshot {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let hangs = watchdog.hangs();
        if hangs.over_250ms >= count {
            return hangs;
        }
        assert!(Instant::now() < deadline, "never {count} hangs: {hangs:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn wait_disarmed(watchdog: &RequestWatchdog) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while watchdog.shared.armed.load(Ordering::SeqCst) {
        assert!(Instant::now() < deadline, "the watchdog never disarmed");
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// The real thread and clock. A sleep only overshoots, so the 300 ms request
/// is always a hang; the 100 ms one has 150 ms of slack under the threshold.
#[test]
fn request_watchdog_ledger_real_thread_counts_300ms_and_skips_100ms() {
    let watchdog = RequestWatchdog::for_hang_test(
        REQUEST_WATCHDOG_THRESHOLD,
        Duration::from_secs(10),
        Box::new(|_record| {}),
    );
    let short = watchdog.begin(7, CREATE).expect("a free slot");
    std::thread::sleep(Duration::from_millis(100));
    drop(short);
    let long = watchdog.begin(7, CREATE).expect("a free slot");
    std::thread::sleep(Duration::from_millis(300));
    drop(long);
    wait_hangs(&watchdog, 1);
    wait_disarmed(&watchdog);

    let hangs = watchdog.hangs();
    let [record] = hangs.records.as_slice() else { panic!("one record: {hangs:?}") };
    assert_eq!(record.span, "mux-conn:workspace.create");
    assert!(record.duration_ms >= 300, "its final duration: {record:?}");
}
