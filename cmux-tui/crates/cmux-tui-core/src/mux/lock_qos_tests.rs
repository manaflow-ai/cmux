//! Every ranked lock raises an automation request's thread before it waits
//! for the lock and while it holds it (crate::lock_rank
//! `raises_holder`, cmux_tui_platform::qos). Where the platform cannot take
//! UTILITY back (Linux without `RLIMIT_NICE`) nothing is lowered and nothing
//! is raised.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_threads::{LiveQos, ThreadQos};
use cmux_tui_platform::qos::{WorkQos, boosted, work_qos};

use crate::SurfaceOptions;
use crate::event_cause::EventCause;
use crate::lock_rank::{LockRank, RankedMutex};
use crate::mux::Mux;

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("lock-qos-{label}"), SurfaceOptions::default())
}

/// What the kernel reports for a thread running at `qos`: its class on
/// macOS (`pthread_get_qos_class_np`, what `qos_class_self()` returns), its
/// nice value on Linux.
fn live_at(qos: ThreadQos) -> LiveQos {
    #[cfg(target_vendor = "apple")]
    {
        LiveQos::Class(qos)
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        LiveQos::Nice(qos.linux_nice())
    }
    #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
    {
        let _ = qos;
        LiveQos::Unknown
    }
}

/// Asserts the calling thread is raised while it holds `lock`, when its
/// request lowered it.
fn assert_raised(lowered: bool, lock: &str) {
    assert_eq!(boosted(), lowered, "{lock}");
    if lowered {
        assert_eq!(cmux_threads::current(), live_at(ThreadQos::UserInitiated), "{lock}");
    }
}

#[test]
fn qos_request_class_follows_its_cause() {
    assert_eq!(EventCause::Frontend.request_qos(), Some(ThreadQos::UserInitiated));
    assert_eq!(EventCause::Automation.request_qos(), Some(ThreadQos::Utility));
    assert_eq!(EventCause::Program.request_qos(), None);
}

#[test]
fn qos_automation_holder_of_the_state_or_registry_lock_is_raised() {
    let mux = mux("holder");
    std::thread::spawn(move || {
        let request = WorkQos::enter(ThreadQos::Utility);
        let lowered = request.applied();
        if lowered {
            assert_eq!(cmux_threads::current(), live_at(ThreadQos::Utility));
        }

        let state = mux.state.lock().expect("state");
        assert_raised(lowered, "mux.state");
        drop(state);
        assert!(!boosted());

        let registry = mux.workspace_registry.lock().expect("registry");
        assert_raised(lowered, "workspace.registry");
        {
            // Registry, then connection, then state: one raise for all.
            let pinned = mux.lock_state_pinned(&registry).expect("pinned state");
            assert_raised(lowered, "registry.connection and mux.state");
            drop(pinned);
        }
        assert_raised(lowered, "the registry is still held");
        drop(registry);
        assert!(!boosted(), "every lock released");
        assert_eq!(work_qos(), lowered.then_some(ThreadQos::Utility));
        if lowered {
            assert_eq!(cmux_threads::current(), live_at(ThreadQos::Utility), "lowered again");
        }
    })
    .join()
    .expect("holder thread");
}

#[test]
fn qos_automation_holder_of_a_terminal_lock_is_raised() {
    std::thread::spawn(|| {
        let term = RankedMutex::new(LockRank::Terminal, "pty.term", ());
        let request = WorkQos::enter(ThreadQos::Utility);
        let lowered = request.applied();
        let held = term.lock().expect("pty.term");
        assert_raised(lowered, "pty.term");
        drop(held);
        assert!(!boosted());
    })
    .join()
    .expect("terminal thread");
}

#[test]
fn qos_frontend_holder_is_not_raised() {
    let mux = mux("frontend");
    std::thread::spawn(move || {
        let _request = WorkQos::enter(ThreadQos::UserInitiated);
        let state = mux.state.lock().expect("state");
        assert!(!boosted(), "a USER_INITIATED holder needs no raise");
        drop(state);
    })
    .join()
    .expect("frontend thread");
}

/// A UTILITY waiter queued on a lock this thread holds: `take` blocks on the
/// lock in a registered thread named `name`. The waiter must be raised while
/// it still waits, so a lock that hands itself to a parked waiter
/// (parking_lot's eventual fairness, a fair pthread mutex) never hands it to
/// a UTILITY thread that has no CPU. Returns the waiter, to join once the
/// caller released the lock.
fn assert_waiter_raised_before_it_gets_the_lock(
    name: &'static str,
    take: impl FnOnce() + Send + 'static,
) -> std::thread::JoinHandle<()> {
    let got_lock = Arc::new(AtomicBool::new(false));
    let (lowered_tx, lowered_rx) = mpsc::sync_channel(1);
    let waiter = {
        let got_lock = got_lock.clone();
        cmux_threads::spawn(name, ThreadQos::Default, move || {
            let request = WorkQos::enter(ThreadQos::Utility);
            lowered_tx.send(request.applied()).expect("lowered");
            take();
            got_lock.store(true, Ordering::Release);
        })
        .expect("waiter thread")
    };
    let lowered = lowered_rx.recv().expect("the waiter entered its request");
    if lowered {
        let live = || {
            cmux_threads::snapshot().into_iter().find(|row| row.name == name).map(|row| row.live)
        };
        let deadline = Instant::now() + Duration::from_secs(10);
        while live() != Some(live_at(ThreadQos::UserInitiated)) {
            assert!(Instant::now() < deadline, "{name}: the waiter stays at {:?}", live());
            std::thread::yield_now();
        }
        assert!(!got_lock.load(Ordering::Acquire), "{name}: raised while it still waits");
    }
    waiter
}

#[test]
fn qos_utility_waiter_on_the_registry_connection_is_raised_before_it_gets_the_lock() {
    let mux = mux("connection-waiter");
    let pin = mux.registry_connection.pin();
    let waiter =
        assert_waiter_raised_before_it_gets_the_lock("lock-qos-connection-waiter", move || {
            drop(mux.registry_connection.pin());
        });
    drop(pin);
    waiter.join().expect("the waiter got the connection");
}

#[test]
fn qos_utility_waiter_on_a_terminal_lock_is_raised_before_it_gets_the_lock() {
    let term = Arc::new(RankedMutex::new(LockRank::Terminal, "pty.term", ()));
    let held = term.lock().expect("pty.term");
    let waiter_term = term.clone();
    let waiter = assert_waiter_raised_before_it_gets_the_lock("lock-qos-term-waiter", move || {
        drop(waiter_term.lock().expect("pty.term"));
    });
    drop(held);
    waiter.join().expect("the waiter got pty.term");
}
