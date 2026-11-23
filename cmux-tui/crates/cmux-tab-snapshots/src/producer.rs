//! The Mac side's tab state. The host feeds it what each tab shows now
//! ([`Observation`]) and which tabs closed. The producer bumps `rev` only
//! when a row's content changed, keeps blobs in its [`BlobStore`], and keeps
//! a bounded history so a reconnecting phone gets one delta from its rev.
//!
//! The host passes an `epoch` at construction: a fresh random value for every
//! start of the host process. Every manifest and delta carries it, and a
//! `resume` from another epoch (or none) gets a manifest, so a phone's rev
//! from an earlier run is never read as a rev of this one. `rev` starts at
//! the value the host passes. When the tab ids stop meaning what they did
//! (the host is on a new run of the daemon that numbers them),
//! [`Producer::new_epoch`] starts over under a new epoch.

use crate::hash::{BlobHash, Mime};
use crate::row::{Kind, Row, RowPatch, reorder};
use crate::store::BlobStore;
use crate::wire::{Delta, Manifest};
use std::collections::{HashMap, VecDeque};

/// A favicon's bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FaviconInput {
    pub mime: Mime,
    pub bytes: Vec<u8>,
}

/// An image (a card thumbnail or a full frame).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageInput {
    pub mime: Mime,
    pub bytes: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// A terminal's screen as text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScreenInput {
    pub text: String,
    pub cols: u32,
    pub rows: u32,
}

/// What one tab shows now. A `None` part means the tab has none.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Observation {
    pub tab_id: String,
    pub title: String,
    pub kind: Kind,
    pub favicon: Option<FaviconInput>,
    pub thumb: Option<ImageInput>,
    pub screen: Option<ScreenInput>,
    pub frame: Option<ImageInput>,
    pub captured_at_ms: i64,
}

#[derive(Debug)]
struct Change {
    rev: u64,
    changed: Vec<RowPatch>,
    removed: Vec<String>,
    /// True when this change moved tabs.
    reordered: bool,
}

#[derive(Debug)]
pub struct Producer {
    epoch: String,
    rows: Vec<Row>,
    rev: u64,
    /// The oldest rev a delta can start from.
    oldest_base: u64,
    history: VecDeque<Change>,
    history_cap: usize,
    store: BlobStore,
}

impl Producer {
    /// `epoch`: this run's identity, fresh per host start (the crate does not
    /// generate it). `first_rev`: the rev of the empty state. `history_cap`: how many revs
    /// a resume can reach back. `recent_blob_cap`: see [`BlobStore::new`].
    pub fn new(
        epoch: impl Into<String>,
        first_rev: u64,
        history_cap: usize,
        recent_blob_cap: usize,
    ) -> Self {
        Self {
            epoch: epoch.into(),
            rows: Vec::new(),
            rev: first_rev,
            oldest_base: first_rev,
            history: VecDeque::new(),
            history_cap,
            store: BlobStore::new(recent_blob_cap),
        }
    }

    pub fn epoch(&self) -> &str {
        &self.epoch
    }

    pub fn rev(&self) -> u64 {
        self.rev
    }

    pub fn rows(&self) -> &[Row] {
        &self.rows
    }

    pub fn store(&self) -> &BlobStore {
        &self.store
    }

    pub fn manifest(&self) -> Manifest {
        Manifest { epoch: self.epoch.clone(), rev: self.rev, rows: self.rows.clone() }
    }

    /// Records what a tab shows. Returns true when that is a change (a new
    /// rev). The same content again changes nothing, even with a newer
    /// `capturedAtMs`.
    pub fn observe(&mut self, obs: Observation) -> bool {
        let index = self.rows.iter().position(|r| r.tab_id == obs.tab_id);
        let old = index.and_then(|i| self.rows.get(i)).cloned();
        let old = old.as_ref();
        let new = self.row_for(old, obs);
        let patch = match old {
            Some(old) => RowPatch::diff(old, &new.row),
            None => Some(RowPatch::full(&new.row)),
        };
        let Some(patch) = patch else {
            // Unchanged content: give back the references `row_for` took.
            for hash in new.taken {
                self.store.release(hash);
            }
            return false;
        };
        let old_hashes: Vec<_> = old.map(|r| r.hashes().collect()).unwrap_or_default();
        match index.and_then(|i| self.rows.get_mut(i)) {
            Some(slot) => *slot = new.row,
            None => self.rows.push(new.row),
        }
        for hash in old_hashes {
            self.store.release(hash);
        }
        self.record(vec![patch], Vec::new(), false);
        true
    }

    /// Starts over under `epoch`: every row goes, and no delta reaches back
    /// past this point, so a phone on the old epoch (resuming, or open
    /// now) gets a manifest of the new rows only. `rev` keeps counting up,
    /// so no rev of the old epoch is a rev of the new one either.
    pub fn new_epoch(&mut self, epoch: impl Into<String>) {
        for row in std::mem::take(&mut self.rows) {
            for hash in row.hashes() {
                self.store.release(hash);
            }
        }
        self.epoch = epoch.into();
        self.rev = self.rev.saturating_add(1);
        self.oldest_base = self.rev;
        self.history.clear();
    }

    /// Closes a tab. Returns false when no such tab is known.
    pub fn remove(&mut self, tab_id: &str) -> bool {
        let Some(index) = self.rows.iter().position(|r| r.tab_id == tab_id) else {
            return false;
        };
        let row = self.rows.remove(index);
        for hash in row.hashes() {
            self.store.release(hash);
        }
        self.record(Vec::new(), vec![row.tab_id], false);
        true
    }

