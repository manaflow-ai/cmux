//! Lock helpers that never panic on a poisoned lock.
//!
//! A poisoned `Mutex` only means another thread panicked while it held the
//! guard. The daemon and the client keep serving after a contained panic
//! (plans/cmux-next/rust-panic-free.md), so a later `lock()` takes the data as
//! it is instead of turning one panic into a cascade of panics.

use std::sync::{
    Condvar, Mutex, MutexGuard, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard,
    WaitTimeoutResult,
};
use std::time::Duration;

pub(crate) trait MutexRecover<T: ?Sized> {
    /// `lock()`, taking the guard of a poisoned mutex.
    fn lock_or_recover(&self) -> MutexGuard<'_, T>;
}

impl<T: ?Sized> MutexRecover<T> for Mutex<T> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[allow(dead_code, reason = "shared helper; not every target uses RwLock")]
pub(crate) trait RwLockRecover<T: ?Sized> {
    /// `read()`, taking the guard of a poisoned lock.
    fn read_or_recover(&self) -> RwLockReadGuard<'_, T>;
    /// `write()`, taking the guard of a poisoned lock.
    fn write_or_recover(&self) -> RwLockWriteGuard<'_, T>;
}

impl<T: ?Sized> RwLockRecover<T> for RwLock<T> {
    fn read_or_recover(&self) -> RwLockReadGuard<'_, T> {
        self.read().unwrap_or_else(PoisonError::into_inner)
    }

    fn write_or_recover(&self) -> RwLockWriteGuard<'_, T> {
        self.write().unwrap_or_else(PoisonError::into_inner)
    }
}

pub(crate) trait CondvarRecover {
    /// `wait()`, taking the guard back when the mutex is poisoned.
    fn wait_or_recover<'a, T>(&self, guard: MutexGuard<'a, T>) -> MutexGuard<'a, T>;
    /// `wait_timeout()`, taking the guard back when the mutex is poisoned.
    fn wait_timeout_or_recover<'a, T>(
        &self,
        guard: MutexGuard<'a, T>,
        timeout: Duration,
    ) -> (MutexGuard<'a, T>, WaitTimeoutResult);
}

impl CondvarRecover for Condvar {
    fn wait_or_recover<'a, T>(&self, guard: MutexGuard<'a, T>) -> MutexGuard<'a, T> {
        self.wait(guard).unwrap_or_else(PoisonError::into_inner)
    }

    fn wait_timeout_or_recover<'a, T>(
        &self,
        guard: MutexGuard<'a, T>,
        timeout: Duration,
    ) -> (MutexGuard<'a, T>, WaitTimeoutResult) {
        self.wait_timeout(guard, timeout).unwrap_or_else(PoisonError::into_inner)
    }
}
