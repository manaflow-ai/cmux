//! A delta-state last-writer-wins map: chat and session state (titles, pins, read marks, drafts,
//! settings, a message's metadata) that every replica edits, online or not, and that converges.
//!
//! Each key holds one [`Entry`]: its value (or a tombstone), the [`Stamp`] of the edit that wrote it
//! and that edit's [`Dot`]. Merging two entries keeps the greater stamp, which is commutative,
//! associative and idempotent: replicas may exchange [`Delta`]s in any order, any number of times,
//! through any path (Mac -> VM -> phone, or straight), and end equal. This is
//! property-level last-writer-wins without the need for a server to be up: the server (here, the
//! chat's home daemon) still acks edits, and [`Replica::pending`] counts the local edits it has not
//! acked yet, which is what "offline, 3 changes waiting" shows.
//!
//! A [`Delta`] carries entries plus the version vector it brings its receiver to (`covers`), valid
//! only when the receiver already covers `since`. [`Replica::delta_since`] answers a reconnecting
//! replica's vector with exactly the entries it lacks; [`Replica::set`] returns a one-entry delta to
//! push at once. A delta that arrives with a gap (the receiver missed something before it) is still
//! merged, because merging is always safe, but the receiver's vector does not advance, so its next
//! [`delta_since`](Replica::delta_since) round fills the gap.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::hlc::{Actor, Clock, Stamp};
use crate::vv::{Dot, Vv};

/// One key's current value and the edit that wrote it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry<V> {
    /// `None` is a tombstone: the key was deleted. It is kept so a stale replica's older value
    /// cannot bring the key back.
    pub value: Option<V>,
    pub stamp: Stamp,
    pub dot: Dot,
}

/// What a sender ships: entries, and the vector a receiver that covered `since` covers after them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Delta<K, V> {
    pub since: Vv,
    pub covers: Vv,
    pub entries: Vec<(K, Entry<V>)>,
}

impl<K, V> Delta<K, V> {
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// What applying a delta did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Applied<K> {
    /// The keys whose entry changed, in key order: what the UI redraws.
    pub changed: Vec<K>,
    /// The receiver did not cover the delta's `since`: entries were merged, the vector did not
    /// advance, and a [`Replica::delta_since`] round from a peer will fill what is missing.
    pub gap: bool,
    /// The furthest any entry's stamp ran ahead of the receiver's wall clock (0 when none did).
    pub ahead_ms: u64,
}

/// The sync state at a glance, for the sidebar's status icon and the phone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum SyncState {
    /// Connected to the home and every local edit acked.
    Synced,
    /// Connected; `pending` local edits not acked yet.
    Syncing { pending: usize },
    /// Not connected; `pending` local edits kept, to merge without conflicts when it reconnects.
    Offline { pending: usize },
}

/// A replica's whole state, to persist so offline edits survive a restart.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snapshot<K, V> {
    pub clock: Clock,
    pub vv: Vv,
    pub acked: Vv,
    pub entries: Vec<(K, Entry<V>)>,
    #[serde(default)]
    pub history: Vec<(K, Entry<V>)>,
}

/// One replica of a map.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Replica<K: Ord, V> {
    clock: Clock,
    /// What this replica's state covers.
    vv: Vv,
    /// What the home last said it covers: local dots past it are pending.
    acked: Vv,
    entries: BTreeMap<K, Entry<V>>,
    /// Every edit still needed by a replica whose vector is behind. The materialized map keeps
    /// only the winner for each key, while this history lets a causal-gap receiver catch up after
    /// an older edit was overwritten locally.
    history: BTreeMap<Dot, (K, Entry<V>)>,
}

impl<K: Ord + Clone, V: Clone> Replica<K, V> {
    pub fn new(actor: Actor) -> Self {
        Self {
            clock: Clock::new(actor),
            vv: Vv::new(),
            acked: Vv::new(),
            entries: BTreeMap::new(),
            history: BTreeMap::new(),
        }
    }

    pub fn actor(&self) -> &Actor {
        self.clock.actor()
    }

    pub fn vv(&self) -> &Vv {
        &self.vv
    }

    pub fn get(&self, key: &K) -> Option<&V> {
        self.entries.get(key).and_then(|e| e.value.as_ref())
    }

    pub fn entry(&self, key: &K) -> Option<&Entry<V>> {
        self.entries.get(key)
    }

    /// The live keys and values, in key order (tombstones left out).
    pub fn iter(&self) -> impl Iterator<Item = (&K, &V)> {
        self.entries.iter().filter_map(|(k, e)| e.value.as_ref().map(|v| (k, v)))
    }

    /// Entries including tombstones.
    pub fn len_with_tombstones(&self) -> usize {
        self.entries.len()
    }

    /// Write `value` at `key`; returns the one-entry delta to push now.
    pub fn set(&mut self, key: K, value: V, wall_ms: u64) -> Delta<K, V> {
        self.write(key, Some(value), wall_ms)
    }

    /// Delete `key` (a tombstone); returns the one-entry delta to push now.
    pub fn delete(&mut self, key: K, wall_ms: u64) -> Delta<K, V> {
        self.write(key, None, wall_ms)
    }

