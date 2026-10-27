//! A lock whose owner runs at the QoS of its highest waiter.
//!
//! A lock that does not donate priority (parking_lot's, std's on Linux)
//! lets a Utility owner keep a UserInitiated waiter behind it for as long as
//! the scheduler prefers other Utility work. Chromium avoids that with
//! priority inheritance: base/synchronization/lock_impl_posix.cc makes its
//! locks `PTHREAD_PRIO_INHERIT` where the kernel supports it, and macOS's
//! `os_unfair_lock` donates by itself. An [`OwnerBoost`] gives a lock the
//! same rule with QoS overrides ([`crate::qos::boost`], Chromium's
//! `SetCurrentThreadTypeOverride`):
//!
//! - the owner records its thread and class when it takes the lock
//!   ([`OwnerBoost::hold`] on every acquisition, re-entries included);
//! - a waiter of a higher class than the owner, by its registry row, starts
//!   an override on the owner before it blocks ([`OwnerBoost::wait`]);
//! - an owner that takes the lock while higher-class threads still wait
//!   starts the override on itself (the lock went to a lower thread first);
//! - the owner's last hold ends the override before the lock unlocks.
//!
//! A boost lasts until the owner's unlock, also when its waiter gave up.
//!
//! Lock carve-out: the owner, the override and the waiting counts are one
//! std `Mutex`, a leaf held only to record or clear the owner and to start
//! or end one override (no I/O, no waits, no other lock), as Chromium's
//! `ThreadIdNameManager` holds its lock. It is what keeps a waiter from
//! starting an override on an owner thread that already let go and exited.

use std::marker::PhantomData;
use std::ops::Deref;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use crate::qos::ThreadQos;
use crate::qos::boost::{self, Override, Target};

/// The owner boost of one lock. Share it with the lock; every acquisition
/// takes an [`OwnerHold`] and every blocking wait a [`WaitBoost`].
#[derive(Debug, Default)]
pub struct OwnerBoost {
    /// Holds of the owner, re-entries included. Only the owning thread
    /// changes it, while it holds the lock, so the lock orders it.
    depth: AtomicU32,
    state: Mutex<State>,
    started: AtomicU64,
    refused: AtomicU64,
}

#[derive(Debug, Default)]
struct State {
    owner: Option<Owner>,
    /// The override on the owner and the class it raises it to.
    active: Option<(ThreadQos, Override)>,
    /// Waiters by class (`ThreadQos as usize`).
    waiting: [u32; ThreadQos::ALL.len()],
}

#[derive(Debug)]
struct Owner {
    target: Target,
    class: Option<ThreadQos>,
}

/// Overrides an [`OwnerBoost`] started and the ones the kernel or the Linux
/// nice rule refused.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BoostCounts {
    pub started: u64,
    pub refused: u64,
}

impl OwnerBoost {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records the calling thread as the owner; call right after every
    /// acquisition of the lock, re-entries included, and drop the hold
    /// before the lock's guard (declare it first in the struct that holds
    /// both). The first hold starts an override on the owner itself when a
    /// thread of a higher class still waits.
    pub fn hold<R: Deref<Target = OwnerBoost>>(boost: R) -> OwnerHold<R> {
        if boost.depth.fetch_add(1, Ordering::Relaxed) == 0 {
            let owner = Owner { target: boost::target_self(), class: boost::current_class() };
            let mut state = boost.state();
            debug_assert!(state.active.is_none(), "an override outlived its owner");
            state.owner = Some(owner);
            if let Some(top) = state.top_waiter() {
                boost.raise_owner(&mut state, top);
            }
        }
        OwnerHold { boost, _not_send: PhantomData }
    }

    /// The calling thread waits for the lock until the result drops: an
    /// owner of a lower class runs at the caller's class until its unlock.
    /// Call it after a failed try, before blocking; a thread with no
    /// registered class boosts nothing.
    pub fn wait(&self) -> WaitBoost<'_> {
        let class = boost::current_class();
        if let Some(class) = class {
            let mut state = self.state();
            state.waiting[class as usize] += 1;
            self.raise_owner(&mut state, class);
        }
        WaitBoost { boost: self, class }
    }

    pub fn counts(&self) -> BoostCounts {
        BoostCounts {
            started: self.started.load(Ordering::Relaxed),
            refused: self.refused.load(Ordering::Relaxed),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Raises the owner, if any, to `class` when it runs lower. The owner
    /// thread is alive: it clears itself under the state lock before it
    /// unlocks.
    fn raise_owner(&self, state: &mut State, class: ThreadQos) {
        let Some(owner) = &state.owner else {
            return;
        };
        let floor = state.active.as_ref().map(|(qos, _)| *qos).max(owner.class);
        if floor.is_some_and(|floor| floor >= class) {
            return;
        }
        let raised = match &mut state.active {
            Some((qos, active)) => {
                let raised = boost::raise(active, class);
                if raised {
                    *qos = class;
                }
                raised
            }
            None => match boost::start(owner.target, class) {
                Some(active) => {
                    state.active = Some((class, active));
                    true
                }
                None => false,
            },
        };
        let counter = if raised { &self.started } else { &self.refused };
        counter.fetch_add(1, Ordering::Relaxed);
    }

    fn release(&self) {
        if self.depth.fetch_sub(1, Ordering::Relaxed) != 1 {
            return;
        }
        let mut state = self.state();
        state.owner = None;
        if let Some((_, active)) = state.active.take() {
            boost::end(active);
        }
    }
}

impl State {
    fn top_waiter(&self) -> Option<ThreadQos> {
        ThreadQos::ALL.into_iter().rev().find(|qos| self.waiting[*qos as usize] > 0)
    }
}

/// One hold of the lock by its owner thread; the last one ends the owner's
/// boost. Not `Send`: it ends on the thread that holds the lock.
#[must_use = "the owner record lasts only while the hold lives"]
pub struct OwnerHold<R: Deref<Target = OwnerBoost>> {
    boost: R,
    _not_send: PhantomData<*const ()>,
}

impl<R: Deref<Target = OwnerBoost>> Drop for OwnerHold<R> {
    fn drop(&mut self) {
        self.boost.release();
    }
}

impl<R: Deref<Target = OwnerBoost>> std::fmt::Debug for OwnerHold<R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OwnerHold").finish_non_exhaustive()
    }
}

/// A waiter of the lock, counted by class until it drops (it took the lock
/// or gave up).
#[must_use = "the waiter is counted only while this lives"]
#[derive(Debug)]
pub struct WaitBoost<'a> {
    boost: &'a OwnerBoost,
    class: Option<ThreadQos>,
}

impl Drop for WaitBoost<'_> {
    fn drop(&mut self) {
        if let Some(class) = self.class {
            self.boost.state().waiting[class as usize] -= 1;
        }
    }
}

#[cfg(test)]
#[path = "lock_boost_tests.rs"]
mod tests;
