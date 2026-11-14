//! A typed user intent the client sends to a feed owner (Swift
//! `FeedIntent`). Until its echo or its settle line arrives, the client
//! shows it applied on top of the confirmed mirror (`apply`); no other
//! optimistic copy exists (OWNERSHIP-PRINCIPLES "Clients are projections").

use serde_json::{Value, json};

use super::item::{FeedItem, State};

#[derive(Clone, Debug, PartialEq)]
pub enum IntentKind {
    /// `value` is the kind's answer value (feed.md 3.4, "Answer value").
    Answer {
        item: String,
        value: Value,
    },
    /// `feed.cancel` with reason `declined`.
    Decline {
        item: String,
    },
    Read {
        items: Vec<String>,
    },
    Archive {
        items: Vec<String>,
    },
    Snooze {
        items: Vec<String>,
        until: i64,
    },
    /// Reads every unread item posted at or before `before`.
    MarkAllRead {
        before: i64,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Intent {
    /// The idempotency key; the echo carries it as `tx`.
    pub key: String,
    pub kind: IntentKind,
    /// When the user acted (the overlay's answer and triage times).
    pub at: i64,
}

impl Intent {
    pub fn new(key: impl Into<String>, kind: IntentKind, at: i64) -> Self {
        Self { key: key.into(), kind, at }
    }

    /// The catalog op (feed.md section 6).
    pub fn op(&self) -> &'static str {
        match self.kind {
            IntentKind::Answer { .. } => "feed.answer",
            IntentKind::Decline { .. } => "feed.cancel",
            IntentKind::Read { .. } | IntentKind::MarkAllRead { .. } => "feed.read",
            IntentKind::Archive { .. } => "feed.archive",
            IntentKind::Snooze { .. } => "feed.snooze",
        }
    }

    /// The items this intent touches (`None`: every item, `MarkAllRead`).
    pub fn items(&self) -> Option<Vec<&str>> {
        match &self.kind {
            IntentKind::Answer { item, .. } | IntentKind::Decline { item } => {
                Some(vec![item.as_str()])
            }
            IntentKind::Read { items }
            | IntentKind::Archive { items }
            | IntentKind::Snooze { items, .. } => Some(items.iter().map(String::as_str).collect()),
            IntentKind::MarkAllRead { .. } => None,
        }
    }

    /// Whether this intent touches `id`.
    pub fn touches(&self, id: &str) -> bool {
        match &self.kind {
            IntentKind::Answer { item, .. } | IntentKind::Decline { item } => item == id,
            IntentKind::Read { items }
            | IntentKind::Archive { items }
            | IntentKind::Snooze { items, .. } => items.iter().any(|item| item == id),
            IntentKind::MarkAllRead { .. } => true,
        }
    }

    /// The same intent narrowed to `items` (an intent split across owners
    /// keeps its key); answers, declines and Mark All Read stay whole.
    pub fn with_items(&self, items: Vec<String>) -> Self {
        let kind = match &self.kind {
            IntentKind::Read { .. } => IntentKind::Read { items },
            IntentKind::Archive { .. } => IntentKind::Archive { items },
            IntentKind::Snooze { until, .. } => IntentKind::Snooze { items, until: *until },
            other => other.clone(),
        };
        Self { key: self.key.clone(), kind, at: self.at }
    }

    /// The visible effect of this intent on one item (pure). Mirrors the
    /// owner's lifecycle rules (feed.md 3.6): answers and declines apply
    /// only to open requests, so a request that closed elsewhere shows its
    /// closed state even while this intent is pending; open requests cannot
    /// be archived or snoozed.
    pub fn apply(&self, item: &mut FeedItem, user: &str, device: &str) {
        if !self.touches(&item.id) {
            return;
        }
        let at = self.at;
        match &self.kind {
            IntentKind::Answer { value, .. } => {
                if !item.is_open_request() {
                    return;
                }
                item.state = State::Answered;
                item.answer = Some(json!({"value": value, "by": user, "device": device, "at": at}));
                item.closed_at = Some(at);
                item.read_at = item.read_at.or(Some(at));
            }
            IntentKind::Decline { .. } => {
                if !item.is_open_request() {
                    return;
                }
                item.state = State::Cancelled;
                item.cancel = Some(json!({"reason": "declined", "by": user, "at": at}));
                item.closed_at = Some(at);
                item.read_at = item.read_at.or(Some(at));
            }
            IntentKind::Read { .. } => {
                item.read_at = item.read_at.or(Some(at));
            }
            IntentKind::Archive { .. } => {
                if item.is_open_request() || item.archived_at.is_some() {
                    return;
                }
                item.archived_at = Some(at);
                item.read_at = item.read_at.or(Some(at));
            }
            IntentKind::Snooze { until, .. } => {
                if !item.is_open_request() {
                    item.snoozed_until = Some(*until);
                }
            }
            IntentKind::MarkAllRead { before } => {
                if item.read_at.is_none() && item.created_at <= *before {
                    item.read_at = Some(at);
                }
            }
        }
    }
}
