use std::sync::atomic::{AtomicU64, Ordering};

use super::*;

const STALL: Duration = Duration::from_millis(3_000);
const TEST_WINDOW: Duration = Duration::from_millis(1_000);
const TEST_READ: Duration = Duration::from_millis(100);
const TICK: Duration = Duration::from_millis(50);

static WORKING_CPU_US: AtomicU64 = AtomicU64::new(0);
static TRICKLE_CPU_US: AtomicU64 = AtomicU64::new(0);

fn working(_pid: u32) -> Option<Work> {
    let cpu = Duration::from_micros(WORKING_CPU_US.load(Ordering::SeqCst));
    Some(Work { cpu, disk_bytes: 0 })
}

fn trickle(_pid: u32) -> Option<Work> {
    let cpu = Duration::from_micros(TRICKLE_CPU_US.load(Ordering::SeqCst));
    Some(Work { cpu, disk_bytes: 0 })
}

fn no_counters(_pid: u32) -> Option<Work> {
    None
}

/// Advances `counter` by `per_mille` of each tick of wall time until
/// `until`, asserting `check` at every tick.
fn run(counter: &AtomicU64, per_mille: u64, until: Duration, check: impl Fn(Duration)) {
    let started = Instant::now();
    while started.elapsed() < until {
        std::thread::sleep(TICK);
        let tick = u64::try_from(TICK.as_micros()).unwrap();
        counter.fetch_add(tick * per_mille / 1000, Ordering::SeqCst);
        check(started.elapsed());
    }
}

#[test]
fn a_working_owner_keeps_the_wait_past_the_stall_bound_and_a_stalled_one_ends_it() {
    let started = Instant::now();
    let bound = RestoreBound::with(started, STALL, TEST_WINDOW, TEST_READ, working);
    bound.note_owner(Some(42));
    // A full core for twice the stall bound.
    run(&WORKING_CPU_US, 1000, STALL * 2, |at| {
        assert!(!bound.expired(), "a working owner timed out at {at:?}");
    });
    // Then no work: the wait ends about one stall bound after the last
    // window that held work.
    let stalled = Instant::now();
    while !bound.expired() {
        assert!(stalled.elapsed() < STALL + TEST_WINDOW * 2, "a stalled owner kept the wait");
        std::thread::sleep(TICK);
    }
    assert!(stalled.elapsed() + TEST_WINDOW >= STALL, "ended early: {:?}", stalled.elapsed());
}

#[test]
fn a_steady_trickle_of_idle_cpu_never_counts_as_progress() {
    let started = Instant::now();
    let bound = RestoreBound::with(started, STALL, TEST_WINDOW, TEST_READ, trickle);
    bound.note_owner(Some(42));
    // 2% of a core, all along (20 ms/s): idle threads, not a restore. It
    // adds up to well over a window's threshold over the run, but no
    // single window holds enough.
    let expired_at = Cell::new(None);
    run(&TRICKLE_CPU_US, 20, STALL + TEST_WINDOW * 2, |at| {
        if expired_at.get().is_none() && bound.expired() {
            expired_at.set(Some(at));
        }
    });
    let at = expired_at.get().expect("a trickling owner kept the wait");
    assert!(at < STALL + TEST_READ * 3, "the trickle moved the deadline: {at:?}");
}

#[test]
fn the_window_scales_with_a_short_stall_bound() {
    assert_eq!(window_for(RESTORE_DEADLINE), (WINDOW, READ_INTERVAL));
    let (window, read) = window_for(STALL);
    assert_eq!(window, Duration::from_millis(1_000));
    assert_eq!(read, Duration::from_millis(250));
    assert!(window * 3 <= STALL);
}

#[test]
fn idle_threads_are_not_progress() {
    let window = Duration::from_secs(10);
    let earlier = Work { cpu: Duration::from_millis(500), disk_bytes: 10 };
    let idle = Work { cpu: Duration::from_millis(700), disk_bytes: 4_000_000 };
    assert!(!idle.advanced_from(earlier, window));
    let scanning = Work { cpu: Duration::from_millis(1_500), disk_bytes: 10 };
    assert!(scanning.advanced_from(earlier, window));
    let reading = Work { cpu: Duration::from_millis(500), disk_bytes: 10 + 8 * 1024 * 1024 };
    assert!(reading.advanced_from(earlier, window));
}

#[test]
fn without_counters_the_bound_is_fixed() {
    let stall = Duration::from_millis(300);
    let bound = RestoreBound::with(Instant::now(), stall, TEST_WINDOW, TEST_READ, no_counters);
    bound.note_owner(Some(42));
    assert!(!bound.expired());
    std::thread::sleep(stall + Duration::from_millis(50));
    assert!(bound.expired());
}

#[cfg(target_vendor = "apple")]
#[test]
fn this_process_reports_its_own_work() {
    let span = Duration::from_millis(300);
    let work = process_work(std::process::id()).expect("own counters");
    let spin = Instant::now();
    let mut x = 0_u64;
    while spin.elapsed() < span {
        x = std::hint::black_box(x.wrapping_add(1));
    }
    let later = process_work(std::process::id()).expect("own counters");
    assert!(later.advanced_from(work, span), "{work:?} -> {later:?}");
}
