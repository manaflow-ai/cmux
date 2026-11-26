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
mod tests {
    use super::*;
    use crate::hlc::MAX_DRIFT_MS;

    type R = Replica<String, String>;

    fn r(id: &str) -> R {
        Replica::new(Actor::new(id))
    }

    fn k(s: &str) -> String {
        s.to_owned()
    }

    #[test]
    fn the_later_edit_wins_on_every_replica_whatever_the_order() {
        let (mut mac, mut phone) = (r("mac"), r("phone"));
        let a = mac.set(k("title"), k("from mac"), 1_000);
        let b = phone.set(k("title"), k("from phone"), 2_000);
        mac.apply(&b, 2_100);
        phone.apply(&a, 2_100);
        assert_eq!(mac.get(&k("title")), Some(&k("from phone")));
        assert_eq!(phone.get(&k("title")), Some(&k("from phone")));
        assert_eq!(mac.vv(), phone.vv());
    }

    #[test]
    fn applying_twice_changes_nothing_the_second_time() {
        let (mut a, mut b) = (r("a"), r("b"));
        let d = a.set(k("pin"), k("yes"), 5);
        assert_eq!(b.apply(&d, 5).changed, vec![k("pin")]);
        assert_eq!(b.apply(&d, 5).changed, Vec::<String>::new());
    }

    #[test]
    fn a_delete_is_not_undone_by_an_older_value_arriving_late() {
        let (mut a, mut b) = (r("a"), r("b"));
        let old = a.set(k("draft"), k("hello"), 10);
        b.apply(&old, 10);
        let del = b.delete(k("draft"), 20);
        a.apply(&del, 21);
        a.apply(&old, 22);
        assert_eq!(a.get(&k("draft")), None);
    }

    #[test]
    fn a_gap_merges_but_does_not_advance_the_vector_until_filled() {
        let (mut a, mut b) = (r("a"), r("b"));
        let first = a.set(k("x"), k("1"), 1);
        let second = a.set(k("y"), k("2"), 2);
        let got = b.apply(&second, 3);
        assert!(got.gap);
        assert_eq!(b.get(&k("y")), Some(&k("2")));
        assert_eq!(b.vv().get(&Actor::new("a")), 0);
        let fill = a.delta_since(b.vv());
        assert!(!b.apply(&fill, 4).gap);
        assert_eq!(b.vv(), a.vv());
        drop(first);
    }

    #[test]
    fn a_gap_for_an_overwritten_key_can_still_be_filled() {
        let (mut a, mut b) = (r("a"), r("b"));
        let first = a.set(k("x"), k("1"), 1);
        let second = a.set(k("x"), k("2"), 2);
        let got = b.apply(&second, 3);
        assert!(got.gap);
        assert_eq!(b.get(&k("x")), Some(&k("2")));
        let fill = a.delta_since(b.vv());
        assert_eq!(fill.entries.len(), 2);
        assert!(!b.apply(&fill, 4).gap);
        assert_eq!(b.vv(), a.vv());
        assert_eq!(b.get(&k("x")), Some(&k("2")));
        drop(first);
    }

    #[test]
    fn a_local_edit_after_a_far_remote_stamp_wins_the_round_trip() {
        let (mut remote, mut local) = (r("remote"), r("local"));
        let far = remote.set(k("x"), k("remote"), MAX_DRIFT_MS + 10_000);
        local.apply(&far, 0);
        let mine = local.set(k("x"), k("local"), 1);
        assert!(mine.entries[0].1.stamp > far.entries[0].1.stamp);
        remote.apply(&mine, 1);
        let local_vv = local.vv().clone();
        let back = remote.delta_since(&local_vv);
        local.apply(&back, 1);
        assert_eq!(remote.get(&k("x")), Some(&k("local")));
        assert_eq!(local.get(&k("x")), Some(&k("local")));
    }

    #[test]
    fn delta_since_ships_only_what_the_receiver_lacks() {
        let (mut a, mut b) = (r("a"), r("b"));
        for i in 0..100 {
            let d = a.set(format!("k{i}"), k("v"), i);
            b.apply(&d, i);
        }
        a.set(k("k3"), k("new"), 200);
        let d = a.delta_since(b.vv());
        assert_eq!(d.entries.len(), 1, "{d:?}");
        assert!(a.delta_since(a.vv()).is_empty());
    }

    #[test]
    fn pending_counts_unacked_local_edits_and_state_follows() {
        let mut phone = r("phone");
        phone.set(k("a"), k("1"), 1);
        phone.set(k("b"), k("2"), 2);
        assert_eq!(phone.state(false), SyncState::Offline { pending: 2 });
        assert_eq!(phone.state(true), SyncState::Syncing { pending: 2 });
        phone.ack(&Vv::from([("phone", 2)]));
        assert_eq!(phone.state(true), SyncState::Synced);
    }

    #[test]
    fn compact_drops_tombstones_only_when_everyone_has_them() {
        let (mut a, mut b) = (r("a"), r("b"));
        let d = a.set(k("x"), k("1"), 1);
        b.apply(&d, 1);
        let del = a.delete(k("x"), 2);
        assert_eq!(a.compact(&[a.vv().clone(), b.vv().clone()]), 0);
        b.apply(&del, 3);
        assert_eq!(a.compact(&[a.vv().clone(), b.vv().clone()]), 1);
        assert_eq!(a.len_with_tombstones(), 0);
    }

    #[test]
    fn a_snapshot_round_trips_through_json_with_its_pending_edits() {
        let mut a = r("a");
        a.set(k("x"), k("1"), 1);
        let json = serde_json::to_string(&a.snapshot()).unwrap();
        let back: R = Replica::restore(serde_json::from_str(&json).unwrap());
        assert_eq!(back, a);
        assert_eq!(back.pending(), 1);
    }

    #[test]
    fn sync_state_serializes_for_the_ui() {
        let s = serde_json::to_string(&SyncState::Offline { pending: 3 }).unwrap();
        assert_eq!(s, r#"{"state":"offline","pending":3}"#);
    }
}
