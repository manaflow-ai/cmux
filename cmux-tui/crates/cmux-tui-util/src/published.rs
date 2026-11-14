//! A value that one thread at a time changes and any thread reads without waiting
//! (handoff/rewrites/R-DAEMON-STATE/DESIGN.md, rule R2: readers never wait).
//!
//! Writers serialize on the value's mutex, as before. A guard that changed the value (it was
//! borrowed mutably) publishes an immutable projection of the value when it drops, while it still
//! holds the mutex, so projections are published in the order of the changes. A reader loads the
//! newest projection with one atomic load (`arc-swap`): it never takes the mutex, so no reader
//! waits for a writer and no writer waits for a reader.
//!
//! The projection is the only copy a reader sees, and only the guard writes it: no code path can
//! change the value without publishing the change, because every change goes through the guard.
//!
//! A change that a panic cuts short is never published: the guard that held it drops during the unwind, and the
//! mutex is then marked poisoned, so a reader's [`Published::load`] gives the last finished projection inside the
//! poison error, and the reader decides whether to fail closed or to recover it.
//!
//! Publishing is on or off for the value's life (a stage switch decides it when the value is made;
//! tests can turn it on). Off, a guard builds no projection, so a value nobody reads lock-free costs
//! what a plain mutex costs; a reader asks [`Published::publishing`] which read is current.

use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LockResult, Mutex, MutexGuard, PoisonError};
#[cfg(any(test, feature = "test-support"))]
use std::sync::{TryLockError, TryLockResult};

use arc_swap::ArcSwap;

/// A mutex-guarded value with a lock-free published projection (see the module docs).
pub struct Published<T, S> {
    value: Mutex<T>,
    projection: ArcSwap<S>,
    project: fn(&T) -> S,
    /// Whether a changing guard publishes. Fixed when the value is made; a test may set it, under `value`'s lock and
    /// after the current value is published (Release), so a reader that sees it on (Acquire) sees a current projection.
    publishing: AtomicBool,
}

/// A value whose projection is a copy of the whole value (small maps the key path reads), not publishing.
impl<T: Clone + Default> Default for Published<T, T> {
    fn default() -> Self {
        Self::new(T::default(), T::clone, false)
    }
}

impl<T, S> Published<T, S> {
    /// `project` makes the immutable projection that readers load. It runs under the mutex after
    /// each change while `publishing` is on, so it must read only and stay small.
    pub fn new(value: T, project: fn(&T) -> S, publishing: bool) -> Self {
        let projection = ArcSwap::from_pointee(project(&value));
        Self {
            value: Mutex::new(value),
            projection,
            project,
            publishing: AtomicBool::new(publishing),
        }
    }

    /// Turns publishing on or off; on, the current value is published first, under the lock (tests).
    #[cfg(any(test, feature = "test-support"))]
    pub fn set_publishing_for_test(&self, on: bool) {
        let value = self.value.lock().unwrap_or_else(PoisonError::into_inner);
        if on {
            self.projection.store(Arc::new((self.project)(&*value)));
        }
        self.publishing.store(on, Ordering::Release);
    }

    /// Whether changes are published: on, [`Self::load`] gives the newest finished change; off, the projection is
    /// stale and a reader takes [`Self::lock`] instead.
    pub fn publishing(&self) -> bool {
        self.publishing.load(Ordering::Acquire)
    }

    /// Whether a writer panicked while it held the value.
    pub fn is_poisoned(&self) -> bool {
        self.value.is_poisoned()
    }

    /// The projection of the newest finished change: one atomic load, never a wait. When a writer
    /// panicked while it held the value (the mutex is poisoned), the projection comes in the error,
    /// as `std::sync::Mutex::lock` gives its guard, so a caller can fail closed. Only a value that
    /// publishes has a current projection; a reader of one that does not takes [`Self::lock`].
    pub fn load(&self) -> LockResult<arc_swap::Guard<Arc<S>>> {
        debug_assert!(self.publishing(), "a projection read of a value that does not publish");
        let projection = self.projection.load();
        if self.value.is_poisoned() { Err(PoisonError::new(projection)) } else { Ok(projection) }
    }

    /// The value itself, for a change or for a read that needs more than the projection. A
    /// poisoned mutex gives its guard in the error, as `std::sync::Mutex::lock` does.
    pub fn lock(&self) -> LockResult<PublishGuard<'_, T, S>> {
        match self.value.lock() {
            Ok(guard) => Ok(self.guard(guard)),
            Err(poison) => Err(PoisonError::new(self.guard(poison.into_inner()))),
        }
    }

    fn guard<'a>(&'a self, guard: MutexGuard<'a, T>) -> PublishGuard<'a, T, S> {
        PublishGuard {
            owner: self,
            guard,
            changed: false,
            panicking_at_lock: std::thread::panicking(),
            retired: None,
        }
    }
}

#[cfg(any(test, feature = "test-support"))]
impl<T, S> Published<T, S> {
    /// The value if no thread holds it now (tests that prove a hold).
    pub fn try_lock(&self) -> TryLockResult<PublishGuard<'_, T, S>> {
        match self.value.try_lock() {
            Ok(guard) => Ok(self.guard(guard)),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => {
                Err(TryLockError::Poisoned(PoisonError::new(self.guard(poison.into_inner()))))
            }
        }
    }
}

/// A held [`Published`] value. A mutable borrow marks it changed; it then publishes the new
/// projection when it drops, before the mutex is released (fields drop after `Drop::drop`).
pub struct PublishGuard<'a, T, S> {
    owner: &'a Published<T, S>,
    guard: MutexGuard<'a, T>,
    changed: bool,
    /// Whether this thread was already unwinding when it took the value, as `std::sync::MutexGuard` records it.
    panicking_at_lock: bool,
    /// The projection this guard replaced. It drops after `guard` (fields drop in order), so what it may hold last
    /// is freed after the mutex is released, never under it.
    retired: Option<Arc<S>>,
}

impl<T, S> Deref for PublishGuard<'_, T, S> {
    type Target = T;

    fn deref(&self) -> &T {
        &self.guard
    }
}

impl<T, S> DerefMut for PublishGuard<'_, T, S> {
    fn deref_mut(&mut self) -> &mut T {
        self.changed = true;
        &mut self.guard
    }
}

impl<T, S> Drop for PublishGuard<'_, T, S> {
    fn drop(&mut self) {
        // A panic that began while this guard held the value cut its change short: the `MutexGuard` field poisons
        // the mutex right after this (the same test std makes), and the half-made value is never published, so no
        // reader sees it, not even before the poisoning.
        let cut_short = std::thread::panicking() && !self.panicking_at_lock;
        // The flag is read under the lock this guard holds, where it is also written.
        if self.changed && !cut_short && self.owner.publishing.load(Ordering::Relaxed) {
            let projection = Arc::new((self.owner.project)(&*self.guard));
            self.retired = Some(self.owner.projection.swap(projection));
        }
    }
}

#[cfg(test)]
mod tests;