    /// Sets the tab order: the listed tabs first, in the listed order, then
    /// every unlisted tab in its old relative order. Unknown ids are
    /// ignored. Returns true when that is a change (a new rev).
    pub fn set_order<S: AsRef<str>>(&mut self, order: &[S]) -> bool {
        if !reorder(&mut self.rows, order) {
            return false;
        }
        self.record(Vec::new(), Vec::new(), true);
        true
    }

    /// One delta from `base_rev` to now, or `None` when `base_rev` is older
    /// than the history reaches or is not a rev this producer handed out.
    /// At the current rev it is an empty delta.
    pub fn delta_since(&self, base_rev: u64) -> Option<Delta> {
        if base_rev < self.oldest_base || base_rev > self.rev {
            return None;
        }
        let mut changed: Vec<RowPatch> = Vec::new();
        let mut at: HashMap<String, usize> = HashMap::new();
        let mut removed: Vec<String> = Vec::new();
        let mut reordered = false;
        for change in self.history.iter().filter(|c| c.rev > base_rev) {
            reordered |= change.reordered;
            for id in &change.removed {
                if let Some(i) = at.remove(id) {
                    // Keep the slot so other indexes stay valid; it is
                    // dropped below.
                    if let Some(p) = changed.get_mut(i) {
                        p.tab_id.clear();
                    }
                }
                if !removed.contains(id) {
                    removed.push(id.clone());
                }
            }
            for patch in &change.changed {
                removed.retain(|id| *id != patch.tab_id);
                match at.get(&patch.tab_id).and_then(|&i| changed.get_mut(i)) {
                    Some(existing) => existing.merge(patch.clone()),
                    None => {
                        at.insert(patch.tab_id.clone(), changed.len());
                        changed.push(patch.clone());
                    }
                }
            }
        }
        changed.retain(|p| !p.tab_id.is_empty());
        // The order is the current one: later appends and removals are
        // already reflected in it.
        let order = reordered.then(|| self.rows.iter().map(|r| r.tab_id.clone()).collect());
        Some(Delta { epoch: self.epoch.clone(), rev: self.rev, base_rev, changed, removed, order })
    }

    fn record(&mut self, changed: Vec<RowPatch>, removed: Vec<String>, reordered: bool) {
        self.rev = self.rev.saturating_add(1);
        self.history.push_back(Change { rev: self.rev, changed, removed, reordered });
        while self.history.len() > self.history_cap {
            match self.history.pop_front() {
                Some(dropped) => self.oldest_base = dropped.rev,
                None => break,
            }
        }
        if self.history_cap == 0 {
            self.oldest_base = self.rev;
        }
    }

    /// Builds the row for `obs`, storing any part whose bytes are new to the
    /// row. Each stored part holds one store reference, listed in `taken`.
    fn row_for(&mut self, old: Option<&Row>, obs: Observation) -> NewRow {
        let mut taken = Vec::new();
        // A part whose bytes the row already shows takes one more reference
        // without counting as a dedupe hit; new bytes go through the store.
        let mut put = |store: &mut BlobStore, had: Option<BlobHash>, mime: Mime, bytes: &[u8]| {
            let hash = BlobHash::of(bytes);
            if had == Some(hash) && store.acquire(hash) {
                taken.push(hash);
                return hash;
            }
            store.insert_hashed(hash, mime, bytes);
            taken.push(hash);
            hash
        };
        let store = &mut self.store;
        let favicon_hash = obs
            .favicon
            .as_ref()
            .map(|f| put(store, old.and_then(|o| o.favicon_hash), f.mime, &f.bytes));
        let thumb_hash = obs
            .thumb
            .as_ref()
            .map(|t| put(store, old.and_then(|o| o.thumb_hash), t.mime, &t.bytes));
        let screen_hash = obs.screen.as_ref().map(|s| {
            put(store, old.and_then(|o| o.screen_hash), Mime::ScreenText, s.text.as_bytes())
        });
        let frame_hash = obs
            .frame
            .as_ref()
            .map(|f| put(store, old.and_then(|o| o.frame_hash), f.mime, &f.bytes));
        let thumb = obs.thumb.as_ref();
        let screen = obs.screen.as_ref();
        let row = Row {
            tab_id: obs.tab_id,
            title: obs.title,
            kind: obs.kind,
            favicon_hash,
            thumb_hash,
            thumb_w: thumb.map_or(0, |t| t.width),
            thumb_h: thumb.map_or(0, |t| t.height),
            thumb_mime: thumb.map_or(Mime::OctetStream, |t| t.mime),
            screen_hash,
            screen_cols: screen.map_or(0, |s| s.cols),
            screen_rows: screen.map_or(0, |s| s.rows),
            frame_hash,
            captured_at_ms: obs.captured_at_ms,
        };
        let row = match old {
            // An unchanged row keeps its capture time, so the manifest and
            // the deltas a phone applied agree.
            Some(old) if old.same_content(&row) => {
                Row { captured_at_ms: old.captured_at_ms, ..row }
            }
            _ => row,
        };
        NewRow { row, taken }
    }
}

struct NewRow {
    row: Row,
    taken: Vec<BlobHash>,
}

#[cfg(test)]
#[path = "producer_tests.rs"]
mod tests;
