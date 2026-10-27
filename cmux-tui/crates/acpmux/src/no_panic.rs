//! Panic-free helpers for the daemon (plans/cmux-next/rust-panic-free.md).
//!
//! A poisoned lock only means another thread panicked while it held the
//! lock; the data is still there. Recovering it keeps one failed request
//! from turning every later request into a panic.
//!
//! `value["key"] = x` panics when `value` is not an object or null (an
//! array, a string from a peer). [`JsonExt::set`] inserts into an object,
//! turns null into an object, and leaves any other value as it is.
//! [`JsonExt::field`] is the `value["key"]` read under a name the
//! `indexing_slicing` lint does not flag: Null when the key is absent or the
//! value is not an object, as the index read already is.

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
    /// `value[key]`: the field, or Null when the key is absent or the value
    /// is not an object.
    fn field(&self, key: &str) -> &Value;
    /// `&mut value[key]`: the field, inserted as Null when absent; a null
    /// value becomes an object first. `None` for any other non-object.
    fn field_mut(&mut self, key: &str) -> Option<&mut Value>;
    /// `value[a][b]... = x` for `path` = `[a, b, ...]`: every missing or null
    /// step becomes an object. A step that is any other non-object stops the
    /// write there (and `false` is returned).
    fn set_path(&mut self, path: &[&str], value: Value) -> bool;
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
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }
    fn field_mut(&mut self, key: &str) -> Option<&mut Value> {
        Some(self.object_mut()?.entry(key).or_insert(Value::Null))
    }
    fn set_path(&mut self, path: &[&str], value: Value) -> bool {
        let Some((last, parents)) = path.split_last() else {
            return false;
        };
        let mut at = self;
        for key in parents {
            match at.field_mut(key) {
                Some(next) => at = next,
                None => return false,
            }
        }
        at.set(last, value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn field_reads_null_for_a_missing_key_or_a_non_object() {
        let v = json!({"a": {"b": 1}});
        assert_eq!(v.field("a").field("b"), &json!(1));
        assert!(v.field("missing").is_null());
        assert!(json!([1, 2]).field("a").is_null());
        assert!(json!("text").field("a").field("b").is_null());
    }

    #[test]
    fn field_mut_inserts_null_and_turns_null_into_an_object() {
        let mut v = Value::Null;
        assert_eq!(v.field_mut("a"), Some(&mut Value::Null));
        assert_eq!(v, json!({"a": null}));
        assert!(json!([1]).field_mut("a").is_none());
    }

    #[test]
    fn set_path_makes_the_missing_steps_and_stops_at_a_non_object() {
        let mut v = json!({"_meta": {"keep": 1}});
        assert!(v.set_path(&["_meta", "acpmux", "via"], json!("cli")));
        assert_eq!(v, json!({"_meta": {"keep": 1, "acpmux": {"via": "cli"}}}));
        // `value["_meta"]["acpmux"] = x` panics on a string step; this leaves it.
        let mut peer = json!({"_meta": "from an old peer"});
        assert!(!peer.set_path(&["_meta", "acpmux"], json!(1)));
        assert_eq!(peer, json!({"_meta": "from an old peer"}));
        let mut array = json!([1]);
        assert!(!array.set_path(&["a"], json!(1)));
        assert!(!array.set_path(&[], json!(1)));
        assert_eq!(array, json!([1]));
    }
}
