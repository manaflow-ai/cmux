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
mod tests {
    use super::Published;

    #[derive(Default)]
    struct Counter {
        value: u64,
        reads: u64,
    }

    fn project(counter: &Counter) -> u64 {
        counter.value
    }

    #[test]
    fn a_change_is_published_when_its_guard_drops_and_a_read_publishes_nothing() {
        let published = Published::new(Counter::default(), project, true);
        assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 0);
        {
            let mut guard = published.lock().unwrap_or_else(|poison| poison.into_inner());
            guard.value = 7;
            // Not yet: the guard still holds the change.
            assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 0);
        }
        assert_eq!(
            **published.load().unwrap_or_else(|poison| poison.into_inner()),
            7,
            "the change was published when its guard dropped"
        );
        let before = published.load_full_for_test();
        {
            let guard = published.lock().unwrap_or_else(|poison| poison.into_inner());
            assert_eq!(guard.reads, 0);
        }
        assert!(
            std::sync::Arc::ptr_eq(&before, &published.load_full_for_test()),
            "a guard that only read published nothing"
        );
    }

    #[test]
    fn a_reader_does_not_wait_for_a_writer_that_holds_the_value() {
        let published = std::sync::Arc::new(Published::new(Counter::default(), project, true));
        let (held, holding) = std::sync::mpsc::channel();
        let (release, released) = std::sync::mpsc::channel::<()>();
        let writer = std::thread::spawn({
            let published = published.clone();
            move || {
                let mut guard = published.lock().unwrap_or_else(|poison| poison.into_inner());
                guard.value = 1;
                let _ = held.send(());
                let _ = released.recv_timeout(std::time::Duration::from_secs(5));
            }
        });
        let _ = holding.recv();
        let started = std::time::Instant::now();
        let seen = **published.load().unwrap_or_else(|poison| poison.into_inner());
        let waited = started.elapsed();
        let _ = release.send(());
        let _ = writer.join();
        assert_eq!(seen, 0, "the reader saw the last finished change, not the one in progress");
        assert!(waited < std::time::Duration::from_millis(100), "the reader waited {waited:?}");
        assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 1);
    }

    /// A writer that panics in the middle of a change leaves a half-made value: its guard still drops (the unwind
    /// runs it), but it publishes nothing, so no reader ever sees the half-made change, not even in the moment before
    /// the mutex is marked poisoned. Readers then fail closed with the last finished projection.
    #[test]
    fn a_change_cut_short_by_a_panic_is_never_published() {
        let published = Published::new(Counter::default(), project, true);
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut guard = published.lock().unwrap_or_else(|poison| poison.into_inner());
            guard.value = 9;
            panic!("a writer panics in the middle of a change");
        }));
        let Err(poisoned) = published.load() else {
            panic!("a reader of a poisoned value must be able to fail closed");
        };
        assert_eq!(**poisoned.into_inner(), 0, "the half-made change was published");
    }

    #[test]
    fn a_poisoned_value_gives_its_projection_in_the_error() {
        let published = Published::new(Counter::default(), project, true);
        assert!(published.load().is_ok());
        published.poison_for_test();
        assert!(published.is_poisoned());
        assert!(published.load().is_err(), "a reader can fail closed on a poisoned value");
    }

    /// A guard taken while the thread already unwinds (a cleanup in a `Drop`) finishes its change: it is published,
    /// as std leaves such a mutex unpoisoned.
    #[test]
    fn a_change_made_during_an_unwind_is_published() {
        struct Cleanup<'a>(&'a Published<Counter, u64>);
        impl Drop for Cleanup<'_> {
            fn drop(&mut self) {
                self.0.lock().unwrap_or_else(|poison| poison.into_inner()).value = 5;
            }
        }
        let published = Published::new(Counter::default(), project, true);
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _cleanup = Cleanup(&published);
            panic!("an unrelated panic runs the cleanup");
        }));
        assert!(!published.is_poisoned());
        assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 5);
    }

    /// Off, nothing is published and a reader is told so.
    #[test]
    fn a_value_that_does_not_publish_says_so() {
        let published = Published::new(Counter::default(), project, false);
        assert!(!published.publishing());
        published.lock().unwrap_or_else(|poison| poison.into_inner()).value = 3;
        assert_eq!(*published.load_full_for_test(), 0, "a change was published while off");
        published.set_publishing_for_test(true);
        assert!(published.publishing());
        assert_eq!(**published.load().unwrap_or_else(|poison| poison.into_inner()), 3);
    }

    impl<T, S> Published<T, S> {
        fn load_full_for_test(&self) -> std::sync::Arc<S> {
            self.projection.load_full()
        }

        /// Poisons the value: a panic while it is held (fail-closed tests).
        fn poison_for_test(&self) {
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _held = self.lock();
                panic!("poisons the value for a fail-closed test");
            }));
        }
    }
}
