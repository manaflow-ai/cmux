//! Lock admission by class (`server::priority_gate`) on the registry lock,
//! the registry connection lock and the mux state lock.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use super::SignaledMutex;
use crate::diagnostics::LockClassesSnapshot;
use crate::event_cause::{EventCause, EventCauseScope};
use crate::server::priority_gate::{AUTOMATION_ADMIT_GAP, RESERVE_LEAD};
use crate::{Mux, SurfaceOptions};

const AUTOMATION_THREADS: usize = 32;
const HOLD: Duration = Duration::from_micros(200);
/// The longest admit gap a preempted holder may cause on a test machine
/// running other tests in parallel.
const PREEMPTED_GAP: Duration = Duration::from_millis(25);

/// Hold a lock for `duration` without leaving the CPU, as a short critical
/// section does.
fn hold_for(duration: Duration) {
    let until = Instant::now() + duration;
    while Instant::now() < until {
        std::hint::spin_loop();
    }
}

/// The timing tests here each keep 4 to 34 threads spinning; run one at a
/// time so they measure the gate, not each other.
static TIMING: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn timing() -> std::sync::MutexGuard<'static, ()> {
    TIMING.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn test_mux() -> Arc<Mux> {
    Mux::new("signaled-mutex-class", SurfaceOptions::default())
}

/// 32 automation threads keep `lock` busy; a frontend request then counts
/// the automation critical sections that began after it asked. With the
/// gate it gets the lock at the next release, so at most one begins (the
/// one that may start before it registers as waiting); without it the
/// frontend queues behind the automation threads already waiting.
fn frontend_acquires_within_one_critical_section<G>(
    lock: &(dyn Fn() -> G + Sync),
    class_stats: &(dyn Fn() -> LockClassesSnapshot + Sync),
) {
    let _timing = timing();
    let stop = AtomicBool::new(false);
    let sections = AtomicU64::new(0);
    let overtakes = std::thread::scope(|scope| {
        for _ in 0..AUTOMATION_THREADS {
            scope.spawn(|| {
                let _cause = EventCauseScope::enter(EventCause::Automation);
                while !stop.load(Ordering::Relaxed) {
                    let guard = lock();
                    sections.fetch_add(1, Ordering::SeqCst);
                    hold_for(HOLD);
                    drop(guard);
                }
            });
        }
        let frontend = scope.spawn(|| {
            let _cause = EventCauseScope::enter(EventCause::Frontend);
            // Let the automation threads pile up on the lock first.
            std::thread::sleep(Duration::from_millis(30));
            let mut overtakes = Vec::new();
            for _ in 0..40 {
                let asked = Instant::now();
                let before = sections.load(Ordering::SeqCst);
                let guard = lock();
                overtakes.push((sections.load(Ordering::SeqCst) - before, asked.elapsed()));
                hold_for(HOLD);
                drop(guard);
                std::thread::sleep(Duration::from_millis(2));
            }
            overtakes
        });
        let overtakes = frontend.join().unwrap();
        stop.store(true, Ordering::Relaxed);
        overtakes
    });
    // Only the hold it found (its count may land after the frontend read
    // it): an automation caller that gets the lock while the frontend waits
    // gives it back. A frontend that waits past automation's due admission
    // (its holder preempted on a loaded machine) also lets that one
    // reserved admission in, automation's bounded share. Never the queue of
    // 32.
    let due = AUTOMATION_ADMIT_GAP - RESERVE_LEAD;
    let over: Vec<&(u64, Duration)> =
        overtakes.iter().filter(|(count, waited)| *count > 1 + u64::from(*waited >= due)).collect();
    assert!(over.is_empty(), "automation sections begun while the frontend waited: {over:?}");
    let stats = class_stats();
    assert!(stats.frontend.wait_us.count >= 40, "{stats:?}");
    assert!(stats.automation.wait_us.count > 0, "{stats:?}");
    assert!(stats.automation_yields > 0, "{stats:?}");
}

#[test]
fn signaled_mutex_class_frontend_overtakes_automation_on_the_registry_lock() {
    let mutex = SignaledMutex::new(0u64);
    frontend_acquires_within_one_critical_section(&|| mutex.lock().unwrap(), &|| {
        mutex.class_stats()
    });
}

