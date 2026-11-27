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
mod tests {
    use super::Mutex;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    /// The slow holder seam: a thread holds the lock for 2 s. Eight tasks wait on it on a
    /// two-worker runtime, and another task (a hello, a `status`) still runs in under 500 ms.
    /// With a std mutex, both workers park and it waits the whole 2 s.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn waiters_leave_the_workers_free() {
        let lock = Arc::new(Mutex::new(0u32));
        let (held_tx, held_rx) = std::sync::mpsc::channel();
        let holder = std::thread::spawn({
            let lock = lock.clone();
            move || {
                let _held = lock.lock().unwrap();
                held_tx.send(()).unwrap();
                std::thread::sleep(Duration::from_secs(2));
            }
        });
        held_rx.recv_timeout(Duration::from_secs(10)).expect("the slow holder never took the lock");
        let waiters: Vec<_> = (0..8)
            .map(|_| {
                let lock = lock.clone();
                tokio::spawn(async move { *lock.lock().unwrap() += 1 })
            })
            .collect();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let started = Instant::now();
        tokio::time::timeout(Duration::from_secs(5), tokio::spawn(async {}))
            .await
            .unwrap()
            .unwrap();
        let took = started.elapsed();
        assert!(took < Duration::from_millis(500), "a task waited {took:?} for a free worker");
        for waiter in waiters {
            tokio::time::timeout(Duration::from_secs(5), waiter).await.unwrap().unwrap();
        }
        holder.join().unwrap();
        assert_eq!(*lock.lock().unwrap(), 8);
    }

    /// A writer waits behind a long reader, and on macOS every new reader queues behind that
    /// writer: those readers' waits leave the workers too.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn rwlock_waiters_leave_the_workers_free() {
        let lock = Arc::new(super::RwLock::new(()));
        let (held_tx, held_rx) = std::sync::mpsc::channel();
        let reader = std::thread::spawn({
            let lock = lock.clone();
            move || {
                let _held = lock.read().unwrap();
                held_tx.send(()).unwrap();
                std::thread::sleep(Duration::from_secs(2));
            }
        });
        held_rx.recv_timeout(Duration::from_secs(10)).expect("the slow holder never took the lock");
        let writer = tokio::spawn({
            let lock = lock.clone();
            async move { drop(lock.write().unwrap()) }
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        let readers: Vec<_> = (0..8)
            .map(|_| {
                let lock = lock.clone();
                tokio::spawn(async move { drop(lock.read().unwrap()) })
            })
            .collect();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let started = Instant::now();
        tokio::time::timeout(Duration::from_secs(5), tokio::spawn(async {}))
            .await
            .unwrap()
            .unwrap();
        let took = started.elapsed();
        assert!(took < Duration::from_millis(500), "a task waited {took:?} for a free worker");
        tokio::time::timeout(Duration::from_secs(5), writer).await.unwrap().unwrap();
        for reader in readers {
            tokio::time::timeout(Duration::from_secs(5), reader).await.unwrap().unwrap();
        }
        reader.join().unwrap();
    }

    #[test]
    fn a_poisoned_lock_still_answers() {
        let lock = Arc::new(Mutex::new(()));
        let poisoner = lock.clone();
        let _ = std::thread::spawn(move || {
            let _held = poisoner.lock().unwrap();
            panic!("poison it");
        })
        .join();
        assert!(lock.lock().is_err());
        drop(lock.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
    }
}
