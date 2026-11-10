//! The feed as the person sees it (Swift `FeedLedger` and
//! `FeedOrderedIndex`): each item with the pending intents applied, the
//! panel list's order (open requests by priority then newest, then
//! everything else newest first), every item newest first, and the badge
//! counts. The mirror tells it which ids changed; it recomputes those only.
//! Nothing here sorts or compares the whole feed per change: the orders are
//! ordered sets keyed by unique keys (the id breaks ties).

use std::cmp::Reverse;
use std::collections::{BTreeSet, HashMap, HashSet};

use super::intent::Intent;
use super::item::FeedItem;

/// The panel list's order: open requests first, by priority then newest;
/// then everything else, newest first; ids break ties.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct ListKey {
    section: u8,
    rank: Reverse<i8>,
    time: Reverse<i64>,
    id: String,
}

impl ListKey {
    fn of(item: &FeedItem) -> Self {
        let request = item.is_open_request();
        Self {
            section: u8::from(!request),
            rank: Reverse(if request { item.priority.rank() } else { 0 }),
            time: Reverse(item.created_at),
            id: item.id.clone(),
        }
    }
}

/// Newest first; ids break ties.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct TimeKey {
    time: Reverse<i64>,
    id: String,
}

impl TimeKey {
    fn of(item: &FeedItem) -> Self {
        Self { time: Reverse(item.created_at), id: item.id.clone() }
    }
}

/// The badge (feed.md 3.7): open requests plus unread notices, over active
/// items; `unread` counts every unread visible item (Mark All Read).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub open_requests: usize,
    pub unread_notices: usize,
    pub unread: usize,
}

impl Counts {
    pub fn badge(&self) -> usize {
        self.open_requests.saturating_add(self.unread_notices)
    }
}

#[derive(Default)]
pub(crate) struct Ledger {
    /// Mirror + pending intents, by id.
    pub(crate) visible: HashMap<String, FeedItem>,
    /// The panel list: active items (not archived, not snoozed).
    list: BTreeSet<ListKey>,
    list_key: HashMap<String, ListKey>,
    /// Every visible item, newest first.
    timeline: BTreeSet<TimeKey>,
    pub(crate) counts: Counts,
    /// Items hidden by a snooze, until when: they come back when `now`
    /// passes it.
    snoozed: HashMap<String, i64>,
}

impl Ledger {
    /// Snoozed items whose time has come by `now`.
    pub(crate) fn woken(&self, now: i64) -> Vec<String> {
        self.snoozed.iter().filter(|(_, until)| **until <= now).map(|(id, _)| id.clone()).collect()
    }

    /// The panel list's ids, in order.
    pub(crate) fn list_ids(&self) -> impl Iterator<Item = &str> {
        self.list.iter().map(|key| key.id.as_str())
    }

    /// Every visible id, newest first.
    pub(crate) fn timeline_ids(&self) -> impl Iterator<Item = &str> {
        self.timeline.iter().map(|key| key.id.as_str())
    }

    /// Recomputes `ids` from the mirror and the intents; returns the ids
    /// whose visible value or list membership changed, plus every `forced`
    /// id (an intent on it started or settled, so its pending mark moved).
    pub(crate) fn update<'a>(
        &mut self,
        ids: impl IntoIterator<Item = &'a str>,
        source: &Source<'_>,
        now: i64,
        forced: &HashSet<String>,
    ) -> Vec<String> {
        let Source { confirmed, pending, user, device } = *source;
        let mut changed = Vec::new();
        let mut seen = HashSet::new();
        for id in ids {
            if !seen.insert(id) {
                continue;
            }
            let new = overlay(id, confirmed, pending, user, device);
            let was_active = self.list_key.contains_key(id);
            let is_active = new.as_ref().is_some_and(|item| item.is_active(now));
            let old = self.visible.get(id);
            if old == new.as_ref() && was_active == is_active {
                if forced.contains(id) {
                    changed.push(id.to_owned());
                }
                continue;
            }
            if let Some(old) = old.cloned() {
                self.count(&old, was_active, -1);
                self.timeline.remove(&TimeKey::of(&old));
            }
            if let Some(key) = self.list_key.remove(id) {
                self.list.remove(&key);
            }
            match new {
                Some(new) => {
                    self.count(&new, is_active, 1);
                    self.timeline.insert(TimeKey::of(&new));
                    if is_active {
                        let key = ListKey::of(&new);
                        self.list.insert(key.clone());
                        self.list_key.insert(id.to_owned(), key);
                    }
                    match new.snoozed_until {
                        Some(until) if !new.is_archived() && until > now => {
                            self.snoozed.insert(id.to_owned(), until);
                        }
                        _ => {
                            self.snoozed.remove(id);
                        }
                    }
                    self.visible.insert(id.to_owned(), new);
                }
                None => {
                    self.snoozed.remove(id);
                    self.visible.remove(id);
                }
            }
            changed.push(id.to_owned());
        }
        changed
    }

    fn count(&mut self, item: &FeedItem, active: bool, sign: isize) {
        let add = |value: &mut usize| *value = value.saturating_add_signed(sign);
        if item.is_unread() {
            add(&mut self.counts.unread);
        }
        if !active {
            return;
        }
        if item.is_open_request() {
            add(&mut self.counts.open_requests);
        }
        if !item.is_request() && item.is_unread() {
            add(&mut self.counts.unread_notices);
        }
    }
}

/// One item with the pending intents applied, in send order.
/// What the visible items are made of: the owners' items and the intents
/// on top, as `user` on `device`.
#[derive(Clone, Copy)]
pub(crate) struct Source<'a> {
    pub(crate) confirmed: &'a HashMap<String, FeedItem>,
    pub(crate) pending: &'a [Intent],
    pub(crate) user: &'a str,
    pub(crate) device: &'a str,
}

pub(crate) fn overlay(
    id: &str,
    confirmed: &HashMap<String, FeedItem>,
    pending: &[Intent],
    user: &str,
    device: &str,
) -> Option<FeedItem> {
    let mut item = confirmed.get(id)?.clone();
    for intent in pending {
        intent.apply(&mut item, user, device);
    }
    Some(item)
}
