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

use crate::peer::Peer;
use std::collections::HashMap;
use std::sync::{Arc, LockResult, Mutex, MutexGuard, PoisonError};

type Map = HashMap<String, Arc<Peer>>;

#[derive(Default)]
pub(crate) struct PeerTable {
    /// One writer at a time; also the ordering fence for a change of the registry.
    writer: Mutex<()>,
    current: arc_swap::ArcSwap<Map>,
}

impl PeerTable {
    /// The peer registered under `name` now, with no lock.
    pub(crate) fn get(&self, name: &str) -> Option<Arc<Peer>> {
        self.current.load().get(name).cloned()
    }

    /// Every registered peer now, with no lock: a consistent snapshot.
    pub(crate) fn load(&self) -> Arc<Map> {
        self.current.load_full()
    }

    /// The registry for a change: waits for any other writer. Reads through the guard see the
    /// registry as of the lock plus the guard's own changes; each change is published at once.
    /// The `LockResult` keeps the std mutex's call shape (`.lock().unwrap()`).
    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<PeerGuard<'_>> {
        let (writer, poisoned) = match self.writer.lock() {
            Ok(w) => (w, false),
            Err(e) => (e.into_inner(), true),
        };
        let guard = PeerGuard {
            table: self,
            view: self.current.load_full(),
            _held: super::held_lock::HeldTimer::start("peers"),
            _writer: writer,
        };
        if poisoned { Err(PoisonError::new(guard)) } else { Ok(guard) }
    }
}

pub(crate) struct PeerGuard<'a> {
    table: &'a PeerTable,
    view: Arc<Map>,
    /// How long the registry's writer lock is held (`held_lock.rs`, a log line only); dropped
    /// before the lock, as fields drop in order.
    _held: super::held_lock::HeldTimer,
    _writer: MutexGuard<'a, ()>,
}

impl PeerGuard<'_> {
    fn change<T>(&mut self, f: impl FnOnce(&mut Map) -> T) -> T {
        // A registry is a few dozen entries: a copy per change is cheap, and a change is rare.
        let mut next = (*self.view).clone();
        let out = f(&mut next);
        self.view = Arc::new(next);
        self.table.current.store(self.view.clone());
        out
    }

    pub(crate) fn insert(&mut self, name: String, peer: Arc<Peer>) -> Option<Arc<Peer>> {
        self.change(|m| m.insert(name, peer))
    }

    pub(crate) fn remove(&mut self, name: &str) -> Option<Arc<Peer>> {
        if !self.view.contains_key(name) {
            return None;
        }
        self.change(|m| m.remove(name))
    }

    #[cfg(test)]
    pub(crate) fn clear(&mut self) {
        self.change(HashMap::clear);
    }
}

impl std::ops::Deref for PeerGuard<'_> {
    type Target = Map;
    fn deref(&self) -> &Map {
        &self.view
    }
}

#[cfg(test)]
#[path = "peer_table_tests.rs"]
mod tests;
