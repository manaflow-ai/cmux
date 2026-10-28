//! Panic-free helpers for the daemon (plans/cmux-next/rust-panic-free.md).
//!
//! A poisoned lock only means another thread panicked while it held the
//! lock; the data is still there. Recovering it keeps one failed request
//! from turning every later request into a panic.
//!
//! `value["key"] = x` panics when `value` is not an object or null (an
//! array, a string from a peer). [`JsonExt::set`] inserts into an object,
//! turns null into an object, and leaves any other value as it is.
//! [`JsonExt::field`] and [`JsonExt::item`] read like `value["key"]` and
//! `value[0]` (Null when absent) without the index operator, so the panic
//! lints stay at 0 and a reader sees that no read can panic.

use serde_json::{Map, Value};
use std::sync::{Mutex, MutexGuard, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// Lock without panicking on poison.
pub trait LockExt<T: ?Sized> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T>;
}

impl<T: ?Sized> LockExt<T> for Mutex<T> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Read or write an `RwLock` without panicking on poison.
pub trait RwLockExt<T: ?Sized> {
    fn read_or_recover(&self) -> RwLockReadGuard<'_, T>;
    fn write_or_recover(&self) -> RwLockWriteGuard<'_, T>;
}

impl<T: ?Sized> RwLockExt<T> for RwLock<T> {
    fn read_or_recover(&self) -> RwLockReadGuard<'_, T> {
        self.read().unwrap_or_else(PoisonError::into_inner)
    }
    fn write_or_recover(&self) -> RwLockWriteGuard<'_, T> {
        self.write().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Set an object key without the panicking `IndexMut` of `serde_json::Value`.
pub trait JsonExt {
    /// Insert `key`; a null becomes an object first. Any other non-object
    /// value is left unchanged (and `false` is returned).
    fn set(&mut self, key: &str, value: Value) -> bool;
    /// The object map, creating it from null. `None` for any other non-object.
    fn object_mut(&mut self) -> Option<&mut Map<String, Value>>;
    /// `value[path[0]][path[1]]... = value`: each missing or null level
    /// becomes an object, as `IndexMut` does. A level that holds any other
    /// value is left unchanged (and `false` is returned).
    fn set_path(&mut self, path: &[&str], value: Value) -> bool;
    /// `value[key]` for reading: Null when the key is absent or `self` is
    /// not an object.
    fn field(&self, key: &str) -> &Value;
    /// `value[index]` for reading: Null when `self` is not an array or the
    /// index is past its end.
    fn item(&self, index: usize) -> &Value;
}

static JSON_NULL: Value = Value::Null;

impl JsonExt for Value {
    fn set(&mut self, key: &str, value: Value) -> bool {
        match self.object_mut() {
            Some(map) => {
                map.insert(key.to_owned(), value);
                true
            }
            None => false,
        }
    }
    fn object_mut(&mut self) -> Option<&mut Map<String, Value>> {
        if self.is_null() {
            *self = Value::Object(Map::new());
        }
        self.as_object_mut()
    }
    fn set_path(&mut self, path: &[&str], value: Value) -> bool {
        let Some((last, parents)) = path.split_last() else { return false };
        let mut at = self;
        for key in parents {
            let Some(map) = at.object_mut() else { return false };
            at = map.entry((*key).to_owned()).or_insert(Value::Null);
        }
        at.set(last, value)
    }
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }
    fn item(&self, index: usize) -> &Value {
        self.get(index).unwrap_or(&JSON_NULL)
    }
}

/// Byte-bounded prefixes of a `str` without the slice operator.
pub trait StrExt {
    /// The longest prefix of at most `max` bytes that ends on a character
    /// boundary: `&text[..max]` for ASCII, never a cut through a character.
    fn head(&self, max: usize) -> &str;
}

impl StrExt for str {
    fn head(&self, max: usize) -> &str {
        let mut cut = self.len().min(max);
        loop {
            if let Some(head) = self.get(..cut) {
                return head;
            }
            // `get(..0)` is always Some, so `cut` is > 0 here.
            cut = cut.saturating_sub(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{JsonExt, StrExt};
    use serde_json::json;

    #[test]
    fn head_cuts_on_a_character_boundary() {
        assert_eq!("0123456789".head(8), "01234567");
        assert_eq!("abc".head(8), "abc");
        assert_eq!("aé".head(2), "a");
        assert_eq!("é".head(1), "");
        assert_eq!("".head(3), "");
    }

    #[test]
    fn field_and_item_read_like_index_without_panicking() {
        let v = json!({"a": {"b": [1, 2]}, "s": "text"});
        assert_eq!(v.field("a").field("b").item(1), &json!(2));
        assert!(v.field("missing").is_null());
        assert!(v.field("s").field("x").is_null());
        assert!(v.field("a").field("b").item(9).is_null());
        assert!(json!("string").item(0).is_null());
    }

    #[test]
    fn set_path_builds_missing_levels_and_leaves_other_values() {
        let mut v = json!({"keep": 1});
        assert!(v.set_path(&["_meta", "acpmux", "name"], json!("n")));
        assert_eq!(v, json!({"keep": 1, "_meta": {"acpmux": {"name": "n"}}}));

        let mut null = serde_json::Value::Null;
        assert!(null.set_path(&["a"], json!(true)));
        assert_eq!(null, json!({"a": true}));

        let mut blocked = json!({"_meta": "peer string"});
        assert!(!blocked.set_path(&["_meta", "acpmux", "name"], json!("n")));
        assert_eq!(blocked, json!({"_meta": "peer string"}));
        assert!(!blocked.set_path(&[], json!(1)));
    }
}
