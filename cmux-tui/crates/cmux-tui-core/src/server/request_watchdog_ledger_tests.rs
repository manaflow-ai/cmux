//! The hang ledger behind server-stats `hangs` (p12-perf-process-232): a
//! scope of any kind busy past 250 ms is counted once with its span and
//! final duration, whether the watchdog saw it busy or it ended between
//! ticks; a shorter one is not; an idle watchdog does not wake.

use std::time::{Duration, Instant};

use super::*;

const CREATE: WatchedMethod =
    WatchedMethod(RESOURCE_TAG | ResourceOperation::WorkspaceCreate as u32);

/// A watchdog with the default threshold whose hang-log records are dropped
/// (no process hang log in tests).
fn watchdog() -> RequestWatchdog {
    RequestWatchdog::for_hang_test(
        REQUEST_WATCHDOG_THRESHOLD,
        Duration::from_secs(10),
        Box::new(|_record| {}),
    )
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

#[test]
fn request_watchdog_ledger_counts_a_300ms_request_once() {
    let watchdog = watchdog();
    let scope = watchdog.begin(7, CREATE).expect("a free slot");
    std::thread::sleep(Duration::from_millis(300));
    drop(scope);
    wait_hangs(&watchdog, 1);
    wait_disarmed(&watchdog);

    let hangs = watchdog.hangs();
    assert_eq!(hangs.over_250ms, 1, "{hangs:?}");
    let [record] = hangs.records.as_slice() else { panic!("one record: {hangs:?}") };
    assert_eq!((record.sequence, record.span.as_str()), (1, "mux-conn:workspace.create"));
    assert!((300..1_000).contains(&record.duration_ms), "its final duration: {record:?}");
}

#[test]
fn request_watchdog_ledger_skips_a_200ms_request() {
    let watchdog = watchdog();
    let scope = watchdog.begin(7, CREATE).expect("a free slot");
    std::thread::sleep(Duration::from_millis(200));
    drop(scope);
    wait_disarmed(&watchdog);
    assert_eq!(watchdog.hangs(), HangsSnapshot::default());
}

/// A journal commit's hang tier (2 s) is past the ledger's 250 ms: a 300 ms
/// commit that ends between ticks still hands its end to the watchdog.
#[test]
fn request_watchdog_ledger_counts_a_300ms_journal_commit_under_its_hang_tier() {
    let (records, received) = std::sync::mpsc::channel();
    let records = std::sync::Mutex::new(records);
    let watchdog = RequestWatchdog::build(
        REQUEST_WATCHDOG_THRESHOLD,
        spawn_watchdog_thread,
        Box::new(thread_backtrace::capture),
        Box::new(move |record| {
            let _ = records.lock().unwrap().send(record);
        }),
    );
    let scope = watchdog.watch(WatchKind::JournalWriter, 0).expect("a free slot");
    std::thread::sleep(Duration::from_millis(300));
    drop(scope);
    let hangs = wait_hangs(&watchdog, 1);
    assert_eq!(hangs.records[0].span, "journal-writer:commit-batch", "{hangs:?}");
    wait_disarmed(&watchdog);
    assert!(received.try_recv().is_err(), "under its hang tier: not in the hang log");
}

/// An echo item's hang tier (100 ms) is under the ledger's 250 ms: the
/// watchdog keeps watching it after the hang-log record and counts it busy.
#[test]
fn request_watchdog_ledger_counts_an_echo_item_still_busy_past_250ms() {
    let watchdog = watchdog();
    let echo = watchdog.echo_watch();
    let scope = echo.item(WatchKind::LineOut).expect("a free slot");
    let hangs = wait_hangs(&watchdog, 1);
    assert_eq!(hangs.records[0].span, "mux-line-out:write-item", "{hangs:?}");
    assert!(hangs.records[0].duration_ms >= 250, "{hangs:?}");
    drop(scope);
    wait_disarmed(&watchdog);
    assert_eq!(watchdog.hangs().over_250ms, 1, "counted once");
}

#[test]
fn request_watchdog_ledger_idle_watchdog_wakes_zero_times() {
    let watchdog = watchdog();
    let scope = watchdog.begin(1, CREATE).expect("a free slot");
    std::thread::sleep(Duration::from_millis(300));
    drop(scope);
    wait_hangs(&watchdog, 1);
    wait_disarmed(&watchdog);
    let before = watchdog.shared.wakeups.load(Ordering::Relaxed);
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(watchdog.shared.wakeups.load(Ordering::Relaxed), before, "woke while idle");
    assert_eq!(watchdog.hangs().over_250ms, 1);
}
