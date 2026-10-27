//! `Mutex`, `RwLock` and `Condvar` with std's API that time their waits
//! (plans/cmux-next/chrome-parity/p02-threads.md, 3D, task 227).
//!
//! A site swaps `std::sync::{Mutex, RwLock, Condvar}` for these and nothing
//! else: the guards, `LockResult` and `PoisonError` are std's, so a guard
//! from [`Mutex::lock`] goes to [`Condvar::wait`] or to any code that takes a
//! `std::sync::MutexGuard`.
//!
//! - Debug: an acquisition tries the lock first, and only a failed try on a
//!   thread that may not wait ([`crate::blocking`]) is timed. When that wait
//!   took [`LOCK_WAIT_BUDGET`] or more, its caller is a recorded
//!   [`BlockingKind::LockWait`] site; a condition-variable wait that long is
//!   a [`BlockingKind::CondvarWait`] site. Record only, never a panic: the
//!   wait is over and its guard held.
//! - Release: the std call, unchanged.
//!
//! Chromium times the contended path only, the same way:
//! base/synchronization/lock_impl.h (`LockImpl::Lock` tries first; a failed
//! try takes `LockInternalWithTracking`) and
//! base/synchronization/condition_variable_posix.cc (`Wait` runs inside a
//! `ScopedBlockingCallWithBaseSyncPrimitives`). [`crate::lock_wait`] names
//! the holder of one lock; these wrappers name only the waiting site.

#[cfg(debug_assertions)]
use std::sync::TryLockError;
use std::sync::{
    LockResult, MutexGuard, RwLockReadGuard, RwLockWriteGuard, TryLockResult, WaitTimeoutResult,
};
use std::time::Duration;

use crate::blocking::BlockingKind;
#[cfg(debug_assertions)]
use crate::lock_wait::LOCK_WAIT_BUDGET;

/// Runs `wait`, a wait of `kind`, timed on a thread that may not make it: a
/// wait of [`LOCK_WAIT_BUDGET`] or more records the caller's site.
#[inline]
#[cfg_attr(debug_assertions, track_caller)]
#[cfg_attr(not(debug_assertions), allow(unused_variables))]
fn timed<R>(kind: BlockingKind, wait: impl FnOnce() -> R) -> R {
    #[cfg(debug_assertions)]
    if crate::blocking::denies(kind) {
        let since = std::time::Instant::now();
        let result = wait();
        if since.elapsed() >= LOCK_WAIT_BUDGET {
            crate::blocking::note_long_wait(kind, std::panic::Location::caller());
        }
        return result;
    }
    wait()
}

/// A try's result as the blocking call returns it, or `None` when the
/// lock is held.
#[cfg(debug_assertions)]
#[inline]
fn won<G>(attempt: TryLockResult<G>) -> Option<LockResult<G>> {
    match attempt {
        Ok(guard) => Some(Ok(guard)),
        Err(TryLockError::Poisoned(poisoned)) => Some(Err(poisoned)),
        Err(TryLockError::WouldBlock) => None,
    }
}

/// `std::sync::Mutex` with its contended waits timed.
#[derive(Default)]
pub struct Mutex<T: ?Sized>(std::sync::Mutex<T>);

impl<T> Mutex<T> {
    /// `Mutex::new`.
    pub const fn new(value: T) -> Self {
        Self(std::sync::Mutex::new(value))
    }

    /// `Mutex::into_inner`.
    pub fn into_inner(self) -> LockResult<T> {
        self.0.into_inner()
    }
}

impl<T: ?Sized> Mutex<T> {
    /// `Mutex::lock`.
    #[inline]
    #[cfg_attr(debug_assertions, track_caller)]
    pub fn lock(&self) -> LockResult<MutexGuard<'_, T>> {
        #[cfg(debug_assertions)]
        if let Some(guard) = won(self.0.try_lock()) {
            return guard;
        }
        timed(BlockingKind::LockWait, || self.0.lock())
    }

    /// `Mutex::try_lock`: never waits.
    #[inline]
    pub fn try_lock(&self) -> TryLockResult<MutexGuard<'_, T>> {
        self.0.try_lock()
    }

    /// `Mutex::is_poisoned`.
    pub fn is_poisoned(&self) -> bool {
        self.0.is_poisoned()
    }

    /// `Mutex::clear_poison`.
    pub fn clear_poison(&self) {
        self.0.clear_poison();
    }

    /// `Mutex::get_mut`.
    pub fn get_mut(&mut self) -> LockResult<&mut T> {
        self.0.get_mut()
    }
}

impl<T> From<T> for Mutex<T> {
    fn from(value: T) -> Self {
        Self::new(value)
    }
}

impl<T: ?Sized + std::fmt::Debug> std::fmt::Debug for Mutex<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

/// `std::sync::RwLock` with its contended waits timed.
#[derive(Default)]
pub struct RwLock<T: ?Sized>(std::sync::RwLock<T>);

impl<T> RwLock<T> {
    /// `RwLock::new`.
    pub const fn new(value: T) -> Self {
        Self(std::sync::RwLock::new(value))
    }

    /// `RwLock::into_inner`.
    pub fn into_inner(self) -> LockResult<T> {
        self.0.into_inner()
    }
}

