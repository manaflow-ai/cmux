//! The Mac's content-addressed blob store.
//!
//! A blob is stored once per distinct sha256, however many rows show it. A
//! blob stays while any row references it. When the last reference goes,
//! the blob moves to a bounded set of recently dropped blobs, so a tab that
//! flips back to an earlier image costs nothing; past the bound the oldest
//! dropped blob is freed.

use crate::hash::{BlobHash, Mime};
use std::collections::hash_map::Entry;
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

/// One stored blob.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredBlob {
    pub mime: Mime,
    pub bytes: Arc<[u8]>,
    refs: u32,
}

/// Counters for reports and the bench.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StoreStats {
    /// Distinct blobs held, live and recently dropped.
    pub blobs: usize,
    /// Bytes held across those blobs.
    pub stored_bytes: u64,
    /// Inserts whose bytes were already stored.
    pub dedupe_hits: u64,
    /// Bytes those inserts did not store again.
    pub dedupe_saved_bytes: u64,
    /// Blobs held only because they were dropped recently.
    pub recent: usize,
}

#[derive(Debug)]
pub struct BlobStore {
    blobs: HashMap<BlobHash, StoredBlob>,
    recent: VecDeque<BlobHash>,
    recent_cap: usize,
    stats: StoreStats,
}

impl BlobStore {
    /// `recent_cap`: how many unreferenced blobs are kept, newest first.
    pub fn new(recent_cap: usize) -> Self {
        Self {
            blobs: HashMap::new(),
            recent: VecDeque::new(),
            recent_cap,
            stats: StoreStats::default(),
        }
    }

    /// Stores `bytes` unless the same bytes are already held, takes one
    /// reference to them and returns their hash. Pair it with one
    /// [`BlobStore::release`] when the row stops showing the blob.
    pub fn insert(&mut self, mime: Mime, bytes: &[u8]) -> BlobHash {
        self.insert_hashed(BlobHash::of(bytes), mime, bytes)
    }

    /// [`BlobStore::insert`] for a caller that already hashed `bytes`.
    pub(crate) fn insert_hashed(&mut self, hash: BlobHash, mime: Mime, bytes: &[u8]) -> BlobHash {
        match self.blobs.entry(hash) {
            Entry::Occupied(_) => {
                self.stats.dedupe_hits += 1;
                self.stats.dedupe_saved_bytes += bytes.len() as u64;
            }
            Entry::Vacant(slot) => {
                slot.insert(StoredBlob { mime, bytes: Arc::from(bytes), refs: 0 });
                self.stats.stored_bytes += bytes.len() as u64;
            }
        }
        self.acquire(hash);
        hash
    }

    pub fn get(&self, hash: &BlobHash) -> Option<&StoredBlob> {
        self.blobs.get(hash)
    }

    pub fn contains(&self, hash: &BlobHash) -> bool {
        self.blobs.contains_key(hash)
    }

    /// One more row references `hash`. Returns false when it is not stored.
    pub fn acquire(&mut self, hash: BlobHash) -> bool {
        let Some(blob) = self.blobs.get_mut(&hash) else {
            return false;
        };
        blob.refs = blob.refs.saturating_add(1);
        if blob.refs == 1 {
            self.recent.retain(|h| *h != hash);
        }
        true
    }

    /// One fewer row references `hash`. At zero it joins the recent set.
    pub fn release(&mut self, hash: BlobHash) {
        let Some(blob) = self.blobs.get_mut(&hash) else {
            return;
        };
        if blob.refs == 0 {
            return;
        }
        blob.refs -= 1;
        if blob.refs == 0 {
            self.push_recent(hash);
        }
    }

    fn push_recent(&mut self, hash: BlobHash) {
        self.recent.push_back(hash);
        while self.recent.len() > self.recent_cap {
            let Some(old) = self.recent.pop_front() else {
                break;
            };
            if let Some(blob) = self.blobs.remove(&old) {
                self.stats.stored_bytes -= blob.bytes.len() as u64;
            }
        }
    }

    pub fn stats(&self) -> StoreStats {
        StoreStats { blobs: self.blobs.len(), recent: self.recent.len(), ..self.stats }
    }
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
