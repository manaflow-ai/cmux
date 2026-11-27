//! `home-inbox` deltas (`since`): a revisioned change log of one caller's
//! Home rows, so a view that already holds the list reads only the rows that
//! changed and the ids that left, never the whole list for one event
//! (plans/feat-ios-instant-list slice 4).
//!
//! The log keeps a fingerprint of each row it last saw and a bounded ring of
//! the last [`HOME_CHANGE_LOG_CAPACITY`] row changes, one revision each. A
//! row change is one O(1) record. A `since` the ring no longer covers (or one
//! from another daemon run) answers [`HomeDelta::Full`].
//!
//! Revisions start at the log's creation time in milliseconds and go up by
//! one per row change, so a revision a view kept from an earlier daemon run is
//! below the new run's first revision and gets a full reply. `since: 0` means
//! "I hold nothing": always a full reply with the current revision.

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::{Hash, Hasher};

use crate::HomeRow;

/// The row changes one log remembers. A view further behind reads the list
/// again (`full`).
pub const HOME_CHANGE_LOG_CAPACITY: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ChangeKind {
    Changed,
    Removed,
}

/// One caller's Home rows over time.
#[derive(Debug)]
pub struct HomeChangeLog {
    /// The revision of the newest change (the base when there is none).
    revision: u64,
    /// `(revision, id, kind)`, oldest first; revisions are consecutive.
    ring: VecDeque<(u64, String, ChangeKind)>,
    capacity: usize,
    /// The last observed fingerprint of each row, by id.
    fingerprints: HashMap<String, u64>,
    /// Whether the fingerprints hold a first observation.
    seeded: bool,
}

/// What a `since` read answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HomeDelta {
    /// The gap is not covered: send the whole list (and `revision`).
    Full,
    /// The ids of rows that changed or came, and the ids that left, since the
    /// asked revision. Each id once, by its latest change.
    Since { changed: Vec<String>, removed: Vec<String> },
}

impl HomeChangeLog {
    /// A log whose first revision is `base` (the creation time in ms).
    pub fn new(base: u64) -> Self {
        Self::with_capacity(base, HOME_CHANGE_LOG_CAPACITY)
    }

    pub fn with_capacity(base: u64, capacity: usize) -> Self {
        Self {
            revision: base.max(1),
            ring: VecDeque::with_capacity(capacity.min(HOME_CHANGE_LOG_CAPACITY)),
            capacity: capacity.max(1),
            fingerprints: HashMap::new(),
            seeded: false,
        }
    }

    /// The revision of the newest change.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// One row changed or came: one O(1) record.
    pub fn record_changed(&mut self, id: &str) {
        self.push(id, ChangeKind::Changed);
    }

    /// One row left the list: one O(1) record.
    pub fn record_removed(&mut self, id: &str) {
        self.fingerprints.remove(id);
        self.push(id, ChangeKind::Removed);
    }

    fn push(&mut self, id: &str, kind: ChangeKind) {
        self.revision += 1;
        if self.ring.len() == self.capacity {
            self.ring.pop_front();
        }
        self.ring.push_back((self.revision, id.to_owned(), kind));
    }

    /// Records every row of `rows` whose content differs from the last
    /// observation (or is new), and every last-seen id that is gone. Rows
    /// that did not change record nothing.
    /// The first observation only seeds the fingerprints: no view holds a
    /// revision of this log yet, so it records nothing.
    pub fn observe(&mut self, rows: &[HomeRow]) {
        if !self.seeded {
            self.seeded = true;
            self.fingerprints = rows.iter().map(|row| (row.id.clone(), fingerprint(row))).collect();
            return;
        }
        let mut seen = HashSet::with_capacity(rows.len());
        for row in rows {
            seen.insert(row.id.as_str());
            let print = fingerprint(row);
            if self.fingerprints.get(&row.id) != Some(&print) {
                self.fingerprints.insert(row.id.clone(), print);
                self.push(&row.id, ChangeKind::Changed);
            }
        }
        let gone: Vec<String> =
            self.fingerprints.keys().filter(|id| !seen.contains(id.as_str())).cloned().collect();
        for id in gone {
            self.record_removed(&id);
        }
    }

    /// The changes after revision `since`: [`HomeDelta::Full`] when the
    /// ring does not reach back to it, `since` is 0, or `since` is newer than
    /// this log (another daemon run). Reads only the ring entries after
    /// `since` (found in O(1): revisions are consecutive).
    pub fn since(&self, since: u64) -> HomeDelta {
        if since == 0 || since > self.revision {
            return HomeDelta::Full;
        }
        let oldest = self.ring.front().map_or(self.revision + 1, |entry| entry.0);
        // The ring holds every change after `oldest - 1`.
        if since + 1 < oldest {
            return HomeDelta::Full;
        }
        let start = usize::try_from(since + 1 - oldest).unwrap_or(usize::MAX);
        let mut latest: HashMap<&str, ChangeKind> = HashMap::new();
        let mut order: Vec<&str> = Vec::new();
        for (_, id, kind) in self.ring.iter().skip(start) {
            if latest.insert(id.as_str(), *kind).is_none() {
                order.push(id.as_str());
            }
        }
        let mut changed = Vec::new();
        let mut removed = Vec::new();
        for id in order {
            match latest.get(id) {
                Some(ChangeKind::Changed) => changed.push(id.to_owned()),
                Some(ChangeKind::Removed) => removed.push(id.to_owned()),
                None => {}
            }
        }
        HomeDelta::Since { changed, removed }
    }
}

/// A row's content hash (its wire JSON).
fn fingerprint(row: &HomeRow) -> u64 {
    let mut hasher = DefaultHasher::new();
    serde_json::to_string(row).unwrap_or_default().hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
#[path = "home_delta_tests.rs"]
mod tests;
