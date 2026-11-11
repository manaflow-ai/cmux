//! Part of `Hub`; see `hub/mod.rs`. The peers' rows (`Hub::remote_sessions`) as a published
//! snapshot: readers load the current table with no lock and never stall a writer; writers
//! serialize among themselves, change a structurally shared copy (`remote_rows.rs`, persistent
//! maps, so the copy is O(1)) and publish it. A reader as slow as it likes (a walk over 12,000
//! rows) costs a peer notice nothing: before, every reader held the one mutex each peer notice
//! needed, and a Mac linked to ~30 peers listing 12,000 sessions starved its peer updates behind
//! lookups walking every row (cmux#40935's class).
//!
//! The writer lock is still the ordering fence it was: a writer publishes before it releases
//! it, so whoever takes it next (a writer, [`RemoteTable::fence`], [`RemoteTable::settled`])
//! sees every earlier write. Lock order is unchanged: `peer_leases`, then `peers`, then this
//! writer lock; a [`RemoteTable::read`] takes no lock and may be taken anywhere.

use super::remote_rows::RemoteRows;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

#[derive(Default)]
pub(crate) struct RemoteTable {
    /// One writer at a time; also the ordering fence.
    writer: Mutex<()>,
    current: arc_swap::ArcSwap<RemoteRows>,
}

impl RemoteTable {
    /// The table as last published, with no lock: a consistent snapshot, which is what a reader
    /// saw under the old lock. A write made while it is held does not change it. Hold it briefly;
    /// a reader that keeps the rows for long takes [`Self::snapshot`].
    pub(crate) fn read(&self) -> arc_swap::Guard<Arc<RemoteRows>> {
        self.current.load()
    }

    /// [`Self::read`] as an owned handle, for a reader that keeps the rows through a long walk.
    pub(crate) fn snapshot(&self) -> Arc<RemoteRows> {
        self.current.load_full()
    }

    /// The table once every writer in flight has published, for a read that pairs the rows with
    /// state a writer changes before it publishes (a peer's `remote_rows_epoch`, its
    /// `cache_dirty_seq`): a writer bumps those under the writer lock, so a plain [`Self::read`]
    /// could see the new epoch with the old rows. The lock is held only to load the handle.
    pub(crate) fn settled(&self) -> Arc<RemoteRows> {
        let _writer = self.fence();
        self.current.load_full()
    }

    /// Changes the table: waits for any other writer, then changes a copy of the current table
    /// (O(1): its maps share every node until written), published when the guard drops.
    pub(crate) fn write(&self) -> WriteGuard<'_> {
        WriteGuard::new(self, self.fence())
    }

    /// [`Self::write`] if no writer holds the lock now.
    #[cfg(test)]
    pub(crate) fn try_write(&self) -> Option<WriteGuard<'_>> {
        let lock = match self.writer.try_lock() {
            Ok(lock) => lock,
            Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return None,
        };
        Some(WriteGuard::new(self, lock))
    }

    /// The writer lock with no change: waits for writers in flight (each has published when it
    /// returns) and keeps others out while held. For a step ordered against row writes that
    /// changes no row (a peer registered, a purge tombstone retired, a capture kept).
    pub(crate) fn fence(&self) -> MutexGuard<'_, ()> {
        self.writer.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// A writer's copy of the table; dereferences to [`RemoteRows`] and publishes it on drop.
pub(crate) struct WriteGuard<'a> {
    table: &'a RemoteTable,
    /// The copy being changed; taken (an O(1) swap with empty maps) when published.
    rows: RemoteRows,
    _writer: MutexGuard<'a, ()>,
}

impl<'a> WriteGuard<'a> {
    fn new(table: &'a RemoteTable, writer: MutexGuard<'a, ()>) -> Self {
        let rows = RemoteRows::clone(&table.current.load());
        Self { table, rows, _writer: writer }
    }
}

impl std::ops::Deref for WriteGuard<'_> {
    type Target = RemoteRows;
    fn deref(&self) -> &RemoteRows {
        &self.rows
    }
}

impl std::ops::DerefMut for WriteGuard<'_> {
    fn deref_mut(&mut self) -> &mut RemoteRows {
        &mut self.rows
    }
}

