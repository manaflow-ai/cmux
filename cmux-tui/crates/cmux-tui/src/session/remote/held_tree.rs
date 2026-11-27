//! The tree the last refresh read, held for the next one (`list-workspaces-known-v1`).
//!
//! A refresh that holds a tree sends its identity and revisions as `known`; the daemon answers
//! `{"unchanged": true}` in O(1) while nothing the tree shows changed
//! (cmux-tui-core server/list_workspaces_page.rs), and the client reuses what it holds instead of
//! reading, sending and parsing the whole tree again.
//!
//! The held tree is a [`TagCache`] entry tagged [`HeldTreeTag::Tree`]. The tree events this
//! client already receives (`tree-changed`, `layout-changed`, `surface-exited`, a patch that did
//! not apply, a lost event stream) invalidate the tag: a stale entry is a tree the client knows
//! changed, so the next refresh reads it whole as before, with no `known` (the daemon then also
//! reads each stale git HEAD for that reply). A fresh entry is sent as `known`; the daemon's
//! revision decides, so an event this client never saw (a scoped subscription, a lagging stream)
//! still gets the whole tree. The refresh takes a [`Stamp`] before it asks, so an event that lands
//! while the reply is on its way leaves the entry it writes stale.
//!
//! The held tree is the parsed reply before the client's own edits (retired surfaces, sidebar
//! order, title and agent patches); a refresh that reuses it applies those again, exactly as it
//! does to a tree it just read.

use std::sync::Arc;

use cmux_tag_cache::{Stamp, TagCache};
use serde_json::Value;

use super::super::tree::TreeView;

/// The daemon answers `known` on `list-workspaces` (cmux-tui-core `LIST_WORKSPACES_KNOWN_CAPABILITY`).
pub(super) const LIST_WORKSPACES_KNOWN_CAPABILITY: &str = "list-workspaces-known-v1";

/// What `known` carries: the reply's identity and revisions, the daemon's `KnownTree`.
const KNOWN_FIELDS: [&str; 6] = [
    "registry_id",
    "generation",
    "workspace_revision",
    "pane_revision",
    "terminal_revision",
    "tree_revision",
];

/// What a held tree was read from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum HeldTreeTag {
    /// The session's whole tree: every tree event invalidates it.
    Tree,
}

/// A whole tree as the daemon sent it, with the `known` that names it.
pub(super) struct HeldTree {
    pub(super) known: Value,
    pub(super) tree: TreeView,
}

/// The one held tree of a remote session.
pub(super) struct HeldTrees {
    cache: TagCache<(), Arc<HeldTree>, HeldTreeTag>,
}

impl Default for HeldTrees {
    fn default() -> Self {
        Self { cache: TagCache::new(1) }
    }
}

impl HeldTrees {
    /// Taken before a refresh asks: see [`TagCache::stamp`].
    pub(super) fn stamp(&self) -> Stamp {
        self.cache.stamp()
    }

    /// The held tree while no tree event has arrived since it was read.
    pub(super) fn fresh(&self) -> Option<Arc<HeldTree>> {
        self.cache.get(&()).fresh().cloned()
    }

    /// Whether a tree is held, and whether it is fresh.
    #[cfg(test)]
    pub(super) fn lookup(&self) -> Option<bool> {
        match self.cache.get(&()) {
            cmux_tag_cache::Lookup::Fresh(_) => Some(true),
            cmux_tag_cache::Lookup::Stale(_) => Some(false),
            cmux_tag_cache::Lookup::Miss => None,
        }
    }

    /// A tree event arrived: the held tree is out of date. One write, whatever is held.
    pub(super) fn invalidate(&mut self) {
        self.cache.invalidate(HeldTreeTag::Tree);
    }

    /// Holds `held` as read (or confirmed unchanged) by a request that started at `at`.
    pub(super) fn hold(&mut self, held: Arc<HeldTree>, at: Stamp) {
        self.cache.insert_at((), held, vec![HeldTreeTag::Tree], at);
    }

    pub(super) fn forget(&mut self) {
        self.cache.remove(&());
    }
}

/// The `known` of a whole reply, when the daemon gave it a tree revision (a part of the tree,
/// `limit`, gets none and is not a tree to hold).
pub(super) fn known_of(data: &Value) -> Option<Value> {
    if is_unchanged(data) || !data.get("tree_revision").is_some_and(Value::is_string) {
        return None;
    }
    let mut known = serde_json::Map::new();
    for field in KNOWN_FIELDS {
        known.insert(field.to_string(), data.get(field).cloned().unwrap_or(Value::Null));
    }
    Some(Value::Object(known))
}

/// The daemon's `{"unchanged": true}`.
pub(super) fn is_unchanged(data: &Value) -> bool {
    data.get("unchanged").and_then(Value::as_bool) == Some(true)
}

/// Whether `data` says the tree named by `known` is still current.
pub(super) fn confirms(data: &Value, known: &Value) -> bool {
    is_unchanged(data)
        && KNOWN_FIELDS.iter().all(|field| {
            data.get(*field).unwrap_or(&Value::Null) == known.get(*field).unwrap_or(&Value::Null)
        })
}