impl<T: ?Sized> RwLock<T> {
    /// `RwLock::read`.
    #[inline]
    #[cfg_attr(debug_assertions, track_caller)]
    pub fn read(&self) -> LockResult<RwLockReadGuard<'_, T>> {
        #[cfg(debug_assertions)]
        if let Some(guard) = won(self.0.try_read()) {
            return guard;
        }
        timed(BlockingKind::LockWait, || self.0.read())
    }

    /// `RwLock::write`.
    #[inline]
    #[cfg_attr(debug_assertions, track_caller)]
    pub fn write(&self) -> LockResult<RwLockWriteGuard<'_, T>> {
        #[cfg(debug_assertions)]
        if let Some(guard) = won(self.0.try_write()) {
            return guard;
        }
        timed(BlockingKind::LockWait, || self.0.write())
    }

    /// `RwLock::try_read`: never waits.
    #[inline]
    pub fn try_read(&self) -> TryLockResult<RwLockReadGuard<'_, T>> {
        self.0.try_read()
    }

    /// `RwLock::try_write`: never waits.
    #[inline]
    pub fn try_write(&self) -> TryLockResult<RwLockWriteGuard<'_, T>> {
        self.0.try_write()
    }

    /// `RwLock::is_poisoned`.
    pub fn is_poisoned(&self) -> bool {
        self.0.is_poisoned()
    }

    /// `RwLock::clear_poison`.
    pub fn clear_poison(&self) {
        self.0.clear_poison();
    }

    /// `RwLock::get_mut`.
    pub fn get_mut(&mut self) -> LockResult<&mut T> {
        self.0.get_mut()
    }
}

impl<T> From<T> for RwLock<T> {
    fn from(value: T) -> Self {
        Self::new(value)
    }
}

impl<T: ?Sized + std::fmt::Debug> std::fmt::Debug for RwLock<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

/// `std::sync::Condvar` with its waits timed: a wait is the time until the
/// waiter holds the mutex again.
#[derive(Debug, Default)]
pub struct Condvar(std::sync::Condvar);

impl Condvar {
    /// `Condvar::new`.
    pub const fn new() -> Self {
        Self(std::sync::Condvar::new())
    }

    /// The std condition variable, for [`crate::checked::sync`], whose waits
    /// are checked at any length.
    pub(crate) fn as_std(&self) -> &std::sync::Condvar {
        &self.0
    }

    /// `Condvar::wait`.
    #[inline]
    #[cfg_attr(debug_assertions, track_caller)]
    pub fn wait<'a, T>(&self, guard: MutexGuard<'a, T>) -> LockResult<MutexGuard<'a, T>> {
        timed(BlockingKind::CondvarWait, || self.0.wait(guard))
    }

    /// `Condvar::wait_while`.
    #[inline]
    #[cfg_attr(debug_assertions, track_caller)]
    pub fn wait_while<'a, T>(
        &self,
        guard: MutexGuard<'a, T>,
        condition: impl FnMut(&mut T) -> bool,
    ) -> LockResult<MutexGuard<'a, T>> {
        timed(BlockingKind::CondvarWait, || self.0.wait_while(guard, condition))
    }

    /// `Condvar::wait_timeout`.
    #[inline]
    #[cfg_attr(debug_assertions, track_caller)]
    pub fn wait_timeout<'a, T>(
        &self,
        guard: MutexGuard<'a, T>,
        timeout: Duration,
    ) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)> {
        // wakeup-allow: deadline the caller's own timed wait, passed through; the audit judges the caller's wait_timeout(
        timed(BlockingKind::CondvarWait, || self.0.wait_timeout(guard, timeout))
    }

    /// `Condvar::wait_timeout_while`.
    #[inline]
    #[cfg_attr(debug_assertions, track_caller)]
    pub fn wait_timeout_while<'a, T>(
        &self,
        guard: MutexGuard<'a, T>,
        timeout: Duration,
        condition: impl FnMut(&mut T) -> bool,
    ) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)> {
        timed(BlockingKind::CondvarWait, || self.0.wait_timeout_while(guard, timeout, condition))
    }

    /// This condition variable for a thread that is idle: it waits for its
    /// own next work item at the top of its loop and holds no one else's
    /// work (a dispatcher's empty queue, a worker's next deadline). Its
    /// waits are never timed or recorded, at any length. Chromium declares
    /// the same with `WaitableEvent::declare_only_used_while_idle`
    /// (base/synchronization/waitable_event.h), which MessagePumpDefault's
    /// event uses: a thread idle at the bottom of its stack is not a
    /// `ScopedBlockingCall`. A wait for another thread's result is not idle;
    /// it takes [`Condvar::wait`].
    #[inline]
    pub fn idle(&self) -> IdleWait<'_> {
        IdleWait(&self.0)
    }

    /// `Condvar::notify_one`.
    #[inline]
    pub fn notify_one(&self) {
        self.0.notify_one();
    }

    /// `Condvar::notify_all`.
    #[inline]
    pub fn notify_all(&self) {
        self.0.notify_all();
    }
}

/// A [`Condvar`]'s idle waits ([`Condvar::idle`]): std's waits, untimed.
#[derive(Clone, Copy, Debug)]
pub struct IdleWait<'c>(&'c std::sync::Condvar);

impl IdleWait<'_> {
    /// `Condvar::wait` for the thread's next work item.
    #[inline]
    pub fn wait<'a, T>(self, guard: MutexGuard<'a, T>) -> LockResult<MutexGuard<'a, T>> {
        self.0.wait(guard)
    }

    /// `Condvar::wait_timeout` until the thread's own next deadline.
    #[inline]
    pub fn wait_timeout<'a, T>(
        self,
        guard: MutexGuard<'a, T>,
        timeout: Duration,
    ) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)> {
        // wakeup-allow: deadline the caller's own timed wait, passed through; the audit judges the caller's wait_timeout(
        self.0.wait_timeout(guard, timeout)
    }
}

#[cfg(test)]
#[path = "sync_locks_tests.rs"]
mod tests;