    fn write(&mut self, key: K, value: Option<V>, wall_ms: u64) -> Delta<K, V> {
        let actor = self.actor().clone();
        let seq = self.vv.get(&actor) + 1;
        let mut stamp = self.clock.now(wall_ms);
        // A far-future remote stamp is deliberately not allowed to poison the HLC. A local
        // overwrite must still win that key, though, so advance only this key's stamp when the
        // wall clock is behind its current winner.
        if let Some(current) = self.entries.get(&key)
            && stamp <= current.stamp
        {
            stamp = current.stamp.clone();
            if stamp.n == u32::MAX {
                stamp.ms = stamp.ms.saturating_add(1);
                stamp.n = 0;
            } else {
                stamp.n += 1;
            }
            stamp.actor = actor.clone();
        }
        let dot = Dot { actor: actor.clone(), seq };
        self.vv.set(actor.clone(), seq);
        let entry = Entry { value, stamp, dot };
        self.entries.insert(key.clone(), entry.clone());
        self.history.insert(entry.dot.clone(), (key.clone(), entry.clone()));
        let mut since = Vv::new();
        since.set(actor.clone(), seq - 1);
        let mut covers = Vv::new();
        covers.set(actor, seq);
        Delta { since, covers, entries: vec![(key, entry)] }
    }

    /// The entries a replica at `theirs` lacks: those whose dot it does not cover. An entry it
    /// covers is one it holds or one it holds a newer edit for, so nothing it needs is left out.
    pub fn delta_since(&self, theirs: &Vv) -> Delta<K, V> {
        let entries = self
            .history
            .values()
            .filter(|(_, e)| !theirs.covers(&e.dot))
            .map(|(k, e)| (k.clone(), e.clone()))
            .collect();
        Delta { since: theirs.clone(), covers: self.vv.clone(), entries }
    }

    /// Merge a delta from any replica, in any order, any number of times.
    pub fn apply(&mut self, delta: &Delta<K, V>, wall_ms: u64) -> Applied<K> {
        let mut changed = Vec::new();
        let mut ahead_ms = 0;
        for (key, theirs) in &delta.entries {
            ahead_ms = ahead_ms.max(self.clock.observe(&theirs.stamp, wall_ms));
            self.history.entry(theirs.dot.clone()).or_insert_with(|| (key.clone(), theirs.clone()));
            let wins = match self.entries.get(key) {
                Some(mine) => theirs.stamp > mine.stamp,
                None => true,
            };
            if wins {
                self.entries.insert(key.clone(), theirs.clone());
                changed.push(key.clone());
            }
        }
        changed.sort();
        changed.dedup();
        let gap = !self.vv.dominates(&delta.since);
        if !gap {
            self.vv.join(&delta.covers);
        }
        Applied { changed, gap, ahead_ms }
    }

    /// The home says it covers `home`: local edits it covers are no longer pending.
    pub fn ack(&mut self, home: &Vv) {
        self.acked.join(home);
    }

    /// Local edits the home has not acked.
    pub fn pending(&self) -> usize {
        let me = self.actor();
        let acked = self.acked.get(me);
        usize::try_from(self.vv.get(me).saturating_sub(acked)).unwrap_or(usize::MAX)
    }

    pub fn state(&self, connected: bool) -> SyncState {
        match (connected, self.pending()) {
            (true, 0) => SyncState::Synced,
            (true, pending) => SyncState::Syncing { pending },
            (false, pending) => SyncState::Offline { pending },
        }
    }

    /// Drop tombstones every replica in `everyone` covers: none of them can hold the deleted value
    /// any more, so nothing can bring it back. `everyone` must be every replica that has ever
    /// synced; one left out could resurrect a key.
    pub fn compact(&mut self, everyone: &[Vv]) -> usize {
        let floor = Vv::meet(everyone);
        let before = self.entries.len();
        self.entries.retain(|_, e| e.value.is_some() || !floor.covers(&e.dot));
        self.history.retain(|_, (_, e)| !floor.covers(&e.dot));
        before - self.entries.len()
    }

    pub fn snapshot(&self) -> Snapshot<K, V> {
        Snapshot {
            clock: self.clock.clone(),
            vv: self.vv.clone(),
            acked: self.acked.clone(),
            entries: self.entries.iter().map(|(k, e)| (k.clone(), e.clone())).collect(),
            history: self.history.values().cloned().collect(),
        }
    }

    pub fn restore(snapshot: Snapshot<K, V>) -> Self {
        let entries: BTreeMap<K, Entry<V>> = snapshot.entries.into_iter().collect();
        let mut history: BTreeMap<Dot, (K, Entry<V>)> = snapshot
            .history
            .into_iter()
            .map(|(key, entry)| (entry.dot.clone(), (key, entry)))
            .collect();
        // Snapshots written before edit history was persisted still have their current winners.
        // They cannot recover overwritten edits, but retaining the winners keeps future deltas
        // correct and lets those snapshots upgrade without data loss.
        if history.is_empty() {
            history.extend(
                entries
                    .iter()
                    .map(|(key, entry)| (entry.dot.clone(), (key.clone(), entry.clone()))),
            );
        }
        Self { clock: snapshot.clock, vv: snapshot.vv, acked: snapshot.acked, entries, history }
    }
}

#[cfg(test)]
#[path = "map_tests.rs"]
mod tests;
