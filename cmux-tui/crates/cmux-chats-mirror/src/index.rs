//! The ordered chat index: acpmux's order (`ChatIndex::chats`), newest first, then the key
//! ascending. A change moves one chat in O(log n); nothing re-sorts or copies the index.

use crate::chat::Chat;
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// One decoded `_acpmux/chat_changed` notification.
#[derive(Clone, Debug, PartialEq)]
pub enum Change {
    /// The chat left the index.
    Removed { key: Box<str> },
    /// The live session's attention or latest reply changed: same place in the list.
    Activity {
        key: Box<str>,
        attention: Option<Box<str>>,
        preview: Option<Box<str>>,
        parent: Option<Box<str>>,
    },
    /// The chat was added or its metadata changed.
    Upserted { chat: Chat },
}

/// A chat's place in the order.
#[derive(Clone, Debug)]
struct Place {
    updated_ms: f64,
    key: Box<str>,
}

impl PartialEq for Place {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for Place {}

impl PartialOrd for Place {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Place {
    /// Newest first, then the key ascending (a total order).
    fn cmp(&self, other: &Self) -> Ordering {
        other.updated_ms.total_cmp(&self.updated_ms).then_with(|| self.key.cmp(&other.key))
    }
}

/// The chat index mirror.
#[derive(Clone, Debug, Default)]
pub struct Index {
    chats: HashMap<Box<str>, Chat>,
    order: BTreeSet<Place>,
}

impl Index {
    /// An index of `chats` in acpmux's order; a repeated key keeps its first chat.
    pub fn from_chats(chats: impl IntoIterator<Item = Chat>) -> Self {
        let mut index = Index::default();
        for chat in chats {
            if !index.chats.contains_key(&chat.key) {
                index.order.insert(Place { updated_ms: chat.updated_ms, key: chat.key.clone() });
                index.chats.insert(chat.key.clone(), chat);
            }
        }
        index
    }

    /// Every chat, children included.
    pub fn len(&self) -> usize {
        self.chats.len()
    }

    pub fn is_empty(&self) -> bool {
        self.chats.is_empty()
    }

    /// One chat by key, O(1).
    pub fn get(&self, key: &str) -> Option<&Chat> {
        self.chats.get(key)
    }

    /// The first chat continuing acpmux session `session_id`, newest first. O(n).
    pub fn by_session(&self, session_id: &str) -> Option<&Chat> {
        self.ordered().find(|chat| &*chat.session_id == session_id)
    }

    /// Every chat in order, children included.
    pub fn ordered(&self) -> impl Iterator<Item = &Chat> {
        self.order.iter().filter_map(|place| self.chats.get(&place.key))
    }

    /// The listed chats (no child chat), newest first.
    pub fn listed(&self) -> impl Iterator<Item = &Chat> {
        self.ordered().filter(|chat| chat.is_listed())
    }

    /// Applies one change. True when the index's membership, order or listed set changed
    /// (activity that only changes attention or preview is false).
    pub fn apply(&mut self, change: Change) -> bool {
        match change {
            Change::Removed { key } => match self.chats.remove(&key) {
                Some(old) => {
                    self.order.remove(&Place { updated_ms: old.updated_ms, key: old.key });
                    true
                }
                None => false,
            },
            Change::Activity { key, attention, preview, parent } => {
                match self.chats.get_mut(&key) {
                    Some(chat) => {
                        chat.attention = attention;
                        chat.preview = preview;
                        let moved = chat.parent != parent;
                        chat.parent = parent;
                        moved
                    }
                    None => false,
                }
            }
            Change::Upserted { chat } => {
                if let Some(old) = self.chats.remove(&chat.key) {
                    self.order.remove(&Place { updated_ms: old.updated_ms, key: old.key });
                }
                self.order.insert(Place { updated_ms: chat.updated_ms, key: chat.key.clone() });
                self.chats.insert(chat.key.clone(), chat);
                true
            }
        }
    }

    /// The daemon's project list input: for each harness, each absolute cwd of a listed chat
    /// with its newest chat's update time in whole milliseconds. Sorted by harness, then path.
    pub fn projects(&self) -> BTreeMap<&str, BTreeMap<&str, i64>> {
        let mut projects: BTreeMap<&str, BTreeMap<&str, i64>> = BTreeMap::new();
        for chat in self.listed() {
            let Some(cwd) = chat.cwd.as_deref().filter(|cwd| cwd.starts_with('/')) else {
                continue;
            };
            #[allow(clippy::cast_possible_truncation)]
            let used = chat.updated_ms.round() as i64;
            let newest = projects.entry(&chat.harness).or_default().entry(cwd).or_insert(i64::MIN);
            *newest = (*newest).max(used);
        }
        projects
    }
}
