//! Session catalogs are usually identical across chats. Keep one immutable copy until a chat
//! changes it. The weak interner owns no catalog and has bounded bookkeeping; eviction only gives
//! up sharing, never drops a session's data.
//!
//! Three catalogs share this way: the config options, the agent's slash commands
//! (`SessionMeta::available_commands`) and its tool rows (`ToolInventory::rows`). The last two
//! were a copy per chat: on Leo's Mac (2026-11-16) 418 chats' commands were 22.7 MB of JSON and
//! only 85 distinct (4 MB), 535 chats' tool rows 3.5 MB and 112 distinct, each held as a
//! `serde_json::Value` tree in a daemon of 952 MB. Shared, they cost what the distinct ones do,
//! however many chats there are.
//!
//! So does the text of a chat's captured context (`ContextPart::text` in
//! `SessionMeta::cmux_context`): cmux's rule, its chat guidance and skill index, a preset's prompt,
//! the same bytes in every chat of a harness. A dhat profile of 1,000 chats put 5.3 MB (5.3 kB a
//! chat) in the copies `context_inventory::snapshot_for` made.

use super::ToolRow;
use crate::no_panic::LockExt;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::ops::{Deref, DerefMut};
use std::sync::{Arc, LazyLock, Mutex, Weak};

/// Distinct catalogs a pool tracks: about ten times the distinct commands Leo's 544 chats hold.
/// When full, it forgets every dead entry, then one live one (which only gives up sharing it).
const INTERN_SLOTS: usize = 1024;
static CATALOGS: LazyLock<Mutex<Interner<Value>>> = LazyLock::new(Mutex::default);
static TOOL_ROWS: LazyLock<Mutex<Interner<Vec<ToolRow>>>> = LazyLock::new(Mutex::default);
static TEXTS: LazyLock<Mutex<Interner<str>>> = LazyLock::new(Mutex::default);

struct Interner<T: ?Sized>(HashMap<u64, Weak<T>>);

impl<T: ?Sized> Default for Interner<T> {
    fn default() -> Self {
        Self(HashMap::new())
    }
}

fn hash_of<T: Hash + ?Sized>(value: &T) -> u64 {
    let mut hash = DefaultHasher::new();
    value.hash(&mut hash);
    hash.finish()
}

impl<T: PartialEq> Interner<T> {
    fn intern(&mut self, value: T, hash: u64) -> Arc<T> {
        match self.existing(&value, hash) {
            Some(existing) => existing,
            None => self.insert(Arc::new(value), hash),
        }
    }
}

impl<T: PartialEq + ?Sized> Interner<T> {
    /// The live copy equal to `value`, when the pool holds one.
    fn existing(&self, value: &T, hash: u64) -> Option<Arc<T>> {
        self.0.get(&hash).and_then(Weak::upgrade).filter(|existing| **existing == *value)
    }

    fn insert(&mut self, value: Arc<T>, hash: u64) -> Arc<T> {
        if self.0.len() >= INTERN_SLOTS {
            self.0.retain(|_, value| value.strong_count() != 0);
            if self.0.len() >= INTERN_SLOTS
                && let Some(key) = self.0.keys().next().copied()
            {
                self.0.remove(&key);
            }
        }
        // Equality in `existing` makes a hash collision a missed sharing chance, never aliasing.
        self.0.insert(hash, Arc::downgrade(&value));
        value
    }
}

/// JSON on disk and on the wire; shared, copy-on-write storage in loaded session metadata.
#[derive(Debug, Clone, PartialEq)]
pub struct SharedValue(Arc<Value>);

impl SharedValue {
    /// Whether both are the one copy.
    pub(crate) fn shares(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }

    /// Detach an array only when an element actually needs an edit.
    pub(crate) fn update_matching(
        &mut self,
        matches: impl Fn(&Value) -> bool,
        edit: impl Fn(&mut Value),
    ) -> bool {
        if !self.as_array().is_some_and(|items| items.iter().any(&matches)) {
            return false;
        }
        if let Some(items) = self.as_array_mut() {
            for item in items.iter_mut().filter(|item| matches(item)) {
                edit(item);
            }
        }
        true
    }
}

impl From<Value> for SharedValue {
    fn from(value: Value) -> Self {
        let hash = hash_of(&value);
        Self(CATALOGS.lock_or_recover().intern(value, hash))
    }
}

/// A chat's tool rows: one copy for every chat whose agent reported the same rows, detached by
/// the first edit (`DerefMut`), as [`SharedValue`] is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedRows(Arc<Vec<ToolRow>>);

impl SharedRows {
    /// Whether both are the one copy.
    pub(crate) fn shares(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

impl Default for SharedRows {
    fn default() -> Self {
        Vec::new().into()
    }
}

impl From<Vec<ToolRow>> for SharedRows {
    fn from(rows: Vec<ToolRow>) -> Self {
        let hash = hash_of(&rows);
        Self(TOOL_ROWS.lock_or_recover().intern(rows, hash))
    }
}

impl FromIterator<ToolRow> for SharedRows {
    fn from_iter<I: IntoIterator<Item = ToolRow>>(rows: I) -> Self {
        rows.into_iter().collect::<Vec<_>>().into()
    }
}

impl Deref for SharedRows {
    type Target = Vec<ToolRow>;

    fn deref(&self) -> &Vec<ToolRow> {
        &self.0
    }
}

impl DerefMut for SharedRows {
    fn deref_mut(&mut self) -> &mut Vec<ToolRow> {
        Arc::make_mut(&mut self.0)
    }
}

impl Serialize for SharedRows {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.as_ref().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for SharedRows {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Vec::<ToolRow>::deserialize(deserializer).map(Self::from)
    }
}

/// A context part's text: one copy for every chat that captured the same bytes, made or read from
/// disk. Immutable (a change is a new text), compared by content as the `String` it replaces, and
/// serialized as that string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedText(Arc<str>);

impl SharedText {
    /// Whether both are the one copy.
    pub(crate) fn shares(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }

    /// Looks the text up before copying it: a `&str` the pool holds already costs no allocation.
    fn intern(text: impl AsRef<str> + Into<Arc<str>>) -> Self {
        let hash = hash_of(text.as_ref());
        let mut pool = TEXTS.lock_or_recover();
        match pool.existing(text.as_ref(), hash) {
            Some(existing) => Self(existing),
            None => Self(pool.insert(text.into(), hash)),
        }
    }
}

impl From<String> for SharedText {
    fn from(text: String) -> Self {
        Self::intern(text)
    }
}

impl From<&str> for SharedText {
    fn from(text: &str) -> Self {
        Self::intern(text)
    }
}

impl Deref for SharedText {
    type Target = str;

    fn deref(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for SharedText {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl Serialize for SharedText {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.as_ref().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for SharedText {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer).map(Self::from)
    }
}

impl Deref for SharedValue {
    type Target = Value;

    fn deref(&self) -> &Value {
        &self.0
    }
}

impl DerefMut for SharedValue {
    fn deref_mut(&mut self) -> &mut Value {
        Arc::make_mut(&mut self.0)
    }
}

impl Serialize for SharedValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.as_ref().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for SharedValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Value::deserialize(deserializer).map(Self::from)
    }
}

#[cfg(test)]
#[path = "shared_value_tests.rs"]
mod tests;
