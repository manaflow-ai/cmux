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

/// A context part's text: one copy for every chat that captured the same bytes, made or read from
/// disk. Immutable (a change is a new text), compared by content as the `String` it replaces, and
/// serialized as that string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedText(Arc<str>);

impl SharedText {
    /// Whether both are the one copy.
    #[cfg(test)]
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

    fn chat(id: &str) -> super::super::SessionMeta {
        let mut meta: super::super::SessionMeta = serde_json::from_value(json!({
            "schema": super::super::META_SCHEMA, "id": id, "name": id, "harness": "codex",
            "cwd": "/repo", "status": "idle", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap_or_else(|e| panic!("a test meta: {e}"));
        let cfg = crate::config::Config::default();
        let mut parts = crate::context_inventory::snapshot(&cfg, &meta.cwd);
        // A `String` made anew for each chat, as `agent_guidance::for_session` makes it.
        parts.push(crate::context_inventory::guidance_part(
            crate::agent_guidance::AGENT_GUIDANCE.to_owned(),
        ));
        meta.cmux_context = Some(parts);
        meta
    }

    fn texts(meta: &super::super::SessionMeta) -> Vec<&SharedText> {
        meta.cmux_context.iter().flatten().filter_map(|part| part.text.as_ref()).collect()
    }

    #[test]
    fn chats_made_or_loaded_with_the_same_context_hold_its_text_once() {
        use super::super::{LocalStore, Store};
        let (first, second) = (chat("first"), chat("second"));
        let (made, other) = (texts(&first), texts(&second));
        assert_eq!(made.len(), 2);
        assert!(made.iter().zip(&other).all(|(a, b)| a.shares(b)), "made: one copy");

        let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
        let root = home.path().join("sessions");
        let store = LocalStore::new(root.clone(), 64 * 1024)
            .unwrap_or_else(|e| panic!("open the store: {e:#}"));
        let session_json = |id: &str| {
            std::fs::read(root.join(id).join("session.json")).unwrap_or_else(|e| panic!("{e}"))
        };
        let mut written = Vec::new();
        for meta in [&first, &second] {
            store.save(meta).unwrap_or_else(|e| panic!("save: {e:#}"));
            written.push(session_json(&meta.id));
        }
        let load = |id: &str| {
            let meta = store.load(id).unwrap_or_else(|e| panic!("load: {e:#}"));
            meta.unwrap_or_else(|| panic!("no {id}"))
        };
        let (read_first, read_second) = (load("first"), load("second"));
        assert_eq!(read_first, first);
        assert_eq!(read_second, second);
        let read = texts(&read_first);
        assert!(read.iter().zip(texts(&read_second)).all(|(a, b)| a.shares(b)), "read: one copy");
        assert!(read.iter().zip(&made).all(|(a, b)| a.shares(b)), "read: the live chat's copy");

        // Written again from what was read: the same bytes.
        for (meta, before) in [&read_first, &read_second].into_iter().zip(&written) {
            store.save(meta).unwrap_or_else(|e| panic!("save: {e:#}"));
            assert_eq!(&session_json(&meta.id), before);
        }
    }

    #[test]
    fn a_context_parts_text_reads_and_writes_as_the_string_it_was() {
        let raw = r#"{"id":"cmux-guidance","source":"cmux-guidance","label":"g","tokens":3,"included":true,"editable":false,"measurement":"estimated","channel":"user-context","text":"same words, λ \"quoted\"\n"}"#;
        let part: crate::context_inventory::ContextPart =
            serde_json::from_str(raw).unwrap_or_else(|e| panic!("read: {e}"));
        assert_eq!(part.text.as_deref(), Some("same words, λ \"quoted\"\n"));
        assert_eq!(serde_json::to_string(&part).unwrap_or_else(|e| panic!("{e}")), raw);
        let none = r#"{"id":"x","source":"harness","label":"x","tokens":0,"included":false,"editable":false,"measurement":"unavailable"}"#;
        let part: crate::context_inventory::ContextPart =
            serde_json::from_str(none).unwrap_or_else(|e| panic!("read: {e}"));
        assert!(part.text.is_none());
        assert_eq!(serde_json::to_string(&part).unwrap_or_else(|e| panic!("{e}")), none);
        // Equal texts compare equal whether or not they are one copy.
        let mut pool = Interner::<str>::default();
        let apart = SharedText(pool.insert(Arc::from("words"), 0));
        assert_eq!(apart, SharedText::from("words".to_owned()));
        assert_ne!(apart, SharedText::from("other"));
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
