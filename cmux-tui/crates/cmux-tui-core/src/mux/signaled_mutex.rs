//! `SignaledMutex`: a mutex whose unlock wakes deadline waiters and whose
//! acquisitions feed hold and wait telemetry (`server-stats`).

use std::ops::{Deref, DerefMut};
use std::sync::{Condvar, LockResult, Mutex, MutexGuard, PoisonError, TryLockError, TryLockResult};
use std::time::Instant;

pub(crate) struct SignaledMutex<T> {
    value: Mutex<T>,
    release_epoch: Mutex<u64>,
    released: Condvar,
    /// Contention record with `#[track_caller]` attribution, reported by
    /// `server-stats` so lock convoys are visible without external sampling.
    stats: crate::diagnostics::LockStats,
}

impl<T> SignaledMutex<T> {
    pub(super) fn new(value: T) -> Self {
        Self {
            value: Mutex::new(value),
            release_epoch: Mutex::new(0),
            released: Condvar::new(),
            stats: crate::diagnostics::LockStats::new(),
        }
    }

    pub(super) fn stats(&self) -> &crate::diagnostics::LockStats {
        &self.stats
    }

    fn guard<'a>(
        &'a self,
        value: MutexGuard<'a, T>,
        site: crate::diagnostics::LockSite,
        waited_from: Instant,
        blocker: Option<crate::diagnostics::LockSite>,
    ) -> SignaledMutexGuard<'a, T> {
        self.stats.acquired(site, waited_from.elapsed(), blocker);
        SignaledMutexGuard { value: Some(value), owner: self, site, acquired_at: Instant::now() }
    }

    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<SignaledMutexGuard<'_, T>> {
        let site = std::panic::Location::caller();
        let waited_from = Instant::now();
        let blocker = self.stats.wait_started();
        match self.value.lock() {
            Ok(value) => Ok(self.guard(value, site, waited_from, blocker)),
            Err(error) => {
                Err(PoisonError::new(self.guard(error.into_inner(), site, waited_from, blocker)))
            }
        }
    }

    #[cfg(test)]
    #[track_caller]
    pub(super) fn try_lock(&self) -> TryLockResult<SignaledMutexGuard<'_, T>> {
        self.try_lock_at(std::panic::Location::caller(), Instant::now(), None)
    }

    fn try_lock_at(
        &self,
        site: crate::diagnostics::LockSite,
        waited_from: Instant,
        blocker: Option<crate::diagnostics::LockSite>,
    ) -> TryLockResult<SignaledMutexGuard<'_, T>> {
        match self.value.try_lock() {
            Ok(value) => Ok(self.guard(value, site, waited_from, blocker)),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(error)) => Err(TryLockError::Poisoned(PoisonError::new(
                self.guard(error.into_inner(), site, waited_from, blocker),
            ))),
        }
    }

    #[track_caller]
    pub(super) fn lock_until(
        &self,
        deadline: Instant,
    ) -> anyhow::Result<SignaledMutexGuard<'_, T>> {
        let site = std::panic::Location::caller();
        let waited_from = Instant::now();
        let blocker = self.stats.wait_started();
        loop {
            match self.try_lock_at(site, waited_from, blocker) {
                Ok(value) => return Ok(value),
                Err(TryLockError::Poisoned(_)) => {
                    self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                    anyhow::bail!("mutex is poisoned")
                }
                Err(TryLockError::WouldBlock) => {}
            }

            let observed = *self.release_epoch.lock().unwrap();
            match self.try_lock_at(site, waited_from, blocker) {
                Ok(value) => return Ok(value),
                Err(TryLockError::Poisoned(_)) => {
                    self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                    anyhow::bail!("mutex is poisoned")
                }
                Err(TryLockError::WouldBlock) => {}
            }

            let mut epoch = self.release_epoch.lock().unwrap();
            if *epoch != observed {
                continue;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                return Err(crate::JournalContention::MUTEX_DEADLINE.into());
            }
            let (next, result) = self.released.wait_timeout(epoch, remaining).unwrap();
            epoch = next;
            if result.timed_out() && *epoch == observed {
                self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                return Err(crate::JournalContention::MUTEX_DEADLINE.into());
            }
        }
    }
}

pub(crate) struct SignaledMutexGuard<'a, T> {
    value: Option<MutexGuard<'a, T>>,
    owner: &'a SignaledMutex<T>,
    site: crate::diagnostics::LockSite,
    acquired_at: Instant,
}

impl<T> Deref for SignaledMutexGuard<'_, T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        self.value.as_deref().expect("signaled mutex guard has a value")
    }
}

impl<T> DerefMut for SignaledMutexGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.value.as_deref_mut().expect("signaled mutex guard has a value")
    }
}

impl<T> Drop for SignaledMutexGuard<'_, T> {
    fn drop(&mut self) {
        // Clear holder attribution before the inner mutex is released, so a
        // waiter that acquires next can never have its holder record erased
        // by this older unlock.
        self.owner.stats.released(self.site, self.acquired_at.elapsed());
        drop(self.value.take());
        let mut epoch = self.owner.release_epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.owner.released.notify_all();
    }
}
