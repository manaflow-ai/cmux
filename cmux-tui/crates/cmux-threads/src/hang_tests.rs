//! The hang watcher: a scope past its deadline is one record naming its site
//! and thread, a short one is none, a burst of scopes wakes the watcher a
//! few times and an idle watcher never wakes.

use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::Duration;

use super::*;

static REQUEST: HangSite = HangSite::new("test.request", Duration::from_millis(250));
static SHORT: HangSite = HangSite::new("test.short", Duration::from_millis(50));

/// Longer than two periods of [`REQUEST`]: the watcher has parked by then.
const SETTLE: Duration = Duration::from_millis(600);

fn channel_sink() -> (HangSink, Receiver<HangRecord>) {
    let (records, received) = channel();
    let records = Mutex::new(records);
    let sink: HangSink = Box::new(move |record| {
        let _ = lock(&records).send(record.clone());
    });
    (sink, received)
}

fn watcher() -> (HangWatcher, Receiver<HangRecord>) {
    let (sink, received) = channel_sink();
    (HangWatcher::start(sink).expect("the watcher starts"), received)
}

fn assert_no_record(received: &Receiver<HangRecord>, within: Duration) {
    match received.recv_timeout(within) {
        Err(RecvTimeoutError::Timeout) => {}
        other => panic!("expected no record, got {other:?}"),
    }
}

#[test]
fn a_300_ms_scope_is_one_record_with_its_site_and_thread() {
    let (watcher, received) = watcher();
    let watcher = Arc::new(watcher);
    let handler = Arc::clone(&watcher);
    crate::spawn("hang-test-handler", ThreadQos::Default, move || {
        let _scope = handler.scope(&REQUEST);
        std::thread::sleep(Duration::from_millis(300));
    })
    .expect("spawn")
    .join()
    .expect("join");

    let record = received.recv_timeout(Duration::from_secs(5)).expect("one record");
    assert_eq!(record.site, "test.request");
    assert_eq!(record.thread, "hang-test-handler");
    assert_eq!(record.deadline_ms, 250);
    assert!(record.busy_ms >= 250, "{record:?}");
    #[cfg(any(target_os = "linux", target_vendor = "apple"))]
    assert!(record.tid.is_some(), "{record:?}");
    assert_no_record(&received, SETTLE);
    let snapshot = watcher.snapshot();
    assert_eq!(snapshot.total, 1, "{snapshot:?}");
    assert_eq!(snapshot.recent, vec![record]);
}

