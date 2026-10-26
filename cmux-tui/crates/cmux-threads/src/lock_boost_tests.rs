//! The owner boost without a lock: an owner thread holds, a waiter thread
//! calls `wait`, and the owner reads its own QoS as the scheduler applies it.
//! Nice-independent on Linux: where the process may not lower nice values
//! (no root, RLIMIT_NICE 0) a boost is refused and counted, and the owner
//! stays where it started.

use std::sync::Arc;
use std::sync::mpsc::{Receiver, channel};

use super::{BoostCounts, OwnerBoost};
use crate::qos::{LiveQos, ThreadQos, current_effective};

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

/// True when this process can raise a Utility thread to the request class
/// (macOS always; Linux when it may lower nice values back to 0).
fn can_boost() -> bool {
    cfg!(target_vendor = "apple")
        || (cfg!(any(target_os = "linux", target_os = "android"))
            && crate::reversible(ThreadQos::Utility))
}

/// What an owner reads before, during and after its hold.
#[derive(Debug)]
struct Reads {
    before: LiveQos,
    during: LiveQos,
    after: LiveQos,
}

/// Starts an owner at `qos` that holds `boost` (twice when `reentered`, the
/// inner hold dropped before the read), lets `waiter` run once it holds,
/// and reads its QoS when `waiter` is done.
fn owner(
    boost: &Arc<OwnerBoost>,
    qos: ThreadQos,
    reentered: bool,
    waiter: impl FnOnce() -> Receiver<()> + Send + 'static,
) -> Reads {
    let boost = Arc::clone(boost);
    crate::spawn("lock-boost-owner-test", qos, move || {
        let before = current_effective();
        let hold = OwnerBoost::hold(&*boost);
        if reentered {
            drop(OwnerBoost::hold(&*boost));
        }
        waiter().recv().expect("the waiter ran");
        let during = current_effective();
        drop(hold);
        Reads { before, during, after: current_effective() }
    })
    .expect("spawn owner")
    .join()
    .expect("owner")
}

/// A waiter at `qos` that calls `wait` once and ends its wait.
fn waiter(boost: &Arc<OwnerBoost>, qos: ThreadQos) -> impl FnOnce() -> Receiver<()> + Send + use<> {
    let boost = Arc::clone(boost);
    move || {
        let (done_tx, done_rx) = channel();
        crate::spawn("lock-boost-waiter-test", qos, move || {
            drop(boost.wait());
            done_tx.send(()).expect("done");
        })
        .expect("spawn waiter");
        done_rx
    }
}

/// The counts one boost of a Utility owner leaves.
fn one_boost() -> BoostCounts {
    if can_boost() {
        BoostCounts { started: 1, refused: 0 }
    } else {
        BoostCounts { started: 0, refused: 1 }
    }
}

#[test]
fn a_higher_waiter_raises_the_owner_until_its_last_hold_ends() {
    for reentered in [false, true] {
        let boost = Arc::new(OwnerBoost::new());
        let reads =
            owner(&boost, ThreadQos::Utility, reentered, waiter(&boost, ThreadQos::UserInitiated));
        #[cfg(target_vendor = "apple")]
        assert_eq!(reads.before, runs_at(ThreadQos::Utility), "{reads:?}");
        let boosted = if can_boost() { runs_at(ThreadQos::UserInitiated) } else { reads.before };
        assert_eq!(reads.during, boosted, "reentered {reentered}: {reads:?}");
        assert_eq!(reads.after, reads.before, "reentered {reentered}: {reads:?}");
        assert_eq!(boost.counts(), one_boost());
    }
}

#[test]
fn an_equal_or_lower_waiter_starts_nothing() {
    for waiter_qos in [ThreadQos::Utility, ThreadQos::Background] {
        let boost = Arc::new(OwnerBoost::new());
        let reads = owner(&boost, ThreadQos::Utility, false, waiter(&boost, waiter_qos));
        assert_eq!(reads.during, reads.before, "{waiter_qos}: {reads:?}");
        assert_eq!(boost.counts(), BoostCounts::default(), "{waiter_qos}");
    }
}

#[test]
fn an_owner_that_takes_the_lock_past_a_higher_waiter_raises_itself() {
    let boost = Arc::new(OwnerBoost::new());
    let (waiting_tx, waiting_rx) = channel();
    let (release_tx, release_rx) = channel::<()>();
    let waiting = Arc::clone(&boost);
    let high = crate::spawn("lock-boost-early-waiter-test", ThreadQos::UserInitiated, move || {
        let wait = waiting.wait();
        waiting_tx.send(()).expect("waiting");
        release_rx.recv().expect("released");
        drop(wait);
    })
    .expect("spawn early waiter");
    waiting_rx.recv().expect("the waiter waits before any owner");
    assert_eq!(boost.counts(), BoostCounts::default(), "no owner to raise yet");
    let reads = owner(&boost, ThreadQos::Utility, false, move || {
        let (done_tx, done_rx) = channel();
        done_tx.send(()).expect("done");
        done_rx
    });
    release_tx.send(()).expect("release");
    high.join().expect("early waiter");
    let boosted = if can_boost() { runs_at(ThreadQos::UserInitiated) } else { reads.before };
    assert_eq!(reads.during, boosted, "{reads:?}");
    assert_eq!(reads.after, reads.before, "{reads:?}");
    assert_eq!(boost.counts(), one_boost());
}

#[test]
fn a_waiter_with_no_registered_class_boosts_nothing() {
    let boost = Arc::new(OwnerBoost::new());
    let unregistered = Arc::clone(&boost);
    let reads = owner(&boost, ThreadQos::Utility, false, move || {
        let (done_tx, done_rx) = channel();
        std::thread::Builder::new()
            .name("lock-boost-unregistered-test".into())
            .spawn(move || {
                drop(unregistered.wait());
                done_tx.send(()).expect("done");
            })
            .expect("spawn unregistered waiter");
        done_rx
    });
    assert_eq!(reads.during, reads.before, "{reads:?}");
    assert_eq!(boost.counts(), BoostCounts::default());
}