#[test]
fn signaled_mutex_class_frontend_overtakes_automation_on_the_state_lock() {
    let mux = test_mux();
    frontend_acquires_within_one_critical_section(&|| mux.state.lock().unwrap(), &|| {
        mux.lock_class_stats().state
    });
}

#[test]
fn signaled_mutex_class_frontend_overtakes_automation_on_the_registry_connection() {
    let mux = test_mux();
    frontend_acquires_within_one_critical_section(&|| mux.registry_connection.get(), &|| {
        mux.lock_class_stats().registry_connection
    });
}

/// Frontend callers keep the lock busy back to back; automation still gets
/// in at least every [`AUTOMATION_ADMIT_GAP`].
#[test]
fn signaled_mutex_class_automation_is_admitted_every_gap_under_frontend_load() {
    let _timing = timing();
    const FRONTENDS: usize = 4;
    const FRONTEND_HOLD: Duration = Duration::from_micros(300);
    let mutex = SignaledMutex::new(Vec::<Instant>::new());
    let stop = AtomicBool::new(false);
    std::thread::scope(|scope| {
        for _ in 0..FRONTENDS {
            scope.spawn(|| {
                let _cause = EventCauseScope::enter(EventCause::Frontend);
                while !stop.load(Ordering::Relaxed) {
                    let guard = mutex.lock().unwrap();
                    hold_for(FRONTEND_HOLD);
                    drop(guard);
                }
            });
        }
        for _ in 0..8 {
            scope.spawn(|| {
                let _cause = EventCauseScope::enter(EventCause::Automation);
                while !stop.load(Ordering::Relaxed) {
                    let mut guard = mutex.lock().unwrap();
                    guard.push(Instant::now());
                    hold_for(Duration::from_micros(50));
                    drop(guard);
                }
            });
        }
        std::thread::sleep(Duration::from_millis(300));
        stop.store(true, Ordering::Relaxed);
    });
    let admissions = std::mem::take(&mut *mutex.lock().unwrap());
    let gaps: Vec<Duration> =
        admissions.windows(2).map(|pair| pair[1].duration_since(pair[0])).collect();
    // The reservation is taken before the admission is due, so the holder
    // and the frontends queued ahead drain inside the gap: about 2.2 to
    // 3.3 ms on a quiet machine.
    assert!(admissions.len() >= 60, "automation starved: {} admissions", admissions.len());
    let over_gap: Vec<&Duration> = gaps.iter().filter(|gap| **gap > AUTOMATION_ADMIT_GAP).collect();
    // The p90 gap is within the 4 ms. The rest are a holder preempted on a
    // machine running the other tests in parallel; without the gate
    // automation waits the whole 300 ms.
    assert!(
        over_gap.len() * 10 <= gaps.len(),
        "admit gaps over {AUTOMATION_ADMIT_GAP:?}: {over_gap:?} of {}",
        gaps.len()
    );
    assert!(
        over_gap.iter().all(|gap| **gap <= PREEMPTED_GAP),
        "admit gaps over {PREEMPTED_GAP:?}: {over_gap:?}"
    );
    let stats = mutex.class_stats();
    assert!(stats.automation_due_admissions > 0, "{stats:?}");
}

