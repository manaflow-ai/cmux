//! An event-driven authority lease for one already authenticated stream.
//! The verifier owns the weak control handle; the transport owns the lease.
//! No timer, runtime, I/O or token replay happens here.

use crate::elapsed::Deadline;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, Weak};
use std::task::{Context, Poll, Waker};
use std::time::Instant;

struct State {
    deadline: Option<Instant>,
    elapsed: Option<Deadline>,
    revision: u64,
    observers: Vec<Weak<Mutex<Observer>>>,
}

impl State {
    fn live_deadline(&self) -> Option<Instant> {
        if self.elapsed.as_ref().is_some_and(|budget| budget.remaining().is_none()) {
            return None;
        }
        self.deadline
    }
}

struct Observer {
    observed: u64,
    waiter: Option<Waker>,
}

/// A verified stream's current deadline and authority-change notification.
/// Expiry is enforced by the transport's one-shot timer. A renewal can update
/// this deadline only while the verifier still recognizes the same authority.
pub struct StreamLease {
    state: Arc<Mutex<State>>,
    observer: Arc<Mutex<Observer>>,
}

impl std::fmt::Debug for StreamLease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StreamLease").field("deadline", &self.deadline()).finish_non_exhaustive()
    }
}
impl Clone for StreamLease {
    fn clone(&self) -> Self {
        let observed = self.observer.lock().map_or(0, |o| o.observed);
        let observer = Arc::new(Mutex::new(Observer { observed, waiter: None }));
        if let Ok(mut state) = self.state.lock() {
            state.observers.retain(|o| o.strong_count() > 0);
            state.observers.push(Arc::downgrade(&observer));
        }
        Self { state: self.state.clone(), observer }
    }
}
impl PartialEq for StreamLease {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.state, &other.state)
    }
}
impl Eq for StreamLease {}

pub(crate) struct LeaseControl(Weak<Mutex<State>>);

impl StreamLease {
    /// A fixed lease for a verifier whose authority cannot renew. TokenVerifier
    /// implementations remain responsible for authenticating before creating it.
    pub fn fixed_until(deadline: Instant) -> Self {
        Self::controlled(deadline).0
    }

    pub(crate) fn controlled(deadline: Instant) -> (Self, LeaseControl) {
        Self::with_budget(deadline, None)
    }

    pub(crate) fn with_budget(
        deadline: Instant,
        elapsed: Option<Deadline>,
    ) -> (Self, LeaseControl) {
        let observer = Arc::new(Mutex::new(Observer { observed: 0, waiter: None }));
        let state = Arc::new(Mutex::new(State {
            deadline: Some(deadline),
            elapsed,
            revision: 0,
            observers: vec![Arc::downgrade(&observer)],
        }));
        let control = LeaseControl(Arc::downgrade(&state));
        (Self { state, observer }, control)
    }

    pub fn deadline(&self) -> Option<Instant> {
        drop(self.observer.lock().ok()?);
        self.state.lock().ok()?.live_deadline()
    }

    pub fn elapsed_deadline(&self) -> Option<Deadline> {
        self.state.lock().ok()?.elapsed.clone()
    }

    /// Registers before checking the revision under the same lock, so a revoke
    /// between reading the deadline and awaiting this future cannot be lost.
    pub fn changed(&mut self) -> Changed<'_> {
        Changed { lease: self }
    }
}

pub struct Changed<'a> {
    lease: &'a mut StreamLease,
}

impl Future for Changed<'_> {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let lease = &mut self.get_mut().lease;
        let Ok(state) = lease.state.lock() else { return Poll::Ready(()) };
        let Ok(mut observer) = lease.observer.lock() else { return Poll::Ready(()) };
        if state.live_deadline().is_none() || state.revision != observer.observed {
            observer.observed = state.revision;
            return Poll::Ready(());
        }
        if observer.waiter.as_ref().is_none_or(|w| !w.will_wake(cx.waker())) {
            observer.waiter = Some(cx.waker().clone());
        }
        Poll::Pending
    }
}

impl Drop for Changed<'_> {
    fn drop(&mut self) {
        if let Ok(mut observer) = self.lease.observer.lock() {
            observer.waiter = None;
        }
    }
}

impl LeaseControl {
    pub(crate) fn deadline(&self) -> Option<Instant> {
        self.0.upgrade()?.lock().ok()?.live_deadline()
    }

    pub(crate) fn elapsed_deadline(&self) -> Option<Deadline> {
        self.0.upgrade()?.lock().ok()?.elapsed.clone()
    }

    /// Return the waker rather than executing arbitrary transport code under
    /// the verifier's state lock. Callers wake only after dropping that lock.
    pub(crate) fn set(&self, deadline: Option<Instant>, elapsed: Option<Deadline>) -> Vec<Waker> {
        let Some(state) = self.0.upgrade() else { return Vec::new() };
        let Ok(mut state) = state.lock() else { return Vec::new() };
        if state.deadline == deadline && state.elapsed == elapsed {
            return Vec::new();
        }
        state.deadline = deadline;
        state.elapsed = elapsed;
        state.revision = state.revision.wrapping_add(1);
        let mut wake = Vec::new();
        state.observers.retain(|observer| {
            let Some(observer) = observer.upgrade() else { return false };
            if let Ok(mut observer) = observer.lock()
                && let Some(waker) = observer.waiter.take()
            {
                wake.push(waker);
            }
            true
        });
        wake
    }
}
