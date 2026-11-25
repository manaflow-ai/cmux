//! Part of `Hub`; see `hub/mod.rs`. The peer registry (`Hub::peers`) as a published snapshot,
//! as `remote_table.rs` keeps the peers' rows: a lookup ([`PeerTable::get`], [`PeerTable::load`])
//! takes no lock and never waits on a writer; writers serialize among themselves on
//! [`PeerTable::lock`], and each change is published the moment it is made.
//!
//! Why: Leo's NIGHTLY daemon wedged twice on 2026-11-25 (cmux 86f5bbbb0). Its samples had every
//! tokio worker (64 of 64 in the second) parked in `__psynch_mutexwait` on this one std mutex,
//! called from `Hub::peer`: every peer notice took it and, still holding it, waited on the rows
//! writer lock (`apply_peer_notice_rows`, `trim_closed_peer_rows`, ...), while every lookup of a
//! peer by name anywhere in the daemon (an outbox attempt, a key route, a read ahead) waited
//! behind them. Outbox deliveries got no answer within 120 s, hellos none within 10 s. Leo:
//! "wtf is not sent: no answer from cmux on Mango!? HELP".
//!
//! The lock is still the ordering fence it was for a change of the registry (lock order:
//! `peer_leases`, then `peers`, then the rows writer lock), and a change is published before
//! the guard's next step, so a step after it under the rows writer lock (a removal's row purge)
//! is ordered after it. A row writer that needs "is this instance still the one registered"
//! takes the rows writer lock and then [`PeerTable::get`]: a registration or removal publishes
//! under (or before) the rows writer lock it takes, so the check sees it or is done before it.
//!
//! The lease registry uses the same table with generation values: public listing reads its
//! snapshot without waiting behind a lease mutation blocked on the peer or row writer. Cache
//! persistence keeps taking the lease lock, preserving its ordering with lease publication.

use crate::peer::Peer;
use std::collections::HashMap;
use std::sync::{Arc, LockResult, Mutex, MutexGuard, PoisonError};

type Map<V> = HashMap<String, V>;

pub(crate) struct PeerTable<V = Arc<Peer>> {
    /// One writer at a time; also the ordering fence for a change of the registry.
    writer: Mutex<()>,
    current: arc_swap::ArcSwap<Map<V>>,
    name: &'static str,
}

impl<V> Default for PeerTable<V> {
    fn default() -> Self {
        Self::named("peers")
    }
}

impl<V> PeerTable<V> {
    pub(crate) fn named(name: &'static str) -> Self {
        Self { writer: Mutex::new(()), current: Default::default(), name }
    }
}

impl<V: Clone> PeerTable<V> {
    /// The peer registered under `name` now, with no lock.
    pub(crate) fn get(&self, name: &str) -> Option<V> {
        self.current.load().get(name).cloned()
    }

    /// Every registered peer now, with no lock: a consistent snapshot.
    pub(crate) fn load(&self) -> Arc<Map<V>> {
        self.current.load_full()
    }

    /// The registry for a change: waits for any other writer. Reads through the guard see the
    /// registry as of the lock plus the guard's own changes; each change is published at once.
    /// The `LockResult` keeps the std mutex's call shape (`.lock().unwrap()`).
    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<PeerGuard<'_, V>> {
        let (writer, poisoned) = match self.writer.lock() {
            Ok(w) => (w, false),
            Err(e) => (e.into_inner(), true),
        };
        let guard = PeerGuard {
            table: self,
            view: self.current.load_full(),
            _held: super::held_lock::HeldTimer::start(self.name),
            _writer: writer,
        };
        if poisoned { Err(PoisonError::new(guard)) } else { Ok(guard) }
    }
}

pub(crate) struct PeerGuard<'a, V> {
    table: &'a PeerTable<V>,
    view: Arc<Map<V>>,
    /// How long the registry's writer lock is held (`held_lock.rs`, a log line only); dropped
    /// before the lock, as fields drop in order.
    _held: super::held_lock::HeldTimer,
    _writer: MutexGuard<'a, ()>,
}

impl<V: Clone> PeerGuard<'_, V> {
    fn change<T>(&mut self, f: impl FnOnce(&mut Map<V>) -> T) -> T {
        // A registry is a few dozen entries: a copy per change is cheap, and a change is rare.
        let mut next = (*self.view).clone();
        let out = f(&mut next);
        self.view = Arc::new(next);
        self.table.current.store(self.view.clone());
        out
    }

    pub(crate) fn insert(&mut self, name: String, peer: V) -> Option<V> {
        self.change(|m| m.insert(name, peer))
    }

    pub(crate) fn remove(&mut self, name: &str) -> Option<V> {
        if !self.view.contains_key(name) {
            return None;
        }
        self.change(|m| m.remove(name))
    }

    pub(crate) fn clear(&mut self) {
        self.change(HashMap::clear);
    }
}

impl<V> std::ops::Deref for PeerGuard<'_, V> {
    type Target = Map<V>;
    fn deref(&self) -> &Map<V> {
        &self.view
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wedge_a_lookup_never_waits_on_a_held_writer_and_sees_each_change_at_once() {
        let table = Arc::new(PeerTable::<Arc<Peer>>::default());
        let mut guard = table.lock().unwrap();
        // Another thread's lookup while the writer is held: answered, not parked.
        let t = table.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || tx.send(t.get("a").is_none()).unwrap());
        assert_eq!(rx.recv_timeout(std::time::Duration::from_secs(5)), Ok(true));
        guard.clear();
        assert!(table.load().is_empty());
        drop(guard);
    }
}