/// An automation caller that holds a ranked lock never yields: it could
/// hold up the very frontend request it would yield to.
#[test]
fn signaled_mutex_class_automation_holding_a_rank_never_yields() {
    let mux = test_mux();
    let (held, held_rx) = std::sync::mpsc::sync_channel::<()>(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel::<()>(0);
    std::thread::scope(|scope| {
        let mux = &mux;
        let holder = scope.spawn(move || {
            let _state = mux.state.lock().unwrap();
            held.send(()).unwrap();
            release_rx.recv().unwrap();
        });
        held_rx.recv().unwrap();
        let frontend = scope.spawn(|| {
            let _cause = EventCauseScope::enter(EventCause::Frontend);
            drop(mux.state.lock().unwrap());
        });
        let automation = scope.spawn(|| {
            let _cause = EventCauseScope::enter(EventCause::Automation);
            let registry = mux.workspace_registry.lock().unwrap();
            drop(mux.lock_state_pinned(&registry).unwrap());
        });
        // Let both queue on the held state lock, the frontend counted as
        // waiting while the automation flow (holding the registry) arrives.
        std::thread::sleep(Duration::from_millis(50));
        release.send(()).unwrap();
        holder.join().unwrap();
        frontend.join().unwrap();
        automation.join().unwrap();
    });
    let stats = mux.lock_class_stats();
    assert_eq!(stats.state.automation_yields, 0, "{:?}", stats.state);
    assert_eq!(stats.registry_connection.automation_yields, 0, "{:?}", stats.registry_connection);
    assert!(stats.state.automation.wait_us.count >= 1, "{:?}", stats.state);
    assert!(stats.registry.automation.wait_us.count >= 1, "{:?}", stats.registry);
}

/// 10k acquisitions across every lock order path and class finish: the
/// gate adds no deadlock (a yielding caller holds no ranked lock, and every
/// release wakes the callers waiting on the gate).
#[test]
fn signaled_mutex_class_stress_has_no_deadlock() {
    let _timing = timing();
    const THREADS: usize = 16;
    const ITERATIONS: usize = 10_000 / THREADS;
    let mux = test_mux();
    let (done, done_rx) = std::sync::mpsc::channel::<()>();
    let worker_mux = mux.clone();
    let stress = std::thread::spawn(move || {
        let mux = &worker_mux;
        std::thread::scope(|scope| {
            for thread in 0..THREADS {
                scope.spawn(move || {
                    let cause = match thread % 3 {
                        0 => EventCause::Frontend,
                        1 => EventCause::Automation,
                        _ => EventCause::Program,
                    };
                    let _cause = EventCauseScope::enter(cause);
                    for iteration in 0..ITERATIONS {
                        match (thread + iteration) % 4 {
                            0 => {
                                let registry = mux.workspace_registry.lock().unwrap();
                                let state = mux.lock_state_pinned(&registry).unwrap();
                                hold_for(Duration::from_micros(20));
                                drop(state);
                            }
                            1 => {
                                let state = mux.state.lock().unwrap();
                                hold_for(Duration::from_micros(20));
                                drop(state);
                            }
                            2 => {
                                let connection = mux.registry_connection.get();
                                hold_for(Duration::from_micros(20));
                                drop(connection);
                            }
                            _ => {
                                let registry = mux.workspace_registry.lock().unwrap();
                                let connection = mux.registry_connection.get();
                                hold_for(Duration::from_micros(20));
                                drop(connection);
                                drop(registry);
                            }
                        }
                    }
                });
            }
        });
        done.send(()).unwrap();
    });
    done_rx
        .recv_timeout(Duration::from_secs(120))
        .expect("10k gated acquisitions did not finish: a lock admission deadlock");
    stress.join().unwrap();
    let stats = mux.lock_class_stats();
    let acquisitions = |classes: &LockClassesSnapshot| {
        classes.frontend.wait_us.count
            + classes.program.wait_us.count
            + classes.automation.wait_us.count
    };
    assert!(acquisitions(&stats.state) >= 5_000, "{:?}", stats.state);
    assert!(acquisitions(&stats.registry) >= 5_000, "{:?}", stats.registry);
}

/// `server-stats` `lock_classes` names each class's wait p95.
#[test]
fn signaled_mutex_class_stats_serialize_the_wait_p95() {
    let mux = test_mux();
    {
        let _cause = EventCauseScope::enter(EventCause::Frontend);
        drop(mux.state.lock().unwrap());
    }
    let value = serde_json::to_value(mux.lock_class_stats()).unwrap();
    for lock in ["registry", "registry_connection", "state"] {
        for class in ["frontend", "program", "automation"] {
            assert!(value[lock][class]["wait_p95_us"].is_u64(), "{lock}.{class}: {value}");
        }
    }
    assert!(value["state"]["frontend"]["wait_us"]["count"].as_u64().unwrap() >= 1, "{value}");
}

/// A Program hold far longer than the admit gap, a frontend and 16
/// automation callers waiting: one automation admission is reserved at a
/// time (the gate keeps one flag, not a count), so a frontend that asks late
/// in the hold gets the lock behind at most one automation critical section
/// after the release.
#[test]
fn signaled_mutex_class_a_long_hold_reserves_one_admission() {
    let _timing = timing();
    const PROGRAM_HOLD: Duration = Duration::from_millis(60);
    const AUTOMATION_HOLD: Duration = Duration::from_millis(1);
    let mutex = SignaledMutex::new(());
    let stop = AtomicBool::new(false);
    let sections = AtomicU64::new(0);
    let (held, held_rx) = std::sync::mpsc::sync_channel::<()>(0);
    let (late_overtakes, since_release) = std::thread::scope(|scope| {
        let program = scope.spawn(|| {
            let guard = mutex.lock().unwrap();
            held.send(()).unwrap();
            std::thread::sleep(PROGRAM_HOLD);
            drop(guard);
            Instant::now()
        });
        held_rx.recv().unwrap();
        scope.spawn(|| {
            let _cause = EventCauseScope::enter(EventCause::Frontend);
            drop(mutex.lock().unwrap());
        });
        for _ in 0..16 {
            scope.spawn(|| {
                let _cause = EventCauseScope::enter(EventCause::Automation);
                while !stop.load(Ordering::Relaxed) {
                    let guard = mutex.lock().unwrap();
                    sections.fetch_add(1, Ordering::SeqCst);
                    hold_for(AUTOMATION_HOLD);
                    drop(guard);
                }
            });
        }
        let late = scope.spawn(|| {
            let _cause = EventCauseScope::enter(EventCause::Frontend);
            std::thread::sleep(PROGRAM_HOLD * 2 / 3);
            let before = sections.load(Ordering::SeqCst);
            drop(mutex.lock().unwrap());
            (sections.load(Ordering::SeqCst) - before, Instant::now())
        });
        let released = program.join().unwrap();
        let (late_overtakes, acquired) = late.join().unwrap();
        stop.store(true, Ordering::Relaxed);
        (late_overtakes, acquired.saturating_duration_since(released))
    });
    // The one reserved admission. A late frontend that the machine does not
    // run until a later admission comes due (one every
    // AUTOMATION_ADMIT_GAP - RESERVE_LEAD after the last) concedes that one
    // too, automation's bounded share; never the 16 callers that waited
    // through the hold.
    let due = AUTOMATION_ADMIT_GAP - RESERVE_LEAD;
    let allowed = 1 + u64::try_from(since_release.as_nanos() / due.as_nanos()).unwrap_or(u64::MAX);
    assert!(
        late_overtakes <= allowed,
        "the late frontend waited behind {late_overtakes} automation holds, \
         {since_release:?} after the release"
    );
    assert!(mutex.class_stats().automation_due_admissions >= 1);
}

/// A frontend flow that holds the registry never waits behind an automation
/// reservation on the state lock (nothing waits while a rank is held); one
/// that holds no rank does.
#[test]
fn signaled_mutex_class_a_frontend_holding_a_rank_never_waits_behind_a_reservation() {
    let mux = test_mux();
    let reservation = mux.state.gate.reserve_for_test();
    let (ranked_done, ranked_rx) = std::sync::mpsc::channel::<()>();
    let (free_done, free_rx) = std::sync::mpsc::channel::<()>();
    std::thread::scope(|scope| {
        let mux = &mux;
        scope.spawn(move || {
            let _cause = EventCauseScope::enter(EventCause::Frontend);
            let registry = mux.workspace_registry.lock().unwrap();
            drop(mux.lock_state_pinned(&registry).unwrap());
            ranked_done.send(()).unwrap();
        });
        ranked_rx
            .recv_timeout(Duration::from_secs(10))
            .expect("a frontend holding the registry waited behind the reservation");
        scope.spawn(move || {
            let _cause = EventCauseScope::enter(EventCause::Frontend);
            drop(mux.state.lock().unwrap());
            free_done.send(()).unwrap();
        });
        assert!(
            free_rx.recv_timeout(Duration::from_millis(100)).is_err(),
            "a frontend holding no rank waits behind the reservation"
        );
        drop(reservation);
        free_rx.recv_timeout(Duration::from_secs(10)).expect("the reservation's end wakes it");
    });
}

/// With no frontend waiting, each release wakes one parked automation
/// caller, not all of them.
#[test]
fn signaled_mutex_class_a_release_wakes_one_automation_caller() {
    let _timing = timing();
    const THREADS: usize = 32;
    const PER_THREAD: u64 = 100;
    let mutex = SignaledMutex::new(());
    std::thread::scope(|scope| {
        for _ in 0..THREADS {
            scope.spawn(|| {
                let _cause = EventCauseScope::enter(EventCause::Automation);
                for _ in 0..PER_THREAD {
                    let guard = mutex.lock().unwrap();
                    hold_for(Duration::from_micros(50));
                    drop(guard);
                }
            });
        }
    });
    let acquisitions = THREADS as u64 * PER_THREAD;
    let wakeups = mutex.gate.wakeups();
    assert!(wakeups <= acquisitions * 2, "{wakeups} wakeups for {acquisitions} acquisitions");
}

/// A deadline wait on a poisoned lock fails at once: dropping the poisoned
/// guard wakes the gate while the waiter holds none of its locks.
#[test]
fn signaled_mutex_class_a_deadline_wait_on_a_poisoned_lock_returns() {
    let mutex = Arc::new(SignaledMutex::new(()));
    let poisoner = Arc::clone(&mutex);
    std::thread::spawn(move || {
        let _guard = poisoner.lock().unwrap();
        panic!("poison the lock");
    })
    .join()
    .unwrap_err();
    let (done, done_rx) = std::sync::mpsc::channel();
    let waiter = Arc::clone(&mutex);
    std::thread::spawn(move || {
        let result = waiter.lock_until(Instant::now() + Duration::from_secs(1)).map(drop);
        done.send(result.is_err()).unwrap();
    });
    let failed =
        done_rx.recv_timeout(Duration::from_secs(10)).expect("the deadline wait hung on poison");
    assert!(failed, "a poisoned lock is an error");
}

/// The registry connection keeps its lock-wait record around admission: a
/// frontend queued on the lock and an automation caller the gate keeps out
/// are both contended waiters of its `LockHolder`.
#[test]
fn signaled_mutex_class_connection_waits_keep_the_holder_record() {
    let mux = test_mux();
    let connection = Arc::clone(&mux.registry_connection);
    let (held, held_rx) = std::sync::mpsc::sync_channel::<()>(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel::<()>(0);
    std::thread::scope(|scope| {
        let connection = &connection;
        let holder = scope.spawn(move || {
            let pin = connection.pin();
            held.send(()).unwrap();
            release_rx.recv().unwrap();
            drop(pin);
        });
        held_rx.recv().unwrap();
        let frontend = scope.spawn(|| {
            let _cause = EventCauseScope::enter(EventCause::Frontend);
            drop(connection.get());
        });
        while connection.lock_waiting() < 1 {
            std::thread::yield_now();
        }
        let automation = scope.spawn(|| {
            let _cause = EventCauseScope::enter(EventCause::Automation);
            drop(connection.get());
        });
        while connection.lock_waiting() < 2 {
            std::thread::yield_now();
        }
        release.send(()).unwrap();
        holder.join().unwrap();
        frontend.join().unwrap();
        automation.join().unwrap();
    });
    assert_eq!(connection.lock_waiting(), 0);
    let stats = connection.class_stats();
    assert_eq!(stats.frontend.wait_us.count, 1, "{stats:?}");
    assert_eq!(stats.automation.wait_us.count, 1, "{stats:?}");
}

/// A re-entry of the connection lock under a pin frees nothing, so its
/// release wakes no waiter; the pin's release does.
#[test]
fn signaled_mutex_class_a_reentry_release_wakes_nobody() {
    let mux = test_mux();
    let connection = Arc::clone(&mux.registry_connection);
    let (held, held_rx) = std::sync::mpsc::sync_channel::<()>(0);
    let (release, release_rx) = std::sync::mpsc::sync_channel::<()>(0);
    std::thread::scope(|scope| {
        let connection = &connection;
        let holder = scope.spawn(move || {
            let pin = connection.pin();
            held.send(()).unwrap();
            release_rx.recv().unwrap();
            for _ in 0..1_000 {
                drop(connection.get());
            }
            let wakeups = connection.gate_wakeups();
            drop(pin);
            wakeups
        });
        held_rx.recv().unwrap();
        let waiter = scope.spawn(|| {
            let _cause = EventCauseScope::enter(EventCause::Automation);
            drop(connection.get());
        });
        while connection.lock_waiting() < 1 {
            std::thread::yield_now();
        }
        let before = connection.gate_wakeups();
        release.send(()).unwrap();
        let during = holder.join().unwrap();
        waiter.join().unwrap();
        assert_eq!(during, before, "1000 re-entry releases woke the parked waiter");
    });
}
