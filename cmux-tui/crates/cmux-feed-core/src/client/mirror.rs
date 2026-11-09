//! The client's projection of one user's feed (Swift `FeedModel`, with the
//! two-owner merge of `LocalFeedSourceAdapter`): a confirmed mirror written
//! only by owner data (the cloud owner's snapshot and events, the
//! integration owner's events, the item of a `feed.closed` refusal), plus
//! one ordered intent log. Visible state is mirror + pending intents; an
//! intent leaves the log on its echo (`tx`) or its settle line.
//!
//! Two owners feed it: the user's `FeedDO` (`Owner::Cloud`) and this
//! daemon's in-memory integration owner (`Owner::Local`, GitHub items and
//! update cards). An item the local owner posted is routed to it; an intent
//! that spans both is sent to each with the same key and settles when both
//! did.

use std::collections::{HashMap, HashSet};

use super::intent::{Intent, IntentKind};
use super::item::FeedItem;
use super::ledger::{Counts, Ledger, Source};

/// The cloud owner's connection, as the view shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Connection {
    Connecting,
    Connected,
    /// The owner is unreachable: cloud items refuse changes (nothing
    /// queues offline, user decision 2026-10-01).
    Disconnected(String),
}

impl Connection {
    pub fn state(&self) -> &'static str {
        match self {
            Connection::Connecting => "connecting",
            Connection::Connected => "connected",
            Connection::Disconnected(_) => "disconnected",
        }
    }

    pub fn reason(&self) -> Option<&str> {
        match self {
            Connection::Disconnected(reason) => Some(reason),
            _ => None,
        }
    }
}

/// An owner refused an intent (feed.md section 6 errors).
#[derive(Clone, Debug, PartialEq)]
pub enum Reject {
    /// `feed.closed`: the request closed first; carries the item so the
    /// client shows "Answered on iPhone".
    Closed(Box<FeedItem>),
    /// `feed.moving`: the item is being handed to the cloud owner; retryable.
    Moving,
    /// `validation.invalid`: the answer does not match the kind's schema.
    Invalid(String),
    /// The cloud owner is unreachable (refused here, never sent).
    Disconnected,
    Other(String),
}

impl Reject {
    /// The daemon error code of this refusal.
    pub fn code(&self) -> &'static str {
        match self {
            Reject::Closed(_) => "feed.closed",
            Reject::Moving => "feed.moving",
            Reject::Invalid(_) => "validation.invalid",
            Reject::Disconnected => "feed.disconnected",
            Reject::Other(_) => "feed.rejected",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Reject::Closed(_) => "the request already closed".to_owned(),
            Reject::Moving => "the item is moving to the cloud owner; try again".to_owned(),
            Reject::Invalid(message) | Reject::Other(message) => message.clone(),
            Reject::Disconnected => "the feed owner is unreachable".to_owned(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner {
    Cloud,
    Local,
}

/// One commit of the mirror that changed what is shown: the new view
/// revision and the ids whose visible value (or pending mark) changed;
/// empty for a connection change alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Commit {
    pub revision: u64,
    pub changed: Vec<String>,
}

/// Where one intent goes ([`Mirror::route`]).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Routed {
    pub local: Option<Intent>,
    pub cloud: Option<Intent>,
    /// The cloud part could not go out (disconnected): settle it with
    /// [`Reject::Disconnected`].
    pub refused: bool,
}

pub struct Mirror {
    connection: Connection,
    /// Owner-confirmed items by id (never written by intents).
    confirmed: HashMap<String, FeedItem>,
    /// Pending intents in send order.
    pending: Vec<Intent>,
    ledger: Ledger,
    /// Bumps once per commit that changes anything shown.
    revision: u64,
    /// The cloud part is hydrated: its owner's snapshot came for this
    /// account. Separate from the integration owner, which lives in this
    /// process and is always current; a view is loaded only when both are, so
    /// an empty view before the first snapshot (connecting, or a first
    /// connection that failed) never reads as "nothing waits".
    hydrated: bool,
    user: String,
    device: String,
    /// Ids the integration owner holds.
    local_ids: HashSet<String>,
    /// Intents sent to both owners: settles still awaited, and the first
    /// refusal heard.
    splits: HashMap<String, (usize, Option<Reject>)>,
}

impl Mirror {
    pub fn new(device: &str) -> Self {
        Self {
            connection: Connection::Disconnected("signed_out".to_owned()),
            confirmed: HashMap::new(),
            pending: Vec::new(),
            ledger: Ledger::default(),
            revision: 0,
            hydrated: false,
            user: String::new(),
            device: device.to_owned(),
            local_ids: HashSet::new(),
            splits: HashMap::new(),
        }
    }

