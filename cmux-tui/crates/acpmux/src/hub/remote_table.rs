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

/// Takings of any table's writer lock that found it held ([`RemoteTable::contended`]).
static CONTENDED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

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
    #[track_caller]
    pub(crate) fn write(&self) -> WriteGuard<'_> {
        let writer = self.fence();
        let mut guard = WriteGuard::new(self, writer);
        guard.held = Some(super::held_lock::HeldTimer::start("remote_sessions"));
        guard
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
    ///
    /// A taken lock is waited for off the runtime's worker ([`crate::qos::off_worker`]): the
    /// worker hands its other tasks on first. Waited for in place, each of ~200 peers' notice
    /// loops parked a worker on this mutex while a holder sat preempted (cosmic-gray,
    /// 2026-11-27: load 187 on 15 CPUs, "std mutex held long" on this lock 1646 times), and with
    /// every worker parked nothing else ran: `acpmux session inbox` hung 60 s and prompt
    /// admission leases lapsed. A free lock is taken in place, as before.
    pub(crate) fn fence(&self) -> MutexGuard<'_, ()> {
        match self.writer.try_lock() {
            Ok(lock) => lock,
            Err(std::sync::TryLockError::Poisoned(e)) => e.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => {
                CONTENDED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                crate::qos::off_worker(|| {
                    self.writer.lock().unwrap_or_else(PoisonError::into_inner)
                })
            }
        }
    }

    /// How many takings of the writer lock found it held and waited off the worker, since
    /// start (a gauge for `daemon status`-style reads and the tests).
    pub(crate) fn contended() -> u64 {
        CONTENDED.load(std::sync::atomic::Ordering::Relaxed)
    }
}

/// A writer's copy of the table; dereferences to [`RemoteRows`] and publishes it on drop.
pub(crate) struct WriteGuard<'a> {
    table: &'a RemoteTable,
    /// The copy being changed; taken (an O(1) swap with empty maps) when published.
    rows: RemoteRows,
    /// Ends before the writer unlocks and the replaced table is freed: cleanup after the
    /// unlock is not time spent holding the writer lock.
    held: Option<super::held_lock::HeldTimer>,
    _writer: MutexGuard<'a, ()>,
    /// The table this one replaced, freed after the writer lock is released (fields drop in
    /// order), so the next writer never waits on the nodes no reader shares any more.
    replaced: Option<Arc<RemoteRows>>,
}

impl<'a> WriteGuard<'a> {
    fn new(table: &'a RemoteTable, writer: MutexGuard<'a, ()>) -> Self {
        let rows = RemoteRows::clone(&table.current.load());
        under_writer::enter();
        Self { table, rows, _writer: writer, replaced: None, held: None }
    }
}

/// The work a thread does while it holds the rows writer lock, counted in tests: each row of a
/// peer it walks (`RemoteRows::of_peer`) and each row it builds from JSON (`PeerRow::new`). A
/// peer's refresh (an idle close, a drop, a row that closes, a restart's saved rows) must build
/// its rows before the lock and walk none of them under it: every other peer's notices wait on
/// this lock (cosmic-gray, 2026-11-27: held 53 to 181 ms at each of those four writers, the
/// daemon at 94% CPU). A no-op outside tests.
pub(crate) mod under_writer {
    #[cfg(test)]
    thread_local! {
        static HELD: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
        static HOLDS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
        static WALKED: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
        static BUILT: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
    }

    #[inline]
    pub(crate) fn enter() {
        #[cfg(test)]
        {
            HELD.with(|h| h.set(h.get() + 1));
            HOLDS.with(|h| h.set(h.get() + 1));
        }
    }

    #[inline]
    pub(crate) fn leave() {
        #[cfg(test)]
        HELD.with(|h| h.set(h.get().saturating_sub(1)));
    }

    /// One of a peer's rows walked.
    #[inline]
    pub(crate) fn walked() {
        #[cfg(test)]
        if HELD.with(std::cell::Cell::get) > 0 {
            WALKED.with(|w| w.set(w.get() + 1));
        }
    }

    /// One row built from JSON.
    #[inline]
    pub(crate) fn built() {
        #[cfg(test)]
        if HELD.with(std::cell::Cell::get) > 0 {
            BUILT.with(|b| b.set(b.get() + 1));
        }
    }

    /// What this thread did under the writer lock since the last call: how many times it took
    /// it, and the rows it walked and built while holding it.
    #[cfg(test)]
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(crate) struct Cost {
        pub(crate) holds: u64,
        pub(crate) walked: u64,
        pub(crate) built: u64,
    }

    #[cfg(test)]
    pub(crate) fn take() -> Cost {
        Cost {
            holds: HOLDS.with(|h| h.replace(0)),
            walked: WALKED.with(|w| w.replace(0)),
            built: BUILT.with(|b| b.replace(0)),
        }
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
        under_writer::leave();
        self.replaced = Some(self.table.current.swap(Arc::new(std::mem::take(&mut self.rows))));
    }
}

#[cfg(test)]
#[path = "remote_table_tests.rs"]
mod tests;
