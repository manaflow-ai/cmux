//! The registry connection lock boosts its owner: a Utility owner (a lowered
//! journal writer) runs at UserInitiated while a UserInitiated request
//! waits for the lock, and at Utility again once it lets go.
//!
//! On Linux a boost lowers the owner's nice value, which only root or an
//! RLIMIT_NICE that allows it may do; elsewhere the boost is refused and
//! counted, and the owner stays where it started.

use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use cmux_threads::{BoostCounts, LiveQos, ThreadQos, current_effective};

use crate::WorkspaceRegistry;

/// How long the owner spins with the waiter behind it.
const SPIN: Duration = Duration::from_millis(20);

/// What `current_effective` reads for a thread at `qos`.
fn runs_at(qos: ThreadQos) -> LiveQos {
    #[cfg(target_vendor = "apple")]
    return LiveQos::Class(qos);
    #[cfg(any(target_os = "linux", target_os = "android"))]
    return LiveQos::Nice(qos.linux_nice());
    #[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
    return {
        let _ = qos;
        LiveQos::Unknown
    };
}

/// True when this process can raise a Utility thread to UserInitiated.
fn can_boost() -> bool {
    cfg!(target_vendor = "apple")
        || (cfg!(any(target_os = "linux", target_os = "android"))
            && cmux_threads::reversible(ThreadQos::Utility))
}

#[derive(Debug)]
struct OwnerReads {
    before: LiveQos,
    during: LiveQos,
    after: LiveQos,
}

/// A `waiter_qos` request waits for the connection a Utility owner pinned;
/// the owner spins [`SPIN`] once the waiter started its boost and reads its
/// QoS before, during and after its hold.
fn owner_behind(waiter_qos: ThreadQos, name: &str) -> (OwnerReads, BoostCounts) {
    let registry = WorkspaceRegistry::in_memory(name).expect("registry");
    let connection = Arc::clone(&registry.connection);
    let (held_tx, held_rx) = channel();
    let owner = cmux_threads::spawn("registry-boost-owner-test", ThreadQos::Utility, move || {
        let before = current_effective();
        let pin = connection.pin();
        held_tx.send(()).expect("held");
        // Until the waiter's try failed; it starts its boost right after.
        while connection.lock_waiting() == 0 {
            std::hint::spin_loop();
        }
        let spin_until = Instant::now() + SPIN;
        while Instant::now() < spin_until {
            std::hint::spin_loop();
        }
        let during = current_effective();
        drop(pin);
        OwnerReads { before, during, after: current_effective() }
    })
    .expect("spawn owner");
    held_rx.recv().expect("the owner pinned the connection");
    let counts = Arc::clone(&registry.connection);
    let waiter = cmux_threads::spawn("registry-boost-waiter-test", waiter_qos, move || {
        registry.terminal_revision().expect("terminal revision behind the owner");
    })
    .expect("spawn waiter");
    let reads = owner.join().expect("owner");
    waiter.join().expect("waiter");
    let boosts = counts.owner_boosts();
    (reads, boosts)
}

#[test]
fn a_user_initiated_waiter_raises_a_utility_owner_until_it_unlocks() {
    let (reads, boosts) = owner_behind(ThreadQos::UserInitiated, "owner-boost-raise");
    #[cfg(target_vendor = "apple")]
    assert_eq!(reads.before, runs_at(ThreadQos::Utility), "{reads:?}");
    if can_boost() {
        assert_eq!(reads.during, runs_at(ThreadQos::UserInitiated), "{reads:?}");
        assert_eq!(boosts, BoostCounts { started: 1, refused: 0 });
    } else {
        assert_eq!(reads.during, reads.before, "{reads:?}");
        assert_eq!(boosts, BoostCounts { started: 0, refused: 1 });
    }
    assert_eq!(reads.after, reads.before, "{reads:?}");
}

#[test]
fn a_waiter_at_the_owners_qos_starts_no_boost() {
    let (reads, boosts) = owner_behind(ThreadQos::Utility, "owner-boost-equal");
    assert_eq!(reads.during, reads.before, "{reads:?}");
    assert_eq!(reads.after, reads.before, "{reads:?}");
    assert_eq!(boosts, BoostCounts::default());
}
