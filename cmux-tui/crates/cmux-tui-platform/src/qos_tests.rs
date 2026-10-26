//! Request QoS and the lock-holder boost (p06-scheduler-035). Each test runs
//! on its own thread: the scopes are thread-local and change its QoS.
//!
//! On Linux an unprivileged thread cannot take back a lowering, so UTILITY
//! is refused there (and under `nice`): the tests then check that nothing
//! changed. On macOS every class applies.

use super::*;
use std::hint::black_box;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex, mpsc};
use std::time::{Duration, Instant};

/// The calling thread's class as `qos_class_self()` reports it.
#[cfg(target_vendor = "apple")]
fn live() -> Option<ThreadQos> {
    // The class is read as its `u32` repr: the kernel may report a class
    // `libc::qos_class_t` has no variant for (QOS_CLASS_MAINTENANCE).
    unsafe extern "C" {
        #[link_name = "qos_class_self"]
        fn qos_class_self_raw() -> u32;
    }
    // SAFETY: qos_class_self has no preconditions and returns a plain value.
    let raw = unsafe { qos_class_self_raw() };
    ThreadQos::from_qos_class(raw)
}

/// The calling thread's nice value: what a class sets on Linux.
#[cfg(not(target_vendor = "apple"))]
fn live() -> cmux_threads::LiveQos {
    cmux_threads::current()
}

