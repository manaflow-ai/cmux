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

use std::sync::{LockResult, MutexGuard, TryLockError};

#[derive(Default, Debug)]
pub(crate) struct Mutex<T>(std::sync::Mutex<T>);

impl<T> Mutex<T> {
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
        held_rx.recv().unwrap();
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
