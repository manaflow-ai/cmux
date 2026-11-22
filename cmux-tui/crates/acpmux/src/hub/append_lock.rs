//! A chat's append lock (`Session::append_lock`), whose waiters never park a runtime worker.
//!
//! The holder writes the chat's log (and, the first time, scans it) under the lock. On a loaded
//! Mac that write can take seconds, and every other append to the chat waits behind it. Those
//! waits ran on tokio workers: Leo's daemon, 2026-11-22 (load 73 on 15 cores), had its workers
//! parked in `__psynch_mutexwait` behind one slow writer, so a hello, a `status` or an `ls`
//! found no worker to run on and stalled past its 4 s connect budget. A wait here leaves the
//! runtime first ([`crate::qos::off_worker`]): the worker hands its other tasks to a new one,
//! and only this task waits. An uncontended take costs one `try_lock`.

use std::sync::{LockResult, Mutex, MutexGuard, TryLockError};

#[derive(Default)]
pub(crate) struct AppendLock(Mutex<()>);

impl AppendLock {
    /// [`Mutex::lock`], but a wait for another holder runs off the runtime's workers.
    pub(crate) fn lock(&self) -> LockResult<MutexGuard<'_, ()>> {
        match self.0.try_lock() {
            Ok(guard) => Ok(guard),
            Err(TryLockError::Poisoned(poisoned)) => Err(poisoned),
            Err(TryLockError::WouldBlock) => crate::qos::off_worker(|| self.0.lock()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::*;
    use serde_json::json;
    use std::time::{Duration, Instant};

    fn test_hub() -> Arc<Hub> {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    /// The slow-disk seam: a writer that holds the append lock for 2 s, as a log write did on
    /// Leo's swapping Mac. Eight appends queue behind it on a two-worker runtime; `status` (what
    /// `ls` and every pane's connect wait on) must still answer in under 500 ms. Before this
    /// lock, both workers parked in the appends' waits and `status` took the whole 2 s.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn status_answers_while_a_slow_writer_holds_a_chats_append_lock() {
        let hub = test_hub();
        let session = hub
            .new_session(NewRequest {
                harness: Some("fake".into()),
                name: Some("slow-writer".into()),
                cwd: Some(std::env::temp_dir()),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        let (held_tx, held_rx) = std::sync::mpsc::channel();
        let writer = std::thread::spawn({
            let session = session.clone();
            move || {
                let _held = session.append_lock.lock().unwrap();
                held_tx.send(()).unwrap();
                std::thread::sleep(Duration::from_secs(2));
            }
        });
        held_rx.recv().unwrap();
        let appends: Vec<_> = (0..8)
            .map(|i| {
                let (hub, session) = (hub.clone(), session.clone());
                tokio::spawn(async move {
                    hub.append_quiet(&session, "mux", "note", json!({ "i": i }));
                })
            })
            .collect();
        // Let the appends reach the lock and wait on it.
        tokio::time::sleep(Duration::from_millis(100)).await;
        let started = Instant::now();
        let status = tokio::spawn({
            let hub = hub.clone();
            async move { hub.status().await }
        });
        let status = tokio::time::timeout(Duration::from_secs(5), status).await.unwrap().unwrap();
        let took = started.elapsed();
        assert!(took < Duration::from_millis(500), "status took {took:?} behind a slow writer");
        assert_eq!(status["sessions"], json!(1), "{status}");
        for append in appends {
            tokio::time::timeout(Duration::from_secs(5), append).await.unwrap().unwrap();
        }
        writer.join().unwrap();
    }

    #[test]
    fn a_poisoned_lock_still_answers() {
        let lock = std::sync::Arc::new(AppendLock::default());
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