    // MARK: Reads

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// The view is the whole truth: the cloud owner's snapshot came (the
    /// integration owner is always current). Signed out there is no cloud
    /// part; readers tell that from the connection's `signed_out` reason.
    pub fn loaded(&self) -> bool {
        self.hydrated
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub fn user(&self) -> &str {
        &self.user
    }

    pub fn counts(&self) -> Counts {
        self.ledger.counts
    }

    /// The item as shown (mirror + pending intents).
    pub fn visible(&self, id: &str) -> Option<&FeedItem> {
        self.ledger.visible.get(id)
    }

    /// The owner-confirmed item (no overlay).
    pub fn confirmed(&self, id: &str) -> Option<&FeedItem> {
        self.confirmed.get(id)
    }

    /// Every owner-confirmed item, in no order.
    pub fn confirmed_items(&self) -> impl Iterator<Item = &FeedItem> {
        self.confirmed.values()
    }

    /// The panel list (active items), in order: open requests, then the rest.
    pub fn list(&self) -> impl Iterator<Item = &FeedItem> {
        self.ledger.list_ids().filter_map(|id| self.ledger.visible.get(id))
    }

    /// Every visible item, newest first.
    pub fn timeline(&self) -> impl Iterator<Item = &FeedItem> {
        self.ledger.timeline_ids().filter_map(|id| self.ledger.visible.get(id))
    }

    /// An intent on this item still waits for an owner.
    pub fn is_pending(&self, id: &str) -> bool {
        self.pending.iter().any(|intent| intent.touches(id))
    }

    pub fn has_pending(&self, key: &str) -> bool {
        self.pending.iter().any(|intent| intent.key == key)
    }

    pub fn is_local(&self, id: &str) -> bool {
        self.local_ids.contains(id)
    }

    // MARK: Owner data

    pub fn set_connection(&mut self, connection: Connection) -> Option<Commit> {
        if self.connection == connection {
            return None;
        }
        self.connection = connection;
        self.revision = self.revision.saturating_add(1);
        Some(Commit { revision: self.revision, changed: Vec::new() })
    }

    /// The cloud owner's snapshot: replaces every cloud item; the
    /// integration owner's items stay (they win a shared id).
    pub fn cloud_snapshot(&mut self, user: &str, items: Vec<FeedItem>, now: i64) -> Option<Commit> {
        self.user = user.to_owned();
        let mut touched: Vec<String> =
            self.confirmed.keys().filter(|id| !self.local_ids.contains(*id)).cloned().collect();
        for id in &touched {
            self.confirmed.remove(id);
        }
        for item in items {
            if self.local_ids.contains(&item.id) {
                continue;
            }
            touched.push(item.id.clone());
            self.confirmed.insert(item.id.clone(), item);
        }
        self.hydrated = true;
        self.commit(touched, &HashSet::new(), now, true)
    }

    /// The cloud owner is gone for this account (sign-out, another account):
    /// its items leave; the integration owner's stay. The view is unloaded
    /// until the next account's snapshot.
    pub fn clear_cloud(&mut self, now: i64) -> Option<Commit> {
        let gone: Vec<String> =
            self.confirmed.keys().filter(|id| !self.local_ids.contains(*id)).cloned().collect();
        for id in &gone {
            self.confirmed.remove(id);
        }
        self.user.clear();
        let unloaded = std::mem::replace(&mut self.hydrated, false);
        self.commit(gone, &HashSet::new(), now, unloaded)
    }

    /// One committed op of `owner`: the items it changed, the ids it
    /// removed, and the key of this client's intent that caused it.
    pub fn event(
        &mut self,
        owner: Owner,
        items: Vec<FeedItem>,
        removed: Vec<String>,
        tx: Option<&str>,
        now: i64,
    ) -> Option<Commit> {
        let mut touched = Vec::new();
        for item in items {
            if owner == Owner::Local {
                self.local_ids.insert(item.id.clone());
            }
            touched.push(item.id.clone());
            self.adopt(item);
        }
        for id in removed {
            if owner == Owner::Local {
                self.local_ids.remove(&id);
            }
            self.confirmed.remove(&id);
            touched.push(id);
        }
        let mut forced = HashSet::new();
        // An echo settles its intent, unless the intent went to both owners
        // (then only both settle lines end it).
        if let Some(tx) = tx.filter(|tx| !self.splits.contains_key(*tx)) {
            for id in self.end_intents(tx) {
                forced.insert(id.clone());
                touched.push(id);
            }
        }
        self.commit(touched, &forced, now, false)
    }

    /// Writes owner data into the mirror; never moves an item backwards.
    fn adopt(&mut self, item: FeedItem) {
        if self.confirmed.get(&item.id).is_some_and(|current| current.revision > item.revision) {
            return;
        }
        self.confirmed.insert(item.id.clone(), item);
    }

    // MARK: Intents

    /// Logs `intent` (shown applied from now on) and says where it goes.
    pub fn begin(&mut self, intent: Intent, cloud_connected: bool, now: i64) -> (Commit, Routed) {
        let routed = self.route(&intent, cloud_connected);
        let touched: Vec<String> = match intent.items() {
            Some(ids) => ids.into_iter().map(str::to_owned).collect(),
            None => self.ledger.visible.keys().cloned().collect(),
        };
        let forced: HashSet<String> = touched.iter().cloned().collect();
        self.pending.push(intent);
        let commit = match self.commit(touched, &forced, now, false) {
            Some(commit) => commit,
            None => {
                self.revision = self.revision.saturating_add(1);
                Commit { revision: self.revision, changed: Vec::new() }
            }
        };
        (commit, routed)
    }

    /// Splits an intent across the owners (Swift `LocalFeedSourceAdapter.send`).
    fn route(&mut self, intent: &Intent, cloud_connected: bool) -> Routed {
        let mut routed = Routed::default();
        match &intent.kind {
            IntentKind::Read { items }
            | IntentKind::Archive { items }
            | IntentKind::Snooze { items, .. } => {
                let (local, remote): (Vec<String>, Vec<String>) =
                    items.iter().cloned().partition(|id| self.local_ids.contains(id));
                if !local.is_empty() && !remote.is_empty() {
                    self.splits.insert(intent.key.clone(), (2, None));
                }
                if !local.is_empty() {
                    routed.local = Some(intent.with_items(local));
                }
                if !remote.is_empty() {
                    if cloud_connected {
                        routed.cloud = Some(intent.with_items(remote));
                    } else {
                        routed.refused = true;
                    }
                }
            }
            IntentKind::Answer { item, .. } | IntentKind::Decline { item } => {
                if self.local_ids.contains(item) {
                    routed.local = Some(intent.clone());
                } else if cloud_connected {
                    routed.cloud = Some(intent.clone());
                } else {
                    routed.refused = true;
                }
            }
            IntentKind::MarkAllRead { .. } => {
                if cloud_connected {
                    self.splits.insert(intent.key.clone(), (2, None));
                    routed.cloud = Some(intent.clone());
                }
                routed.local = Some(intent.clone());
            }
        }
        routed
    }

    /// One owner's settle line for `key`. Returns the commit, and the final
    /// outcome once every owner it went to settled (`Some(Ok)` or the first
    /// refusal; `None` while another owner's line is still due).
    #[allow(clippy::type_complexity)]
    pub fn settle(
        &mut self,
        key: &str,
        reject: Option<Reject>,
        now: i64,
    ) -> (Option<Commit>, Option<Result<(), Reject>>) {
        let mut touched = Vec::new();
        if let Some(Reject::Closed(item)) = &reject {
            touched.push(item.id.clone());
            self.adopt(item.as_ref().clone());
        }
        let outcome = match self.splits.get_mut(key) {
            Some((remaining, first)) if *remaining > 1 => {
                *remaining = remaining.saturating_sub(1);
                if first.is_none() {
                    *first = reject;
                }
                None
            }
            Some(_) => {
                let first = self.splits.remove(key).and_then(|(_, first)| first);
                Some(first.or(reject))
            }
            None => Some(reject),
        };
        let Some(outcome) = outcome else {
            return (self.commit(touched, &HashSet::new(), now, false), None);
        };
        let ended = self.end_intents(key);
        let forced: HashSet<String> = ended.iter().cloned().collect();
        touched.extend(ended);
        let commit = self.commit(touched, &forced, now, false);
        (commit, Some(outcome.map_or(Ok(()), Err)))
    }

    /// Ends the intents with `key`; returns the ids they touched.
    fn end_intents(&mut self, key: &str) -> Vec<String> {
        let mut touched = Vec::new();
        for intent in self.pending.iter().filter(|intent| intent.key == key) {
            match intent.items() {
                Some(ids) => touched.extend(ids.into_iter().map(str::to_owned)),
                None => touched.extend(self.ledger.visible.keys().cloned()),
            }
        }
        self.pending.retain(|intent| intent.key != key);
        touched
    }

    /// Shows snoozed items whose time came by `now`.
    pub fn tick(&mut self, now: i64) -> Option<Commit> {
        self.commit(Vec::new(), &HashSet::new(), now, false)
    }

    /// Recomputes the touched items (and snoozes that ended by `now`).
    /// `always`: bump the revision even when nothing visible moved (a
    /// snapshot makes the view loaded).
    fn commit(
        &mut self,
        mut touched: Vec<String>,
        forced: &HashSet<String>,
        now: i64,
        always: bool,
    ) -> Option<Commit> {
        touched.extend(self.ledger.woken(now));
        let source = Source {
            confirmed: &self.confirmed,
            pending: &self.pending,
            user: &self.user,
            device: &self.device,
        };
        let changed = self.ledger.update(touched.iter().map(String::as_str), &source, now, forced);
        if changed.is_empty() && !always {
            return None;
        }
        self.revision = self.revision.saturating_add(1);
        Some(Commit { revision: self.revision, changed })
    }
}
