//! Panic-free helpers for the daemon (plans/cmux-next/rust-panic-free.md).
//!
//! A poisoned lock only means another thread panicked while it held the
//! lock; the data is still there. Recovering it keeps one failed request
//! from turning every later request into a panic.
//!
//! `value["key"] = x` panics when `value` is not an object or null (an
//! array, a string from a peer). [`JsonExt::set`] inserts into an object,
//! turns null into an object, and leaves any other value as it is.
//! [`JsonRead::field`] and [`JsonRead::item`] read like `value["key"]` and
//! `value[0]` (Null when absent) without the index operator, so the panic
//! lints stay at 0 and a reader sees that no read can panic.
//! [`JsonRead::field_mut`] is `&mut value["key"]` without the index operator.

use serde_json::Value;
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

/// Non-panicking `serde_json::Value` writes: the shared [`cmux_json::JsonSet`]
/// under the name the daemon already imports.
pub use cmux_json::JsonSet as JsonExt;

/// Read a `serde_json::Value` like the index operator, without its panics.
pub trait JsonRead {
    /// `value[key]` for reading: Null when the key is absent or `self` is
    /// not an object.
    fn field(&self, key: &str) -> &Value;
    /// `&mut value[key]`: the field, inserted as Null when absent; a null
    /// value becomes an object first. `None` for any other non-object.
    fn field_mut(&mut self, key: &str) -> Option<&mut Value>;
    /// `value[index]` for reading: Null when `self` is not an array or the
    /// index is past its end.
    fn item(&self, index: usize) -> &Value;
}

static JSON_NULL: Value = Value::Null;

impl JsonRead for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }
    fn field_mut(&mut self, key: &str) -> Option<&mut Value> {
        Some(JsonExt::object_mut(self)?.entry(key).or_insert(Value::Null))
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
    use super::{JsonExt as _, JsonRead, StrExt};
    use serde_json::Value;
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
    fn field_mut_inserts_null_and_turns_null_into_an_object() {
        let mut v = Value::Null;
        assert_eq!(v.field_mut("a"), Some(&mut Value::Null));
        assert_eq!(v, json!({"a": null}));
        assert!(json!([1]).field_mut("a").is_none());
    }

    #[test]
    fn set_path_builds_missing_levels_and_leaves_other_values() {
        let mut v = json!({"keep": 1});
        v.set_path(&["_meta", "acpmux", "name"], json!("n"));
        assert_eq!(v, json!({"keep": 1, "_meta": {"acpmux": {"name": "n"}}}));

        let mut null = serde_json::Value::Null;
        null.set_path(&["a"], json!(true));
        assert_eq!(null, json!({"a": true}));

        let mut blocked = json!({"_meta": "peer string"});
        blocked.set_path(&["_meta", "acpmux", "name"], json!("n"));
        assert_eq!(blocked, json!({"_meta": "peer string"}));
        blocked.set_path(&[], json!(1));
        assert_eq!(blocked, json!({"_meta": "peer string"}));
    }
}
