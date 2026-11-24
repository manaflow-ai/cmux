//! A bounded cache whose entries carry tags, invalidated by tag at a constant cost.
//!
//! Each entry keeps its value, its tags (a session, a workspace, a host, a harness: whatever the
//! value was read from) and the clock reading it was written at. Invalidating a tag writes one
//! number, the clock's next reading, against that tag: nothing walks the entries, so the cost is
//! the same with ten cached or ten thousand. A read compares the entry's write time with each of
//! its tags' invalidation times, and an entry older than any of them is stale.
//!
//! A stale entry is still handed back ([`Lookup::Stale`]): a caller that can draw it at once and
//! read the fresh value behind it (stale-while-revalidate) does, and one that cannot reads again.
//!
//! A caller reading a value outside the cache's lock takes a [`Stamp`] first ([`TagCache::stamp`])
//! and writes the value at it ([`TagCache::insert_at`]): an invalidation that lands while the
//! value is read leaves the written entry stale, never fresh with what it missed.
//!
//! The cache holds at most its capacity of entries; a new key past it drops the entry written
//! first. A tag's time is kept while some entry carrying it is older than it, and the others are
//! dropped in one sweep once the tags outnumber the entries several times over, so the memory
//! stays bounded by the capacity and each operation's cost stays constant, amortized. A value
//! read before a sweep and written after it could have missed a dropped time: it is written
//! stale.

use std::borrow::Borrow;
use std::collections::{HashMap, VecDeque};
use std::hash::Hash;

/// A clock reading: an entry's write time or a tag's invalidation time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Stamp(u64);

/// What a read found.
#[derive(Debug, PartialEq, Eq)]
pub enum Lookup<'a, V> {
    /// Written after every invalidation of its tags.
    Fresh(&'a V),
    /// Written before one of its tags was invalidated: draw it, and read the fresh value.
    Stale(&'a V),
    /// Nothing cached for the key.
    Miss,
}

impl<'a, V> Lookup<'a, V> {
    /// The cached value, fresh or stale.
    pub fn value(&self) -> Option<&'a V> {
        match *self {
            Self::Fresh(value) | Self::Stale(value) => Some(value),
            Self::Miss => None,
        }
    }

    /// The value only while it is fresh.
    pub fn fresh(&self) -> Option<&'a V> {
        match *self {
            Self::Fresh(value) => Some(value),
            Self::Stale(_) | Self::Miss => None,
        }
    }
}

struct Entry<V, T> {
    value: V,
    tags: Vec<T>,
    written: Stamp,
    /// Read before a sweep dropped tag times it could have missed (module docs).
    missed: bool,
    /// Which write this is: its pair in `order` names it.
    serial: u64,
}

/// The cache: see the module docs.
pub struct TagCache<K, V, T> {
    clock: u64,
    /// Counts the writes, so a key written again is told from its earlier write in `order`.
    writes: u64,
    capacity: usize,
    entries: HashMap<K, Entry<V, T>>,
    /// Keys in the order they were written, each with its write's serial: an older pair whose key
    /// was written again since is skipped when it reaches the front.
    order: VecDeque<(K, u64)>,
    /// Each tag's last invalidation.
    invalidated: HashMap<T, Stamp>,
    /// The clock at the last sweep of `invalidated`.
    swept: Stamp,
    /// How many tag times start the next sweep.
    sweep_at: usize,
}

