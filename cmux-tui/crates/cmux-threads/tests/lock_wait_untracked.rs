//! Holder tracking off (a release daemon that does not record): an
//! uncontended acquisition publishes nothing, so its fast path is the try
//! and one relaxed load of a global. Holder tracking is process-wide, so
//! these tests get their own binary.

use std::panic::Location;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_threads::{LockHolder, lock_waits, set_holder_tracking};

#[test]
fn an_untracked_acquisition_publishes_no_holder() {
    set_holder_tracking(false);
    let lock = Mutex::new(());
    let holder = LockHolder::default();
    drop(holder.lock_mutex("untracked.fast", Location::caller(), &lock));
    assert_eq!(holder.holder(), None, "no name was written");
}

#[test]
fn an_untracked_long_wait_is_recorded_without_a_holder() {
    set_holder_tracking(false);
    let shared = Arc::new((Mutex::new(()), LockHolder::default()));
    let guard = shared.0.lock().expect("lock");
    let waiter = {
        let shared = Arc::clone(&shared);
        std::thread::Builder::new()
            .name("untracked-waiter".into())
            .spawn(move || {
                drop(shared.1.lock_mutex("untracked.wait", Location::caller(), &shared.0));
            })
            .expect("spawn waiter")
    };
    while shared.1.waiting() == 0 {
        std::thread::yield_now();
    }
    std::thread::sleep(Duration::from_millis(20));
    drop(guard);
    waiter.join().expect("waiter");
    let waits = lock_waits();
    let wait = waits.newest("untracked.wait").expect("the wait is recorded");
    assert_eq!(wait.holder, None);
    assert_eq!(wait.waiter, "untracked-waiter");
}

/// One acquisition in its own frame, so the loop cannot hoist the load.
#[inline(never)]
fn holder_acquire(holder: &LockHolder, lock: &Mutex<()>, site: &'static Location<'static>) {
    drop(holder.lock_mutex("untracked.bench", site, lock));
}

#[inline(never)]
fn bare_try(lock: &Mutex<()>) {
    drop(lock.try_lock());
}

/// Best of five runs of `CALLS` calls of `f`, in ns per call.
fn ns_per_call(mut f: impl FnMut()) -> f64 {
    const CALLS: u32 = 2_000_000;
    (0..5)
        .map(|_| {
            let start = Instant::now();
            for _ in 0..CALLS {
                f();
            }
            start.elapsed().as_secs_f64() * 1e9 / f64::from(CALLS)
        })
        .fold(f64::INFINITY, f64::min)
}

/// The uncontended `LockHolder` path costs < 5 ns over a bare `try_lock` in
/// the optimized build the daemon ships (`cargo test --release`).
#[test]
#[cfg_attr(debug_assertions, ignore = "timing bound holds for --release")]
fn the_untracked_fast_path_is_a_try_plus_under_five_ns() {
    set_holder_tracking(false);
    let lock = Mutex::new(());
    let holder = LockHolder::default();
    let site = Location::caller();
    let bare = ns_per_call(|| bare_try(std::hint::black_box(&lock)));
    let held = ns_per_call(|| holder_acquire(&holder, std::hint::black_box(&lock), site));
    eprintln!("lock fast path: bare try {bare:.2} ns, LockHolder {held:.2} ns");
    assert!(held - bare < 5.0, "LockHolder adds {:.2} ns", held - bare);
}
