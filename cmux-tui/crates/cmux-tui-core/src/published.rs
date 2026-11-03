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

use std::ops::{Deref, DerefMut};
use std::sync::{Arc, LockResult, Mutex, MutexGuard, PoisonError};
#[cfg(test)]
use std::sync::{TryLockError, TryLockResult};

use arc_swap::ArcSwap;

/// A mutex-guarded value with a lock-free published projection (see the module docs).
pub(crate) struct Published<T, S> {
    value: Mutex<T>,
    projection: ArcSwap<S>,
    project: fn(&T) -> S,
}

impl<T, S> Published<T, S> {
    /// `project` makes the immutable projection that readers load. It runs under the mutex after
    /// each change, so it must read only and stay small.
    pub(crate) fn new(value: T, project: fn(&T) -> S) -> Self {
        let projection = ArcSwap::from_pointee(project(&value));
        Self { value: Mutex::new(value), projection, project }
    }

    /// The projection of the newest finished change: one atomic load, never a wait. When a writer
    /// panicked while it held the value (the mutex is poisoned), the projection comes in the error,
    /// as `std::sync::Mutex::lock` gives its guard, so a caller can fail closed.
    pub(crate) fn load(&self) -> LockResult<arc_swap::Guard<Arc<S>>> {
        let projection = self.projection.load();
        if self.value.is_poisoned() { Err(PoisonError::new(projection)) } else { Ok(projection) }
    }

    /// The value itself, for a change or for a read that needs more than the projection. A
    /// poisoned mutex gives its guard in the error, as `std::sync::Mutex::lock` does.
    pub(crate) fn lock(&self) -> LockResult<PublishGuard<'_, T, S>> {
        match self.value.lock() {
            Ok(guard) => Ok(PublishGuard { owner: self, guard, changed: false }),
            Err(poison) => Err(PoisonError::new(PublishGuard {
                owner: self,
                guard: poison.into_inner(),
                changed: false,
            })),
        }
    }
}

#[cfg(test)]
impl<T, S> Published<T, S> {
    /// The value if no thread holds it now (tests that prove a hold).
    pub(crate) fn try_lock(&self) -> TryLockResult<PublishGuard<'_, T, S>> {
        match self.value.try_lock() {
            Ok(guard) => Ok(PublishGuard { owner: self, guard, changed: false }),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => {
                Err(TryLockError::Poisoned(PoisonError::new(PublishGuard {
                    owner: self,
                    guard: poison.into_inner(),
                    changed: false,
                })))
            }
        }
    }
}

/// A held [`Published`] value. A mutable borrow marks it changed; it then publishes the new
/// projection when it drops, before the mutex is released (fields drop after `Drop::drop`).
pub(crate) struct PublishGuard<'a, T, S> {
    owner: &'a Published<T, S>,
    guard: MutexGuard<'a, T>,
    changed: bool,
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
        if self.changed {
            self.owner.projection.store(Arc::new((self.owner.project)(&*self.guard)));
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
        let published = Published::new(Counter::default(), project);
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
        let published = std::sync::Arc::new(Published::new(Counter::default(), project));
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

    #[test]
    fn a_poisoned_value_gives_its_projection_in_the_error() {
        let published = Published::new(Counter::default(), project);
        assert!(published.load().is_ok());
        published.poison_for_test();
        assert!(published.load().is_err(), "a reader can fail closed on a poisoned value");
    }

    impl<T, S> Published<T, S> {
        fn load_full_for_test(&self) -> std::sync::Arc<S> {
            self.projection.load_full()
        }

        /// Poisons the value: a panic while it is held (fail-closed tests).
        pub(crate) fn poison_for_test(&self) {
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _held = self.value.lock();
                panic!("poisons the value for a fail-closed test");
            }));
            assert!(self.value.is_poisoned());
        }
    }
}
