//! The hang watch's rules (p09-observability task 071): 0 wakes while idle, detection within the
//! deadline plus the minimum deadline, no allocation on a scope, one record per overdue scope,
//! nesting, invalidation, the drift rule and the slot table.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::io;
use std::panic::{self, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use cmux_hang_watch::{
    Clock, Config, Hang, HangSink, HangWatch, InitError, JsonlSink, MAX_SLOTS, Pass, ThreadKind,
};

struct Counting;

thread_local! {
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

fn count_allocation() {
    let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
}

fn allocations() -> u64 {
    ALLOCATIONS.with(Cell::get)
}

// SAFETY: every call forwards to the system allocator with the caller's arguments.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count_allocation();
        // SAFETY: forwarded unchanged.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count_allocation();
        // SAFETY: forwarded unchanged.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        count_allocation();
        // SAFETY: forwarded unchanged.
        unsafe { System.realloc(pointer, layout, size) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: forwarded unchanged.
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

const MS: u64 = 1_000_000;

/// A clock the test moves by hand.
#[derive(Default)]
struct ManualClock(AtomicU64);

impl ManualClock {
    fn set_ms(&self, ms: u64) {
        self.0.store(ms * MS, Ordering::SeqCst);
    }

    fn now(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

impl Clock for ManualClock {
    fn now_ns(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

/// Keeps every hang, and tells a waiting test about each.
#[derive(Clone)]
struct Collect {
    hangs: Arc<Mutex<Vec<Hang>>>,
    seen: Arc<Mutex<Option<mpsc::Sender<Instant>>>>,
}

impl Collect {
    fn new() -> Collect {
        Collect { hangs: Arc::default(), seen: Arc::default() }
    }

    fn hangs(&self) -> Vec<Hang> {
        self.hangs.lock().unwrap().clone()
    }
}

impl HangSink for Collect {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        self.hangs.lock().unwrap().push(hang.clone());
        if let Some(seen) = self.seen.lock().unwrap().as_ref() {
            let _ = seen.send(Instant::now());
        }
        Ok(())
    }
}

/// A watch with no watcher thread, on a manual clock at 0.
fn manual() -> (HangWatch, Arc<ManualClock>, Collect) {
    let clock = Arc::new(ManualClock::default());
    let sink = Collect::new();
    let watch = HangWatch::new(Config::default(), clock.clone(), Box::new(sink.clone()));
    (watch, clock, sink)
}

/// A pass on time at the clock's now.
fn on_time(watch: &HangWatch, clock: &ManualClock) -> Pass {
    watch.check(clock.now())
}

fn wait_until(timeout: Duration, mut done: impl FnMut() -> bool) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if done() {
            return true;
        }
        thread::sleep(Duration::from_millis(5));
    }
    done()
}

#[test]
fn an_idle_watcher_makes_no_wakes() {
    let config = Config { min_deadline: Duration::from_millis(50), ..Config::default() };
    let sink = Collect::new();
    let watch =
        HangWatch::spawn(config, Arc::new(cmux_hang_watch::TraceClock), Box::new(sink.clone()))
            .unwrap();

    thread::sleep(Duration::from_millis(300));
    let fresh = watch.stats();
    assert_eq!(fresh.wakes, 0, "a watch nobody used never wakes");
    assert!(fresh.parked);

    let guard = watch.register_thread(ThreadKind::Io, "mux-conn");
    for _ in 0..3 {
        let scope = guard.watch(Duration::from_secs(5));
        thread::sleep(Duration::from_millis(20));
        drop(scope);
    }
    assert!(
        wait_until(Duration::from_secs(3), || watch.stats().parked),
        "the watcher parks one quiet period after the last scope: {:?}",
        watch.stats()
    );
    thread::sleep(Duration::from_millis(100));
    let parked = watch.stats();
    assert!(parked.wakes >= 1, "the scopes woke the watcher: {parked:?}");
    assert!(parked.wakes <= 20, "about one wake per period while active: {parked:?}");

    thread::sleep(Duration::from_secs(5));
    let idle = watch.stats();
    assert_eq!(idle.wakes, parked.wakes, "0 wakes in 5 s idle: {idle:?}");
    assert!(idle.parked);
    assert!(sink.hangs().is_empty());
}

#[test]
fn a_blocked_thread_is_reported_within_its_deadline_plus_the_period() {
    let period = Duration::from_millis(100);
    let deadline = Duration::from_millis(200);
    let config = Config { min_deadline: period, ..Config::default() };
    let sink = Collect::new();
    let (seen_tx, seen_rx) = mpsc::channel();
    *sink.seen.lock().unwrap() = Some(seen_tx);
    let watch =
        HangWatch::spawn(config, Arc::new(cmux_hang_watch::TraceClock), Box::new(sink.clone()))
            .unwrap();

    let (opened_tx, opened_rx) = mpsc::channel();
    thread::scope(|threads| {
        threads.spawn(|| {
            let guard = watch.register_thread(ThreadKind::Control, "mux-control-dispatch");
            let scope = guard.watch(deadline);
            opened_tx.send(Instant::now()).unwrap();
            thread::sleep(Duration::from_millis(900));
            drop(scope);
        });
        let opened = opened_rx.recv().unwrap();
        let seen = seen_rx.recv_timeout(Duration::from_secs(3)).expect("the hang was reported");
        let latency = seen.duration_since(opened);
        assert!(latency >= deadline, "never before the deadline: {latency:?}");
        // The bound is deadline + period; the slack covers a loaded test machine.
        assert!(latency <= deadline + period + Duration::from_millis(300), "{latency:?}");
    });
    thread::sleep(Duration::from_millis(300));

    let hangs = sink.hangs();
    assert_eq!(hangs.len(), 1, "one record per overdue scope: {hangs:?}");
    let hang = &hangs[0];
    assert_eq!(hang.thread, "mux-control-dispatch");
    assert_eq!(hang.kind, ThreadKind::Control);
    assert_eq!(hang.deadline_ms, 200);
    assert_eq!(hang.pid, std::process::id());
    if cfg!(any(target_os = "linux", target_os = "macos", windows)) {
        assert_ne!(hang.native_thread_id, 0);
    }
    assert_eq!(watch.stats().hangs, 1);
}

#[test]
fn the_watcher_parks_over_spared_scopes_and_the_enclosing_scope_stays_spared() {
    let config = Config { min_deadline: Duration::from_millis(50), ..Config::default() };
    let sink = Collect::new();
    let watch =
        HangWatch::spawn(config, Arc::new(cmux_hang_watch::TraceClock), Box::new(sink.clone()))
            .unwrap();
    let guard = watch.register_thread(ThreadKind::Control, "mux-control-dispatch");

    // A request whose network wait is allowed: nothing to watch, so the watcher parks.
    let request = guard.watch(Duration::from_millis(300));
    let wait = guard.watch(Duration::from_millis(100));
    guard.invalidate_active();
    assert!(
        wait_until(Duration::from_secs(3), || watch.stats().parked),
        "an invalidated scope does not keep the watcher awake: {:?}",
        watch.stats()
    );
    let parked = watch.stats().wakes;
    thread::sleep(Duration::from_millis(400));
    assert_eq!(watch.stats().wakes, parked, "0 wakes while only a spared scope is open");

    // The wait ends: the request's scope (overdue by now) keeps the ignore until it closes.
    wait.close();
    assert!(wait_until(Duration::from_secs(3), || watch.stats().parked));
    thread::sleep(Duration::from_millis(200));
    assert!(sink.hangs().is_empty(), "the enclosing scope of an allowed wait is spared");
    drop(request);
    assert!(sink.hangs().is_empty());
}

#[test]
fn an_enclosing_scope_wakes_the_parked_watcher_when_a_reported_scope_closes() {
    let config = Config { min_deadline: Duration::from_millis(50), ..Config::default() };
    let sink = Collect::new();
    let watch =
        HangWatch::spawn(config, Arc::new(cmux_hang_watch::TraceClock), Box::new(sink.clone()))
            .unwrap();
    let guard = watch.register_thread(ThreadKind::Control, "mux-control-dispatch");

    let request = guard.watch(Duration::from_millis(1_500));
    let stuck = guard.watch(Duration::from_millis(50));
    assert!(wait_until(Duration::from_secs(3), || sink.hangs().len() == 1));
    // A thread stuck past its report gives the watcher nothing more to do.
    assert!(wait_until(Duration::from_secs(3), || watch.stats().parked));
    let parked = watch.stats().wakes;
    thread::sleep(Duration::from_millis(200));
    assert_eq!(watch.stats().wakes, parked, "0 wakes over a reported hang");

    // The inner scope ends before the request's deadline: the request watches again.
    stuck.close();
    assert!(
        wait_until(Duration::from_secs(3), || sink.hangs().len() == 2),
        "the enclosing scope is reported after the inner one closes: {:?}",
        watch.stats()
    );
    let deadlines: Vec<u64> = sink.hangs().iter().map(|hang| hang.deadline_ms).collect();
    assert_eq!(deadlines, [50, 1_500]);
    drop(request);
    assert_eq!(sink.hangs().len(), 2);
}

#[test]
fn opening_and_closing_scopes_allocates_nothing() {
    let (watch, clock, _sink) = manual();
    let guard = watch.register_thread(ThreadKind::Io, "line-out");
    drop(guard.watch(Duration::from_secs(1)));

    let before = allocations();
    for round in 0..10_000u64 {
        clock.set_ms(round);
        let outer = guard.watch(Duration::from_secs(5));
        let inner = guard.watch(Duration::from_millis(250));
        guard.invalidate_active();
        inner.close();
        drop(outer);
    }
    assert_eq!(allocations() - before, 0);
}

#[test]
fn an_overdue_scope_is_reported_once() {
    let (watch, clock, sink) = manual();
    let guard = watch.register_thread(ThreadKind::Io, "mux-conn");
    let scope = guard.watch(Duration::from_secs(1));

    clock.set_ms(999);
    assert_eq!(on_time(&watch, &clock), Pass { open: 1, armed: 1, hangs: 0, late: false });
    clock.set_ms(1_000);
    assert_eq!(on_time(&watch, &clock).hangs, 1, "due at its deadline");
    clock.set_ms(5_000);
    assert_eq!(on_time(&watch, &clock).hangs, 0);
    drop(scope);
    assert_eq!(on_time(&watch, &clock).open, 0);

    let hangs = sink.hangs();
    assert_eq!(hangs.len(), 1);
    assert_eq!(hangs[0].deadline_ms, 1_000);
    assert_eq!(hangs[0].overdue_ms, 0);
    assert_eq!(hangs[0].t_ns, 1_000 * MS);
}

#[test]
fn the_innermost_scope_applies_and_the_enclosing_one_comes_back() {
    let (watch, clock, sink) = manual();
    let guard = watch.register_thread(ThreadKind::Lane, "terminal-work");
    let outer = guard.watch(Duration::from_secs(10));
    let inner = guard.watch(Duration::from_secs(1));

    clock.set_ms(1_500);
    assert_eq!(on_time(&watch, &clock).hangs, 1, "the inner deadline applies");
    inner.close();
    clock.set_ms(2_000);
    assert_eq!(on_time(&watch, &clock).hangs, 0, "the outer one has time left");
    clock.set_ms(10_000);
    assert_eq!(on_time(&watch, &clock).hangs, 1, "the outer scope hangs on its own deadline");
    drop(outer);

    let deadlines: Vec<u64> = sink.hangs().iter().map(|hang| hang.deadline_ms).collect();
    assert_eq!(deadlines, [1_000, 10_000]);
}

#[test]
fn an_enclosing_scope_overdue_through_a_reported_hang_is_not_reported_again() {
    let (watch, clock, sink) = manual();
    let guard = watch.register_thread(ThreadKind::Lane, "terminal-work");
    let outer = guard.watch(Duration::from_secs(1));
    let inner = guard.watch(Duration::from_secs(5));

    clock.set_ms(6_000);
    assert_eq!(on_time(&watch, &clock).hangs, 1);
    inner.close();
    clock.set_ms(6_500);
    assert_eq!(on_time(&watch, &clock).hangs, 0, "the same hang keeps its one record");
    drop(outer);
    assert_eq!(sink.hangs().len(), 1);
}

#[test]
fn invalidate_active_spares_the_open_scopes_and_the_next_scope_watches_again() {
    let (watch, clock, sink) = manual();
    let guard = watch.register_thread(ThreadKind::Control, "mux-control-dispatch");
    let request = guard.watch(Duration::from_secs(1));
    guard.invalidate_active();

    clock.set_ms(3_000);
    assert_eq!(on_time(&watch, &clock), Pass { open: 1, armed: 0, hangs: 0, late: false });

    let follow_up = guard.watch(Duration::from_secs(1));
    clock.set_ms(4_000);
    assert_eq!(on_time(&watch, &clock).hangs, 1, "a scope opened after the wait watches");
    follow_up.close();
    clock.set_ms(9_000);
    assert_eq!(on_time(&watch, &clock).hangs, 0, "the invalidated scope stays spared");
    drop(request);
    assert_eq!(sink.hangs().len(), 1);
}

#[test]
fn invalidate_active_in_a_nested_scope_spares_every_enclosing_scope_until_the_outermost_closes() {
    let (watch, clock, sink) = manual();
    let guard = watch.register_thread(ThreadKind::Control, "mux-control-dispatch");
    let request = guard.watch(Duration::from_secs(1));
    let helper = guard.watch(Duration::from_millis(100));
    guard.invalidate_active();
    helper.close();

    clock.set_ms(3_000);
    assert_eq!(on_time(&watch, &clock), Pass { open: 1, armed: 0, hangs: 0, late: false });
    let follow_up = guard.watch(Duration::from_secs(1));
    clock.set_ms(4_000);
    assert_eq!(on_time(&watch, &clock).hangs, 1, "a scope opened after the wait watches");
    follow_up.close();
    clock.set_ms(9_000);
    assert_eq!(on_time(&watch, &clock).hangs, 0, "the request stays spared");
    drop(request);

    let next = guard.watch(Duration::from_secs(1));
    clock.set_ms(10_000);
    assert_eq!(on_time(&watch, &clock).hangs, 1, "the ignore ends with the outermost scope");
    drop(next);
    let deadlines: Vec<u64> = sink.hangs().iter().map(|hang| hang.deadline_ms).collect();
    assert_eq!(deadlines, [1_000, 1_000]);
}

#[test]
fn a_scope_closed_out_of_order_leaves_no_stale_scope_on_the_slot() {
    let (watch, clock, sink) = manual();
    let guard = watch.register_thread(ThreadKind::Lane, "terminal-work");
    let outer = guard.watch(Duration::from_secs(1));
    let inner = guard.watch(Duration::from_secs(5));
    let closed = panic::catch_unwind(AssertUnwindSafe(|| outer.close()));
    assert_eq!(closed.is_err(), cfg!(debug_assertions), "a debug build refuses the order");
    drop(inner);

    clock.set_ms(2_000);
    assert_eq!(on_time(&watch, &clock), Pass::default(), "both scopes are closed");
    let next = guard.watch(Duration::from_secs(1));
    clock.set_ms(3_000);
    assert_eq!(on_time(&watch, &clock).hangs, 1);
    drop(next);
    assert_eq!(on_time(&watch, &clock).open, 0, "the next scope is top level again");
    let deadlines: Vec<u64> = sink.hangs().iter().map(|hang| hang.deadline_ms).collect();
    assert_eq!(deadlines, [1_000]);
}

#[test]
fn a_report_racing_a_nested_open_and_close_is_recorded_once() {
    const ROUNDS: u64 = 4_000;
    let (watch, clock, sink) = manual();
    let done = AtomicBool::new(false);
    thread::scope(|threads| {
        threads.spawn(|| {
            while !done.load(Ordering::Relaxed) {
                watch.check(clock.now());
            }
        });
        let guard = watch.register_thread(ThreadKind::Lane, "terminal-work");
        for round in 0..ROUNDS {
            // Each round's enclosing scope has its own budget, so a second record shows.
            let start = round * 100_000;
            clock.set_ms(start);
            let budget = round + 1;
            let outer = guard.watch(Duration::from_millis(budget));
            clock.set_ms(start + budget);
            for _ in 0..64 {
                drop(guard.watch(Duration::from_secs(1_000)));
            }
            drop(outer);
        }
        done.store(true, Ordering::Relaxed);
    });

    let mut deadlines: Vec<u64> = sink.hangs().iter().map(|hang| hang.deadline_ms).collect();
    let recorded = deadlines.len();
    deadlines.sort_unstable();
    deadlines.dedup();
    assert_eq!(deadlines.len(), recorded, "one record per overdue scope");
}

#[test]
fn a_late_watcher_blames_nobody() {
    let (watch, clock, sink) = manual();
    let guard = watch.register_thread(ThreadKind::Io, "mux-conn");
    let across_sleep = guard.watch(Duration::from_secs(1));

    // The pass was due at 1 s and ran at 5 s (the watcher was starved, or the clock jumped).
    clock.set_ms(5_000);
    assert_eq!(watch.check(1_000 * MS), Pass { open: 1, armed: 0, hangs: 0, late: true });
    clock.set_ms(6_000);
    assert_eq!(on_time(&watch, &clock).hangs, 0, "deadlines before the late pass stay ignored");

    let after = guard.watch(Duration::from_secs(1));
    clock.set_ms(7_050);
    // 50 ms late is within the 100 ms tolerance. One slot is open (the scopes nest).
    assert_eq!(watch.check(7_000 * MS), Pass { open: 1, armed: 0, hangs: 1, late: false });
    drop(after);
    drop(across_sleep);

    assert_eq!(sink.hangs().len(), 1);
    assert_eq!(watch.stats().late_passes, 1);
}

#[test]
fn a_scope_that_outlives_its_guard_leaves_the_next_owner_alone() {
    let (watch, clock, sink) = manual();
    let first = watch.register_thread(ThreadKind::Io, "first");
    let stale = first.watch(Duration::from_secs(1));
    drop(first);

    let second = watch.register_thread(ThreadKind::Io, "second");
    let live = second.watch(Duration::from_secs(1));
    drop(stale);
    clock.set_ms(2_000);
    assert_eq!(on_time(&watch, &clock).hangs, 1);
    drop(live);
    assert_eq!(sink.hangs()[0].thread, "second");
}

#[test]
fn the_slot_table_grows_by_chunks_and_refuses_past_its_cap() {
    let (watch, clock, sink) = manual();
    let mut guards: Vec<_> = (0..MAX_SLOTS)
        .map(|index| watch.register_thread(ThreadKind::Pool, &format!("pool-{index}")))
        .collect();
    assert!(guards.iter().all(|guard| guard.is_registered()));
    assert_eq!(watch.stats().registered, MAX_SLOTS as u64);

    let refused = watch.register_thread(ThreadKind::Pool, "one-too-many");
    assert!(!refused.is_registered());
    assert!(!refused.watch(Duration::from_secs(1)).is_watching());
    assert_eq!(watch.stats().overflow, 1);
    drop(refused);

    guards.truncate(MAX_SLOTS - 1);
    let reused = watch.register_thread(ThreadKind::Pool, "reused");
    assert!(reused.is_registered());
    let scope = reused.watch(Duration::from_secs(1));
    let last = guards.last().unwrap().watch(Duration::from_secs(1));
    clock.set_ms(1_000);
    assert_eq!(on_time(&watch, &clock), Pass { open: 2, armed: 0, hangs: 2, late: false });
    drop((scope, last));

    let mut names: Vec<String> = sink.hangs().into_iter().map(|hang| hang.thread).collect();
    names.sort();
    assert_eq!(names, [format!("pool-{}", MAX_SLOTS - 2), "reused".to_string()]);
    let slots: Vec<u32> = sink.hangs().iter().map(|hang| hang.slot).collect();
    assert!(slots.iter().all(|slot| (*slot as usize) < MAX_SLOTS));
    drop(guards);
    drop(reused);
    assert_eq!(watch.stats().registered, 0);
}

fn scratch_dir(test: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-hang-watch-{test}-{}-{}",
        std::process::id(),
        cmux_trace::clock::now_ns()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn the_jsonl_sink_appends_one_line_per_hang() {
    let dir = scratch_dir("jsonl");
    let sink = JsonlSink::in_dir(&dir);
    let path = sink.path().to_path_buf();
    assert_eq!(path.file_name().unwrap(), format!("hangs-{}.jsonl", std::process::id()).as_str());

    let clock = Arc::new(ManualClock::default());
    let watch = HangWatch::new(Config::default(), clock.clone(), Box::new(sink));
    let guard = watch.register_thread(ThreadKind::Io, "mux-session-journal");
    let first = guard.watch(Duration::from_secs(5));
    clock.set_ms(5_250);
    assert_eq!(on_time(&watch, &clock).hangs, 1);
    drop(first);
    let second = guard.watch(Duration::from_secs(2));
    clock.set_ms(7_250);
    assert_eq!(on_time(&watch, &clock).hangs, 1);
    drop(second);

    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert!(lines[0].starts_with("{\"schema\":1,"), "{}", lines[0]);
    assert!(lines[0].contains("\"thread\":\"mux-session-journal\""), "{}", lines[0]);
    assert!(lines[0].contains("\"kind\":\"io\""), "{}", lines[0]);
    assert!(lines[0].contains("\"deadline_ms\":5000,\"overdue_ms\":250}"), "{}", lines[0]);
    assert!(lines[1].contains("\"deadline_ms\":2000,\"overdue_ms\":0}"), "{}", lines[1]);
    assert_eq!(watch.stats().sink_errors, 0);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The only test that touches the process watch, so the others cannot race it.
#[test]
fn the_process_watch_is_inert_before_init_and_watches_after() {
    let early = cmux_hang_watch::register_thread(ThreadKind::Main, "early");
    assert!(!early.is_registered());
    assert!(!cmux_hang_watch::watch(Duration::from_secs(1)).is_watching());
    assert!(cmux_hang_watch::stats().is_none());
    drop(early);

    let dir = scratch_dir("process");
    let config = Config { min_deadline: Duration::from_millis(50), ..Config::default() };
    cmux_hang_watch::init_process(
        config,
        Arc::new(cmux_hang_watch::TraceClock),
        Box::new(JsonlSink::in_dir(&dir)),
    )
    .unwrap();
    assert!(matches!(cmux_hang_watch::init(&dir), Err(InitError::AlreadyStarted)));

    let guard = cmux_hang_watch::register_thread(ThreadKind::Main, "main");
    assert!(guard.is_registered());
    // A second process registration on the thread is refused (a debug build panics), so its
    // guard can drop before or after the first and the thread's slot stays the first's.
    let again = panic::catch_unwind(|| cmux_hang_watch::register_thread(ThreadKind::Main, "again"));
    assert_eq!(again.is_err(), cfg!(debug_assertions));
    if let Ok(again) = again {
        assert!(!again.is_registered());
        drop(again);
    }
    assert!(cmux_hang_watch::watch(Duration::from_secs(1)).is_watching());
    drop(cmux_hang_watch::watch(Duration::from_secs(5)));
    let before = allocations();
    for _ in 0..1_000 {
        let scope = cmux_hang_watch::watch(Duration::from_secs(5));
        cmux_hang_watch::invalidate_active();
        drop(scope);
    }
    assert_eq!(allocations() - before, 0, "the process path allocates nothing either");

    let scope = cmux_hang_watch::watch(Duration::from_millis(100));
    let path = dir.join(cmux_hang_watch::file_name(std::process::id()));
    assert!(
        wait_until(Duration::from_secs(3), || path.exists()),
        "the hang reaches hangs-<pid>.jsonl"
    );
    drop(scope);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("\"thread\":\"main\""), "{text}");
    assert_eq!(cmux_hang_watch::stats().unwrap().hangs, 1);

    drop(guard);
    assert!(!cmux_hang_watch::watch(Duration::from_secs(1)).is_watching(), "unregistered again");
    let _ = std::fs::remove_dir_all(&dir);
}
