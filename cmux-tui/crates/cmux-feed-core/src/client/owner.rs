//! The daemon's in-memory integration owner (Swift `InMemoryFeedSource`, the
//! local owner `LocalFeedSourceAdapter` posts GitHub items and update cards
//! to): the owner's lifecycle rules (first answer wins, `feed.closed` for a
//! late answer), dedupe of a post by its key, the poster's withdraw, and a
//! bound of [`MAX_INTEGRATION_ITEMS`]. It keeps nothing on disk, as the
//! Swift owner did not. Pure: every change is returned as owner events.

use std::collections::HashMap;

use serde_json::json;

use super::intent::{Intent, IntentKind};
use super::item::{FeedItem, State};
use super::mirror::Reject;

/// The most items the owner keeps, as the daemon's local feed owner
/// (`cmux_feed_core::MAX_ITEMS`).
pub const MAX_INTEGRATION_ITEMS: usize = crate::MAX_ITEMS;

/// One committed change of the owner.
#[derive(Clone, Debug, PartialEq)]
pub struct OwnerEvent {
    pub revision: u64,
    /// The key of the intent that caused it.
    pub tx: Option<String>,
    pub items: Vec<FeedItem>,
    pub removed: Vec<String>,
}

/// What a post did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Posted {
    pub id: String,
    pub deduped: bool,
}

pub struct IntegrationOwner {
    items: HashMap<String, FeedItem>,
    revision: u64,
    user: String,
    device: String,
    max_items: usize,
}

impl IntegrationOwner {
    pub fn new(device: &str) -> Self {
        Self::with_limit(device, MAX_INTEGRATION_ITEMS)
    }

    pub fn with_limit(device: &str, max_items: usize) -> Self {
        Self {
            items: HashMap::new(),
            revision: 0,
            user: String::new(),
            device: device.to_owned(),
            max_items,
        }
    }

    /// The user an answer's overlay names (the cloud owner's principal).
    pub fn set_user(&mut self, user: &str) {
        user.clone_into(&mut self.user);
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.items.contains_key(id)
    }

    pub fn item(&self, id: &str) -> Option<&FeedItem> {
        self.items.get(id)
    }

    /// The poster posts or updates an item. A post whose dedupe key matches
    /// an item that is still open and not archived makes no new item: a
    /// request comes back unchanged, a notice takes the new content, counts
    /// one more post and is unread again.
    pub fn post(&mut self, item: FeedItem) -> (Posted, Vec<OwnerEvent>) {
        if let Some(key) = &item.dedupe_key
            && let Some(existing) = self.items.values().find(|existing| {
                existing.dedupe_key.as_ref() == Some(key)
                    && existing.state == State::Open
                    && existing.archived_at.is_none()
            })
        {
            let posted = Posted { id: existing.id.clone(), deduped: true };
            if item.is_request() {
                return (posted, Vec::new());
            }
            let updated = FeedItem {
                id: existing.id.clone(),
                count: existing.count.saturating_add(1),
                revision: existing.revision,
                created_at: existing.created_at,
                read_at: None,
                ..item
            };
            return (posted, self.publish(vec![updated], None));
        }
        let posted = Posted { id: item.id.clone(), deduped: false };
        (posted, self.publish(vec![item], None))
    }

    /// The poster withdraws its open items with `dedupe_key`: they close as
    /// cancelled by the poster. Returns their ids.
    pub fn withdraw(&mut self, dedupe_key: &str, now: i64) -> (Vec<String>, Vec<OwnerEvent>) {
        let mut open: Vec<FeedItem> = self
            .items
            .values()
            .filter(|item| {
                item.dedupe_key.as_deref() == Some(dedupe_key) && item.state == State::Open
            })
            .cloned()
            .collect();
        if open.is_empty() {
            return (Vec::new(), Vec::new());
        }
        open.sort_by(|a, b| a.id.cmp(&b.id));
        let ids = open.iter().map(|item| item.id.clone()).collect();
        let closed = open
            .into_iter()
            .map(|mut item| {
                item.state = State::Cancelled;
                item.cancel = Some(json!({"reason": "poster", "by": item.poster.label, "at": now}));
                item.closed_at = Some(now);
                item.read_at = item.read_at.or(Some(now));
                item.updated_at = now;
                item
            })
            .collect();
        (ids, self.publish(closed, None))
    }