/// What [`live`] reads for a thread running at `qos`.
#[cfg(target_vendor = "apple")]
fn at(qos: ThreadQos) -> Option<ThreadQos> {
    Some(qos)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn at(qos: ThreadQos) -> cmux_threads::LiveQos {
    cmux_threads::LiveQos::Nice(qos.linux_nice())
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
fn at(_qos: ThreadQos) -> cmux_threads::LiveQos {
    cmux_threads::LiveQos::Unknown
}

fn on_own_thread(test: impl FnOnce() + Send + 'static) {
    std::thread::spawn(test).join().expect("test thread");
}

#[test]
fn qos_request_class_is_set_for_the_scope_and_restored() {
    for qos in [ThreadQos::Utility, ThreadQos::UserInitiated] {
        on_own_thread(move || {
            let before = live();
            {
                let scope = WorkQos::enter(qos);
                #[cfg(target_vendor = "apple")]
                assert!(scope.applied(), "{qos}: macOS takes every class");
                if scope.applied() {
                    assert_eq!(live(), at(qos), "{qos}");
                    assert_eq!(work_qos(), Some(qos));
                } else {
                    assert_eq!(live(), before, "{qos}: a refused class changes nothing");
                    assert_eq!(work_qos(), None);
                }
                // The same class nested changes nothing.
                let nested = WorkQos::enter(qos);
                assert!(!nested.applied());
                drop(nested);
                assert_eq!(work_qos(), scope.applied().then_some(qos));
            }
            assert_eq!(live(), before, "{qos}: restored");
            assert_eq!(work_qos(), None);
        });
    }
}

#[test]
fn qos_lock_boost_raises_a_utility_holder_until_its_outermost_release() {
    on_own_thread(|| {
        let request = WorkQos::enter(ThreadQos::Utility);
        let lowered = request.applied();
        let outer = LockBoost::hold();
        assert_eq!(boosted(), lowered);
        if lowered {
            assert_eq!(live(), at(LOCK_HOLDER_QOS), "raised while the lock is held");
        }
        let inner = LockBoost::hold();
        drop(inner);
        assert_eq!(boosted(), lowered, "an inner release keeps the raise");
        if lowered {
            assert_eq!(live(), at(LOCK_HOLDER_QOS));
        }
        drop(outer);
        assert!(!boosted());
        if lowered {
            assert_eq!(live(), at(ThreadQos::Utility), "back to the request's class");
        }
        assert_eq!(work_qos(), lowered.then_some(ThreadQos::Utility));
    });
}

#[test]
fn qos_lock_boost_leaves_frontend_and_program_threads_alone() {
    on_own_thread(|| {
        // Outside every request: the thread keeps its own class.
        let before = live();
        let boost = LockBoost::hold();
        assert!(!boosted());
        assert_eq!(live(), before);
        drop(boost);

        let request = WorkQos::enter(ThreadQos::UserInitiated);
        let boost = LockBoost::hold();
        assert!(!boosted(), "a USER_INITIATED holder needs no raise");
        if request.applied() {
            assert_eq!(live(), at(ThreadQos::UserInitiated));
        }
        drop(boost);
    });
}

#[test]
fn qos_request_entered_under_a_held_lock_changes_nothing() {
    on_own_thread(|| {
        let before = live();
        let boost = LockBoost::hold();
        let request = WorkQos::enter(ThreadQos::Utility);
        assert!(!request.applied(), "a lock holder is never lowered");
        assert_eq!(work_qos(), None);
        assert_eq!(live(), before);
        drop(request);
        drop(boost);
        // A rank that is no lock does not count as one.
        let not_a_lock = LockBoost::none();
        let request = WorkQos::enter(ThreadQos::Utility);
        assert_eq!(work_qos(), request.applied().then_some(ThreadQos::Utility));
        drop(request);
        drop(not_a_lock);
        assert_eq!(live(), before);
    });
}

/// CPU work with no lock, no allocation and no system call.
fn spin(iterations: u64) -> u64 {
    let mut x = 0x9e37_79b9_7f4a_7c15_u64;
    for i in 0..iterations {
        x = black_box(x.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(i));
    }
    x
}

/// Iterations of [`spin`] that take about `target` on an idle core.
fn calibrate(target: Duration) -> (u64, Duration) {
    let probe = 1_000_000;
    let started = Instant::now();
    black_box(spin(probe));
    let per_probe = started.elapsed().max(Duration::from_micros(1));
    let iterations = (probe as f64 * target.as_secs_f64() / per_probe.as_secs_f64()) as u64;
    let started = Instant::now();
    black_box(spin(iterations));
    (iterations, started.elapsed())
}

#[test]
fn qos_frontend_request_behind_a_utility_holder_waits_one_critical_section() {
    let (iterations, uncontended) = calibrate(Duration::from_millis(10));
    // Every core busy at the default class: a UTILITY thread would lose its
    // core to them, a raised holder keeps it.
    let spinners = std::thread::available_parallelism().map_or(4, |n| n.get()).min(64);
    let stop = Arc::new(AtomicBool::new(false));
    let running = Arc::new(AtomicUsize::new(0));
    let mut threads = Vec::new();
    for _ in 0..spinners {
        let (stop, running) = (stop.clone(), running.clone());
        threads.push(std::thread::spawn(move || {
            running.fetch_add(1, Ordering::AcqRel);
            while !stop.load(Ordering::Acquire) {
                black_box(spin(10_000));
            }
        }));
    }
    while running.load(Ordering::Acquire) < spinners {
        std::thread::yield_now();
    }

    let lock = Arc::new(Mutex::new(()));
    let ready = Arc::new(Barrier::new(2));
    let (held_tx, held_rx) = mpsc::sync_channel(1);
    let holder = {
        let (lock, ready) = (lock.clone(), ready.clone());
        std::thread::spawn(move || {
            let request = WorkQos::enter(ThreadQos::Utility);
            ready.wait();
            let guard = lock.lock().expect("lock");
            let boost = LockBoost::hold();
            let raised = boosted();
            held_tx.send(()).expect("held");
            let started = Instant::now();
            black_box(spin(iterations));
            let hold = started.elapsed();
            drop(guard);
            drop(boost);
            (request.applied(), raised, hold)
        })
    };
    let frontend = std::thread::spawn(move || {
        let _request = WorkQos::enter(ThreadQos::UserInitiated);
        ready.wait();
        held_rx.recv().expect("holder took the lock");
        let started = Instant::now();
        drop(lock.lock().expect("lock"));
        started.elapsed()
    });
    let (lowered, raised, hold) = holder.join().expect("holder");
    let waited = frontend.join().expect("frontend");
    stop.store(true, Ordering::Release);
    for thread in threads {
        thread.join().expect("spinner");
    }

    assert_eq!(raised, lowered, "a lowered holder is raised while it holds the lock");
    // The frontend gets the lock when the one critical section ahead of it
    // ends.
    assert!(
        waited <= hold + Duration::from_millis(50),
        "waited {waited:?} behind a hold of {hold:?}"
    );
    if lowered {
        // Raised above the spinners, the holder's section takes about its
        // idle time, not the time a starved UTILITY thread takes.
        assert!(
            waited <= uncontended * 4 + Duration::from_millis(20),
            "waited {waited:?}; the section takes {uncontended:?} on an idle core"
        );
    }
}
