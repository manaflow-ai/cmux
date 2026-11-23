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
mod tests {
    use super::*;
    use crate::HomeKind;

    fn row(id: &str, unread: u64) -> HomeRow {
        HomeRow {
            id: id.to_owned(),
            owner: "local",
            kind: HomeKind::Direct,
            name: id.to_owned(),
            unread,
            activity_at: "2026-11-20T00:00:00.000Z".into(),
            preview: None,
            last_author: None,
            chief: None,
            chief_state: None,
            pinned: false,
            pin_position: None,
            marked_unread: false,
            muted: false,
        }
    }

    fn rows(count: usize) -> Vec<HomeRow> {
        (0..count).map(|index| row(&format!("conv_{index}"), 0)).collect()
    }

    #[test]
    fn since_zero_and_unknown_revisions_are_full() {
        let mut log = HomeChangeLog::new(1000);
        log.observe(&rows(3));
        assert_eq!(log.since(0), HomeDelta::Full);
        assert_eq!(log.since(log.revision() + 1), HomeDelta::Full, "a later run's revision");
        assert_eq!(log.since(5), HomeDelta::Full, "an earlier run's revision");
    }

    #[test]
    fn unchanged_rows_record_nothing() {
        let mut log = HomeChangeLog::new(1000);
        let list = rows(10);
        log.observe(&list);
        let revision = log.revision();
        log.observe(&list);
        assert_eq!(log.revision(), revision);
        assert_eq!(log.since(revision), HomeDelta::Since { changed: vec![], removed: vec![] });
    }

    #[test]
    fn one_change_is_one_row() {
        let mut log = HomeChangeLog::new(1000);
        let mut list = rows(10);
        log.observe(&list);
        let revision = log.revision();
        list[4].unread = 3;
        log.observe(&list);
        assert_eq!(log.revision(), revision + 1);
        assert_eq!(
            log.since(revision),
            HomeDelta::Since { changed: vec!["conv_4".into()], removed: vec![] }
        );
    }

    #[test]
    fn removal_is_named() {
        let mut log = HomeChangeLog::new(1000);
        let mut list = rows(5);
        log.observe(&list);
        let revision = log.revision();
        list.remove(2);
        log.observe(&list);
        assert_eq!(
            log.since(revision),
            HomeDelta::Since { changed: vec![], removed: vec!["conv_2".into()] }
        );
        // A row that changed and then left is only removed.
        let revision = log.revision();
        list[0].unread = 9;
        log.observe(&list);
        list.remove(0);
        log.observe(&list);
        assert_eq!(
            log.since(revision),
            HomeDelta::Since { changed: vec![], removed: vec!["conv_0".into()] }
        );
    }

    #[test]
    fn gap_past_the_ring_is_full() {
        let mut log = HomeChangeLog::with_capacity(1000, 4);
        let mut list = rows(10);
        log.observe(&list);
        let revision = log.revision();
        for (index, item) in list.iter_mut().enumerate().take(5) {
            item.unread = index as u64 + 1;
        }
        log.observe(&list);
        assert_eq!(log.since(revision), HomeDelta::Full, "5 changes, ring of 4");
        assert!(matches!(log.since(revision + 1), HomeDelta::Since { .. }), "4 back is covered");
    }

    /// One change in a 5,000-row list: the delta names one row and the read
    /// walks one ring entry, whatever the list's length.
    #[test]
    fn one_change_at_5000_rows_reads_one_row() {
        let mut log = HomeChangeLog::new(1000);
        let mut list = rows(5_000);
        log.observe(&list);
        let revision = log.revision();
        list[4_321].unread = 1;
        log.observe(&list);
        assert_eq!(log.revision() - revision, 1, "one O(1) record");
        let HomeDelta::Since { changed, removed } = log.since(revision) else {
            panic!("covered gap");
        };
        assert_eq!(changed, vec!["conv_4321".to_owned()]);
        assert!(removed.is_empty());
    }
}
