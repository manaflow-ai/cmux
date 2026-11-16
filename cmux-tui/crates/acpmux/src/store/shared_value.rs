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

struct Interner<T>(HashMap<u64, Weak<T>>);

impl<T> Default for Interner<T> {
    fn default() -> Self {
        Self(HashMap::new())
    }
}

fn hash_of<T: Hash>(value: &T) -> u64 {
    let mut hash = DefaultHasher::new();
    value.hash(&mut hash);
    hash.finish()
}

impl<T: PartialEq> Interner<T> {
    fn intern(&mut self, value: T, hash: u64) -> Arc<T> {
        if let Some(existing) = self.0.get(&hash).and_then(Weak::upgrade)
            && *existing == value
        {
            return existing;
        }
        if self.0.len() >= INTERN_SLOTS {
            self.0.retain(|_, value| value.strong_count() != 0);
            if self.0.len() >= INTERN_SLOTS
                && let Some(key) = self.0.keys().next().copied()
            {
                self.0.remove(&key);
            }
        }
        let value = Arc::new(value);
        // Equality above makes a hash collision a missed sharing opportunity, never aliasing.
        self.0.insert(hash, Arc::downgrade(&value));
        value
    }
}

/// JSON on disk and on the wire; shared, copy-on-write storage in loaded session metadata.
#[derive(Debug, Clone, PartialEq)]
pub struct SharedValue(Arc<Value>);

impl SharedValue {
    /// Whether both are the one copy.
    #[cfg(test)]
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
    #[cfg(test)]
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
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn catalog_round_trip_and_session_edits_are_independent() {
        let raw = json!([{"id":"model", "currentValue":"a", "options":[
            {"value":"a", "name":"Model A", "future":{"unicode":"λ", "null":null}},
            {"value":"b", "name":"Model B"}
        ]}]);
        let original: SharedValue = serde_json::from_value(raw.clone()).unwrap();
        let mut edited: SharedValue = serde_json::from_value(raw.clone()).unwrap();
        assert!(Arc::ptr_eq(&original.0, &edited.0));
        edited[0]["currentValue"] = json!("b");
        assert!(!Arc::ptr_eq(&original.0, &edited.0));
        assert_eq!(serde_json::to_value(&original).unwrap(), raw);
        assert_eq!(edited[0]["currentValue"], "b");
        assert_eq!(original[0]["currentValue"], "a");
        let cloned = original.clone();
        assert!(Arc::ptr_eq(&original.0, &cloned.0));
    }

    #[test]
    fn collisions_do_not_share_different_catalogs() {
        let mut pool = Interner::default();
        let first = pool.intern(json!({"a":1}), 0);
        let second = pool.intern(json!({"a":2}), 0);
        assert!(!Arc::ptr_eq(&first, &second));
        assert_eq!(*first, json!({"a":1}));
        assert_eq!(*second, json!({"a":2}));
    }

    #[test]
    fn no_op_updates_keep_sharing_and_real_edits_detach() {
        let original = SharedValue::from(json!([
            {"id":"model", "currentValue":"a"},
            {"id":"mode", "currentValue":"default"}
        ]));
        let mut edited = original.clone();
        assert!(!edited.update_matching(
            |item| item["currentValue"] == "bypassPermissions",
            |item| item["currentValue"] = Value::Null,
        ));
        assert!(Arc::ptr_eq(&original.0, &edited.0));
        assert!(edited.update_matching(
            |item| item["id"] == "mode",
            |item| item["currentValue"] = Value::Null,
        ));
        assert!(!Arc::ptr_eq(&original.0, &edited.0));
        assert_eq!(original[1]["currentValue"], "default");
        assert!(edited[1]["currentValue"].is_null());
        assert_eq!(edited[0], original[0]);
    }

    #[test]
    fn bookkeeping_is_bounded_and_does_not_retain_catalogs() {
        let mut pool = Interner::default();
        let live: Vec<_> = (0..INTERN_SLOTS * 2).map(|n| pool.intern(json!(n), n as u64)).collect();
        assert!(pool.0.len() <= INTERN_SLOTS);
        assert_eq!(*live[0], json!(0));
        let weak = Arc::downgrade(&live[0]);
        drop(live);
        assert!(weak.upgrade().is_none());
        pool.intern(Value::Null, u64::MAX);
        assert_eq!(pool.0.len(), 1);
    }
}