impl<K, V, T> TagCache<K, V, T>
where
    K: Eq + Hash + Clone,
    T: Eq + Hash + Clone,
{
    /// A cache of at most `capacity` entries (at least one).
    pub fn new(capacity: usize) -> Self {
        Self {
            clock: 0,
            writes: 0,
            capacity: capacity.max(1),
            entries: HashMap::new(),
            order: VecDeque::new(),
            invalidated: HashMap::new(),
            swept: Stamp(0),
            sweep_at: capacity.max(1).saturating_mul(4).saturating_add(64),
        }
    }

    /// How many entries are cached.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether nothing is cached.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// How many tag invalidation times are kept (bounded by the capacity: module docs).
    pub fn tracked_tags(&self) -> usize {
        self.invalidated.len()
    }

    /// The clock now: a value read after this and written at it with [`Self::insert_at`] is stale
    /// to any invalidation of its tags made meanwhile.
    pub fn stamp(&self) -> Stamp {
        Stamp(self.clock)
    }

    /// The entry for `key`, fresh or stale, or none.
    pub fn get<Q>(&self, key: &Q) -> Lookup<'_, V>
    where
        K: Borrow<Q>,
        Q: Eq + Hash + ?Sized,
    {
        let Some(entry) = self.entries.get(key) else { return Lookup::Miss };
        if self.stale(entry) { Lookup::Stale(&entry.value) } else { Lookup::Fresh(&entry.value) }
    }

    /// Writes `value` for `key` with `tags`, now.
    pub fn insert(&mut self, key: K, value: V, tags: Vec<T>) {
        let now = self.stamp();
        self.insert_at(key, value, tags, now);
    }

    /// Writes `value` for `key` with `tags` as of `written`, a [`Self::stamp`] taken before the
    /// value was read: an invalidation of its tags since then leaves it stale.
    pub fn insert_at(&mut self, key: K, value: V, tags: Vec<T>, written: Stamp) {
        let written = written.min(self.stamp());
        let missed = written < self.swept;
        if !self.entries.contains_key(&key) {
            while self.entries.len() >= self.capacity {
                if !self.evict_first() {
                    break;
                }
            }
        }
        self.writes = self.writes.wrapping_add(1);
        let serial = self.writes;
        self.order.push_back((key.clone(), serial));
        self.entries.insert(key, Entry { value, tags, written, missed, serial });
        // Rewrites of the same keys leave skipped pairs behind: compact them once they outnumber
        // the entries, so the queue stays bounded too.
        if self.order.len() > self.entries.len().saturating_mul(2).saturating_add(16) {
            let entries = &self.entries;
            self.order
                .retain(|(key, serial)| entries.get(key).is_some_and(|e| e.serial == *serial));
        }
    }

    /// Marks every entry carrying `tag` stale: one write, whatever is cached.
    pub fn invalidate(&mut self, tag: T) {
        self.clock = self.clock.saturating_add(1);
        self.invalidated.insert(tag, Stamp(self.clock));
        if self.invalidated.len() > self.sweep_at {
            self.forget_old_tags();
        }
    }

    /// Drops the entry for `key`.
    pub fn remove<Q>(&mut self, key: &Q) -> Option<V>
    where
        K: Borrow<Q>,
        Q: Eq + Hash + ?Sized,
    {
        self.entries.remove(key).map(|entry| entry.value)
    }

    fn stale(&self, entry: &Entry<V, T>) -> bool {
        entry.missed
            || entry
                .tags
                .iter()
                .any(|tag| self.invalidated.get(tag).is_some_and(|&at| at > entry.written))
    }

    /// Drops the entry written first; false when none is left.
    fn evict_first(&mut self) -> bool {
        while let Some((key, serial)) = self.order.pop_front() {
            if self.entries.get(&key).is_some_and(|entry| entry.serial == serial) {
                self.entries.remove(&key);
                return true;
            }
        }
        false
    }

    /// Forgets every tag time no entry carrying the tag is older than: it can make nothing stale
    /// again. Run once the tags outnumber the last sweep's survivors twice over (and the capacity
    /// four times), so its walk is paid for by the invalidations since the last one.
    fn forget_old_tags(&mut self) {
        let mut keep: HashMap<T, Stamp> = HashMap::new();
        for entry in self.entries.values() {
            for tag in &entry.tags {
                if let Some(&at) = self.invalidated.get(tag)
                    && at > entry.written
                {
                    keep.insert(tag.clone(), at);
                }
            }
        }
        self.invalidated = keep;
        self.swept = self.stamp();
        self.sweep_at = self
            .invalidated
            .len()
            .saturating_mul(2)
            .max(self.capacity.saturating_mul(4).saturating_add(64));
    }
}

#[cfg(test)]
mod tests;