#[test]
fn a_10_ms_scope_is_not_recorded() {
    let (watcher, received) = watcher();
    {
        let _scope = watcher.scope(&REQUEST);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_no_record(&received, SETTLE);
    assert_eq!(watcher.snapshot().total, 0);
}

#[test]
fn ten_thousand_scopes_wake_the_watcher_fewer_than_ten_times() {
    let (watcher, received) = watcher();
    for _ in 0..10_000 {
        drop(watcher.scope(&REQUEST));
    }
    assert_no_record(&received, SETTLE);
    let snapshot = watcher.snapshot();
    assert!(snapshot.wakeups < 10, "{snapshot:?}");
    assert_eq!(snapshot.total, 0, "{snapshot:?}");
}

/// Scopes a few ms apart: each would arm a parked watcher if the watcher
/// parked as soon as no scope was open.
#[test]
fn spaced_scopes_wake_the_watcher_at_most_once_a_period() {
    let (watcher, received) = watcher();
    let start = Instant::now();
    for _ in 0..500 {
        drop(watcher.scope(&REQUEST));
        std::thread::sleep(Duration::from_millis(2));
    }
    let elapsed = start.elapsed();
    let woke = watcher.snapshot().wakeups;
    let periods = elapsed.as_millis().div_ceil(REQUEST.deadline().as_millis());
    let allowed = u64::try_from(periods).unwrap_or(u64::MAX) + 2;
    assert!(woke <= allowed, "{woke} wakeups in {elapsed:?} (allowed {allowed})");
    assert_no_record(&received, SETTLE);
}

#[test]
fn an_idle_watcher_does_not_wake() {
    let (watcher, _received) = watcher();
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(watcher.snapshot().wakeups, 0, "woke before any scope");
    drop(watcher.scope(&REQUEST));
    std::thread::sleep(SETTLE);
    let parked = watcher.snapshot().wakeups;
    std::thread::sleep(Duration::from_secs(5));
    assert_eq!(watcher.snapshot().wakeups, parked, "the parked watcher woke while idle");
}

#[test]
fn an_overdue_inner_scope_is_recorded_and_its_outer_scope_is_not() {
    let (watcher, received) = watcher();
    {
        let _outer = watcher.scope(&REQUEST);
        {
            let _inner = watcher.scope(&SHORT);
            std::thread::sleep(Duration::from_millis(120));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let record = received.recv_timeout(Duration::from_secs(5)).expect("the inner record");
    assert_eq!(record.site, "test.short");
    assert_no_record(&received, SETTLE);
}

#[test]
fn a_recorded_scope_restored_by_a_nested_scope_is_not_recorded_again() {
    let (watcher, received) = watcher();
    {
        let _outer = watcher.scope(&SHORT);
        let record = received.recv_timeout(Duration::from_secs(5)).expect("the outer record");
        assert_eq!(record.site, "test.short");
        drop(watcher.scope(&REQUEST));
        std::thread::sleep(Duration::from_millis(150));
    }
    assert_no_record(&received, SETTLE);
    assert_eq!(watcher.snapshot().total, 1);
}

/// The watcher sleeps up to 3 s while only a [`LONG`] scope is open; a
/// shorter site opened then must not wait for that sleep to end.
#[test]
fn a_short_scope_opened_while_the_watcher_sleeps_on_a_long_site_is_recorded() {
    static LONG: HangSite = HangSite::new("test.long", Duration::from_secs(3));
    let (watcher, received) = watcher();
    let watcher = Arc::new(watcher);
    let (opened, wait_opened) = channel::<()>();
    let (close, closed) = channel::<()>();
    let long = Arc::clone(&watcher);
    let holder = crate::spawn("hang-test-long", ThreadQos::Default, move || {
        let _scope = long.scope(&LONG);
        let _ = opened.send(());
        let _ = closed.recv();
    })
    .expect("spawn");
    wait_opened.recv().expect("the long scope opened");
    // The watcher is now asleep on the 3 s period.
    std::thread::sleep(Duration::from_millis(100));
    {
        let _scope = watcher.scope(&SHORT);
        std::thread::sleep(Duration::from_millis(600));
    }
    let record = received.recv_timeout(Duration::from_secs(1)).expect("the short record");
    drop(close);
    holder.join().expect("join");
    assert_eq!(record.site, "test.short");
    assert_eq!(record.deadline_ms, 50);
    assert_no_record(&received, SETTLE);
    assert_eq!(watcher.snapshot().total, 1);
}

/// An overdue outer word read, then an inner scope that opens and closes
/// (restoring the same word), then the site read: the pair is not used.
#[test]
fn a_nested_scope_between_the_word_and_site_reads_is_not_paired_with_the_outer_deadline() {
    let (sink, received) = channel_sink();
    let watcher = HangWatcher::unstarted(sink, MAX_WATCHED_THREADS, HANG_RING);
    let _outer = watcher.scope(&SHORT);
    std::thread::sleep(Duration::from_millis(60));
    let shared = &watcher.shared;
    let mut nested = false;
    shared.scan_with(shared.now_us(), true, || {
        if !nested {
            nested = true;
            drop(watcher.scope(&REQUEST));
        }
    });
    assert!(nested, "the outer scope was overdue");
    assert!(received.try_recv().is_err(), "a pair read across a nested scope was recorded");
    shared.scan(shared.now_us(), true);
    let record = received.try_recv().expect("the outer record on the next scan");
    assert_eq!((record.site, record.deadline_ms), ("test.short", 50), "{record:?}");
    assert_eq!(watcher.snapshot().total, 1);
}

#[test]
fn a_panicking_sink_is_counted_and_the_watcher_keeps_recording() {
    let (records, received) = channel();
    let records = Mutex::new(records);
    let calls = AtomicUsize::new(0);
    let sink: HangSink = Box::new(move |record| {
        assert!(calls.fetch_add(1, Ordering::Relaxed) > 0, "the test sink fails once");
        let _ = lock(&records).send(record.clone());
    });
    let watcher = HangWatcher::start(sink).expect("the watcher starts");
    for _ in 0..2 {
        let _scope = watcher.scope(&SHORT);
        std::thread::sleep(Duration::from_millis(150));
    }
    let record = received.recv_timeout(Duration::from_secs(5)).expect("the second record");
    assert_eq!(record.site, "test.short");
    let snapshot = watcher.snapshot();
    assert_eq!(snapshot.total, 2, "{snapshot:?}");
    assert_eq!(snapshot.sink_panics, 1, "{snapshot:?}");
}

#[test]
fn a_thread_past_the_slot_limit_is_unwatched_and_an_exited_threads_slot_is_reused() {
    let (sink, _received) = channel_sink();
    let watcher = Arc::new(HangWatcher::start_with(sink, 1, HANG_RING).expect("start"));
    let open_on_new_thread = |name: &'static str| {
        let watcher = Arc::clone(&watcher);
        crate::spawn(name, ThreadQos::Default, move || drop(watcher.scope(&REQUEST)))
            .expect("spawn")
            .join()
            .expect("join");
    };
    open_on_new_thread("hang-test-first");
    open_on_new_thread("hang-test-second");
    assert_eq!(watcher.snapshot().unwatched, 0, "the first thread's slot was released");

    let (held, release) = channel::<()>();
    let (claimed, wait_claimed) = channel::<()>();
    let holder = Arc::clone(&watcher);
    let holding = crate::spawn("hang-test-holder", ThreadQos::Default, move || {
        drop(holder.scope(&REQUEST));
        let _ = claimed.send(());
        let _ = release.recv();
    })
    .expect("spawn");
    wait_claimed.recv().expect("the holder claimed the slot");
    drop(watcher.scope(&REQUEST));
    assert_eq!(watcher.snapshot().unwatched, 1);
    drop(held);
    holding.join().expect("join");
}

#[test]
fn a_late_watcher_blames_nobody_and_does_not_record_the_scope_later() {
    let (sink, received) = channel_sink();
    let watcher = HangWatcher::unstarted(sink, MAX_WATCHED_THREADS, HANG_RING);
    let _scope = watcher.scope(&SHORT);
    std::thread::sleep(Duration::from_millis(60));
    let shared = &watcher.shared;
    assert_eq!(shared.scan(shared.now_us(), false), None);
    assert_eq!(shared.scan(shared.now_us(), true), None);
    assert!(received.try_recv().is_err(), "a scope seen by a late watcher is not recorded");
    let snapshot = watcher.snapshot();
    assert_eq!((snapshot.total, snapshot.unblamed), (0, 1), "{snapshot:?}");
}

/// Opening and closing a scope; `--ignored --nocapture` prints ns per scope.
#[test]
#[ignore = "bench"]
fn hang_scope_bench() {
    const RUNS: u32 = 1_000_000;
    let (watcher, _received) = watcher();
    drop(watcher.scope(&REQUEST));
    let start = Instant::now();
    for _ in 0..RUNS {
        drop(std::hint::black_box(watcher.scope(&REQUEST)));
    }
    let per_scope = start.elapsed() / RUNS;
    println!("hang scope open+close: {} ns", per_scope.as_nanos());
}

#[test]
fn the_ring_keeps_the_newest_records() {
    let mut ring = Ring::default();
    for at_ms in 0..130 {
        let record = HangRecord {
            site: "test.ring",
            deadline_ms: 1,
            thread: "t".to_owned(),
            tid: None,
            busy_ms: 1,
            at_ms,
        };
        ring.push(record, HANG_RING);
    }
    assert_eq!(ring.recent.len(), HANG_RING);
    assert_eq!(ring.total, 130);
    assert_eq!(ring.recent.front().map(|record| record.at_ms), Some(2));
}