impl Drop for WriteGuard<'_> {
    /// Publishes while the writer lock is still held (fields drop after this body), so the next
    /// writer starts from this table and no write is lost.
    fn drop(&mut self) {
        self.table.current.store(Arc::new(std::mem::take(&mut self.rows)));
    }
}

#[cfg(test)]
mod tests {
    use super::super::*;
    use super::*;
    use crate::session_identity::SessionReceipt;
    use std::sync::mpsc;
    use std::time::Duration;

    fn row(peer: &str, mux: &str) -> (String, RemoteSession) {
        let receipt = SessionReceipt::new(peer, mux, None, 0);
        let summary = json!({"sessionId": mux, "peer": peer, "status": "running"});
        (receipt.qualified_id(), RemoteSession { peer: peer.into(), summary, receipt })
    }

    fn table_of(peers: usize, per_peer: usize) -> RemoteTable {
        let table = RemoteTable::default();
        {
            let mut rows = table.write();
            for p in 0..peers {
                for s in 0..per_peer {
                    let (key, r) = row(&format!("peer-{p}"), &format!("s{s}"));
                    rows.insert(key, r);
                }
            }
        }
        table
    }

    /// cmux#40935's class: a reader in the middle of a walk over 12,000 rows, as long as it
    /// likes, never holds up a write. Under the old mutex the write below waited forever.
    #[test]
    fn a_slow_reader_never_stalls_a_writer() {
        let table = Arc::new(table_of(30, 400));
        let (started_tx, started) = mpsc::channel();
        let (release, release_rx) = mpsc::channel::<()>();
        let reader = {
            let table = table.clone();
            std::thread::spawn(move || {
                let rows = table.read();
                started_tx.send(()).unwrap();
                // Still "walking" until released.
                release_rx.recv().unwrap();
                rows.len()
            })
        };
        started.recv().unwrap();
        let (done_tx, done) = mpsc::channel();
        let writer = {
            let table = table.clone();
            std::thread::spawn(move || {
                let (key, r) = row("peer-new", "s0");
                table.write().insert(key, r);
                done_tx.send(()).unwrap();
            })
        };
        let finished = done.recv_timeout(Duration::from_secs(5));
        // Released either way, so a failure reports instead of hanging.
        release.send(()).unwrap();
        assert!(finished.is_ok(), "a write waited behind a reader holding a snapshot");
        writer.join().unwrap();
        assert_eq!(reader.join().unwrap(), 12_000, "the reader kept the version it loaded");
        assert_eq!(table.read().len(), 12_001, "the write is published");
    }

    /// Writers take turns, each starting from the one before's table: none is lost.
    #[test]
    fn writers_serialize_and_publish_in_order() {
        let table = Arc::new(RemoteTable::default());
        let writers: Vec<_> = ["a", "b"]
            .into_iter()
            .map(|peer| {
                let table = table.clone();
                std::thread::spawn(move || {
                    for s in 0..1_000 {
                        let (key, r) = row(peer, &format!("s{s}"));
                        table.write().insert(key, r);
                    }
                })
            })
            .collect();
        for w in writers {
            w.join().unwrap();
        }
        let rows = table.read();
        assert_eq!(rows.len(), 2_000);
        assert_eq!(rows.writes, 2_000);
        assert_eq!(rows.peer_counts().get("a"), Some(&1_000));
    }

    /// A fence waits for a writer in flight and holds the next one off; `settled` sees every
    /// write that published before it.
    #[test]
    fn a_fence_orders_against_writers() {
        let table = Arc::new(table_of(1, 1));
        let fence = table.fence();
        assert!(table.try_write().is_none(), "a fence keeps writers out");
        let writer = {
            let table = table.clone();
            std::thread::spawn(move || {
                let (key, r) = row("peer-1", "s0");
                table.write().insert(key, r);
            })
        };
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(table.read().len(), 1, "no write lands while the fence is held");
        drop(fence);
        writer.join().unwrap();
        assert_eq!(table.settled().len(), 2);
        assert!(table.try_write().is_some());
    }
}
