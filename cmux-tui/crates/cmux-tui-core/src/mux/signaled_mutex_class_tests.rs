//! Lock admission by class (`server::priority_gate`) on the registry lock,
//! the registry connection lock and the mux state lock.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use super::SignaledMutex;
use crate::diagnostics::LockClassesSnapshot;
use crate::event_cause::{EventCause, EventCauseScope};
use crate::server::priority_gate::AUTOMATION_ADMIT_GAP;
use crate::{Mux, SurfaceOptions};

const AUTOMATION_THREADS: usize = 32;
const HOLD: Duration = Duration::from_micros(200);

/// Hold a lock for `duration` without leaving the CPU, as a short critical
/// section does.
fn hold_for(duration: Duration) {
    let until = Instant::now() + duration;
    while Instant::now() < until {
        std::hint::spin_loop();
    }
}

fn test_mux() -> Arc<Mux> {
    Mux::new("signaled-mutex-class", SurfaceOptions::default())
}

/// 32 automation threads keep `lock` busy; a frontend request then counts
/// the automation critical sections that began after it asked. With the
/// gate it gets the lock at the next release, so at most one begins (the
/// one that may start while it registers as waiting); without it the
/// frontend queues behind the automation threads already waiting.
fn frontend_acquires_within_one_critical_section<G>(
    lock: &(dyn Fn() -> G + Sync),
    class_stats: &(dyn Fn() -> LockClassesSnapshot + Sync),
) {
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
                let before = sections.load(Ordering::SeqCst);
                let guard = lock();
                overtakes.push(sections.load(Ordering::SeqCst) - before);
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
    let worst = overtakes.iter().copied().max().unwrap_or_default();
    // One section may begin while the frontend registers, one more in the
    // race of a release with an automation attempt that already passed its
    // check; never the queue of 32.
    assert!(worst <= 2, "automation sections begun while the frontend waited: {overtakes:?}");
    let within_one = overtakes.iter().filter(|count| **count <= 1).count();
    assert!(within_one * 10 >= overtakes.len() * 9, "{overtakes:?}");
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
/// in at least every [`AUTOMATION_ADMIT_GAP`], behind at most the frontends
/// already queued when its turn came.
#[test]
fn signaled_mutex_class_automation_is_admitted_every_gap_under_frontend_load() {
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
    // The gap, then the frontends queued ahead and the one holding (alone
    // on a quiet machine every gap is about 5.3 ms).
    let bound =
        AUTOMATION_ADMIT_GAP + FRONTEND_HOLD * (FRONTENDS as u32 + 1) + Duration::from_millis(3);
    let over: Vec<&Duration> = gaps.iter().filter(|gap| **gap > bound).collect();
    assert!(admissions.len() >= 30, "automation starved: {} admissions", admissions.len());
    // A preempted thread (tests run in parallel) may miss one turn; without
    // the gate automation waits the whole 300 ms.
    assert!(over.len() * 50 <= gaps.len(), "admit gaps over {bound:?}: {over:?}");
    assert!(
        over.iter().all(|gap| **gap < Duration::from_millis(50)),
        "admit gaps over {bound:?}: {over:?}"
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