    /// Drops every item `drop` matches, with no close: they were never this
    /// reader's (the account that read them left). One event, or none.
    pub fn remove_where(&mut self, drop: impl Fn(&FeedItem) -> bool) -> Option<OwnerEvent> {
        let mut removed: Vec<String> =
            self.items.values().filter(|item| drop(item)).map(|item| item.id.clone()).collect();
        if removed.is_empty() {
            return None;
        }
        removed.sort();
        for id in &removed {
            self.items.remove(id);
        }
        self.revision = self.revision.saturating_add(1);
        Some(OwnerEvent { revision: self.revision, tx: None, items: Vec::new(), removed })
    }

    /// Commits one intent: its events, then its settle line (`Err`: the
    /// owner refused it).
    pub fn commit(&mut self, intent: &Intent) -> (Result<(), Reject>, Vec<OwnerEvent>) {
        if let IntentKind::Answer { item, .. } | IntentKind::Decline { item } = &intent.kind
            && let Some(item) = self.items.get(item)
            && item.state.is_closed()
        {
            return (Err(Reject::Closed(Box::new(item.clone()))), Vec::new());
        }
        let mut changed: Vec<FeedItem> = self
            .items
            .values()
            .filter_map(|item| {
                let mut next = item.clone();
                intent.apply(&mut next, &self.user, &self.device);
                (next != *item).then_some(next)
            })
            .collect();
        if changed.is_empty() {
            return (Ok(()), Vec::new());
        }
        changed.sort_by(|a, b| a.id.cmp(&b.id));
        (Ok(()), self.publish(changed, Some(intent.key.clone())))
    }

    fn publish(&mut self, changed: Vec<FeedItem>, tx: Option<String>) -> Vec<OwnerEvent> {
        self.revision = self.revision.saturating_add(1);
        let mut stamped = Vec::with_capacity(changed.len());
        for mut item in changed {
            item.revision =
                self.items.get(&item.id).map_or(0, |old| old.revision).saturating_add(1);
            self.items.insert(item.id.clone(), item.clone());
            stamped.push(item);
        }
        let mut events =
            vec![OwnerEvent { revision: self.revision, tx, items: stamped, removed: Vec::new() }];
        events.extend(self.prune());
        events
    }

    /// Past the limit, the oldest items go: read, archived or closed ones
    /// first, then any other, never an open request waiting for an answer.
    fn prune(&mut self) -> Option<OwnerEvent> {
        if self.items.len() <= self.max_items {
            return None;
        }
        let settled = |item: &FeedItem| {
            item.read_at.is_some() || item.archived_at.is_some() || item.state.is_closed()
        };
        let mut oldest: Vec<&FeedItem> =
            self.items.values().filter(|item| !item.is_open_request()).collect();
        oldest.sort_by(|a, b| {
            settled(b)
                .cmp(&settled(a))
                .then(a.updated_at.cmp(&b.updated_at))
                .then_with(|| a.id.cmp(&b.id))
        });
        let removed: Vec<String> = oldest
            .iter()
            .take(self.items.len().saturating_sub(self.max_items))
            .map(|item| item.id.clone())
            .collect();
        if removed.is_empty() {
            return None;
        }
        for id in &removed {
            self.items.remove(id);
        }
        self.revision = self.revision.saturating_add(1);
        Some(OwnerEvent { revision: self.revision, tx: None, items: Vec::new(), removed })
    }
}
