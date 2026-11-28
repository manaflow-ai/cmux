//! A std mutex whose waiters never park a tokio worker.
//!
//! A sync lock that async code takes is a trap under load. A holder that is slow for any
//! reason (a write and sync, a clone of a large book, page faults on a swapping Mac) holds
//! every waiter, and on a worker each waiter is a whole worker gone. Leo's daemon, 2026-11-22
//! (load 73 on 15 cores): its workers sat in `__psynch_mutexwait` on the outbox's book
//! (`Hub::status`, `deliver`, a peer journal restore), and `ls` and every hello found no
//! worker to run on. Here a take tries the lock first. Only a wait for another holder runs off
//! the runtime's workers ([`crate::qos::off_worker`]): the worker hands its other tasks to a
//! new one, and only this task waits. A thread outside the runtime waits in place.
//!
//! [`RwLock`] is the same for a std RwLock, which on macOS queues every new reader behind a
//! waiting writer: Leo's second sample, 6 min later, had 16 workers waiting to read
//! `ForkView::dropping` (every chat's log read) behind one fork's meta save, itself behind a
//! long read.

use std::sync::{LockResult, MutexGuard, RwLockReadGuard, RwLockWriteGuard, TryLockError};

#[derive(Default, Debug)]
pub(crate) struct Mutex<T>(std::sync::Mutex<T>);

impl<T> Mutex<T> {
    #[cfg(test)]
    pub(crate) const fn new(value: T) -> Self {
        Self(std::sync::Mutex::new(value))
    }

    /// The lock if no one holds it now (a poisoned one too), else None. Never waits.
    pub(crate) fn try_lock(&self) -> Option<MutexGuard<'_, T>> {
        match self.0.try_lock() {
            Ok(guard) => Some(guard),
            Err(TryLockError::Poisoned(poisoned)) => Some(poisoned.into_inner()),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    /// [`std::sync::Mutex::lock`], but a wait for another holder leaves the runtime's workers.
    pub(crate) fn lock(&self) -> LockResult<MutexGuard<'_, T>> {
        match self.0.try_lock() {
            Ok(guard) => Ok(guard),
            Err(TryLockError::Poisoned(poisoned)) => Err(poisoned),
            Err(TryLockError::WouldBlock) => crate::qos::off_worker(|| self.0.lock()),
        }
    }
}

/// A std RwLock whose waits leave the runtime's workers, as [`Mutex`]'s do.
#[derive(Default, Debug)]
pub(crate) struct RwLock<T>(std::sync::RwLock<T>);

impl<T> RwLock<T> {
    #[cfg(test)]
    pub(crate) const fn new(value: T) -> Self {
        Self(std::sync::RwLock::new(value))
    }

    /// [`std::sync::RwLock::read`], but a wait leaves the runtime's workers.
    pub(crate) fn read(&self) -> LockResult<RwLockReadGuard<'_, T>> {
        match self.0.try_read() {
            Ok(guard) => Ok(guard),
            Err(TryLockError::Poisoned(poisoned)) => Err(poisoned),
            Err(TryLockError::WouldBlock) => crate::qos::off_worker(|| self.0.read()),
        }
    }

    /// [`std::sync::RwLock::write`], but a wait leaves the runtime's workers.
    pub(crate) fn write(&self) -> LockResult<RwLockWriteGuard<'_, T>> {
        match self.0.try_write() {
            Ok(guard) => Ok(guard),
            Err(TryLockError::Poisoned(poisoned)) => Err(poisoned),
            Err(TryLockError::WouldBlock) => crate::qos::off_worker(|| self.0.write()),
        }
    }

    /// The write lock if no one holds the lock now (a poisoned one too), else None. Never
    /// waits, so it never stands in the queue that every new reader joins behind a waiting
    /// writer (module docs): what can be done on a later pass takes this.
    pub(crate) fn try_write(&self) -> Option<RwLockWriteGuard<'_, T>> {
        match self.0.try_write() {
            Ok(guard) => Some(guard),
            Err(TryLockError::Poisoned(poisoned)) => Some(poisoned.into_inner()),
            Err(TryLockError::WouldBlock) => None,
        }
    }

    /// Whether a write would wait now (tests: a note before the wait).
    #[cfg(test)]
    pub(crate) fn write_would_wait(&self) -> bool {
        matches!(self.0.try_write(), Err(TryLockError::WouldBlock))
    }
}

#[cfg(test)]
#[path = "worker_lock_tests.rs"]
mod tests;
