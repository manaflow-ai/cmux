//! Non-panicking writes into [`serde_json::Value`], and typed reads of one
//! member ([`JsonGet`]).
//!
//! `value["key"] = x` goes through `IndexMut`, which panics when `value` is
//! neither an object nor null (an array, a string, a number: easy to get from
//! a peer, an agent or a file on disk). [`JsonSet::set`] does the same write
//! and leaves such a value unchanged instead.
//!
//! ```
//! use cmux_json::JsonSet as _;
//! use serde_json::json;
//!
//! let mut reply = json!({ "ok": true });
//! reply.set("id", json!(7));
//! reply.set_path(&["error", "data"], json!("late"));
//! assert_eq!(reply, json!({ "ok": true, "id": 7, "error": { "data": "late" } }));
//!
//! let mut peer = json!([1, 2]);
//! peer.set("id", json!(7)); // `peer["id"] = json!(7)` would panic here
//! assert_eq!(peer, json!([1, 2]));
//! ```

use serde_json::{Map, Value};

/// String-key writes that never panic, for [`Value`] and JSON object maps.
pub trait JsonSet {
    /// Sets `key` to `value`, like `self[key] = value`.
    ///
    /// `value` is a [`Value`] (not `impl Into<Value>`) so a right-hand side
    /// such as `iter.collect()` or `x.into()` infers exactly as it did in the
    /// `self[key] = value` it replaces.
    ///
    /// A null value first becomes an empty object (as with `IndexMut`). Any
    /// other non-object value is left unchanged, `value` is dropped and
    /// `false` is returned; most callers ignore the result.
    fn set(&mut self, key: impl Into<String>, value: Value) -> bool;

    /// Sets the member at `path`, like `self[path[0]][path[1]]... = value`.
    ///
    /// Missing or null members on the way become empty objects. When `self`
    /// or a member on the path is neither an object nor null, nothing changes.
    /// An empty `path` changes nothing.
    fn set_path(&mut self, path: &[&str], value: Value);

    /// The object map, turning null into an empty object first; `None` for
    /// any other non-object value.
    fn object_mut(&mut self) -> Option<&mut Map<String, Value>>;
}

impl JsonSet for Value {
    fn set(&mut self, key: impl Into<String>, value: Value) -> bool {
        let Some(object) = object_mut(self) else {
            return false;
        };
        object.insert(key.into(), value);
        true
    }

    fn set_path(&mut self, path: &[&str], value: Value) {
        if let Some(object) = object_mut(self) {
            object.set_path(path, value);
        }
    }

    fn object_mut(&mut self) -> Option<&mut Map<String, Value>> {
        object_mut(self)
    }
}

impl JsonSet for Map<String, Value> {
    fn set(&mut self, key: impl Into<String>, value: Value) -> bool {
        self.insert(key.into(), value);
        true
    }

    fn object_mut(&mut self) -> Option<&mut Map<String, Value>> {
        Some(self)
    }

    fn set_path(&mut self, path: &[&str], value: Value) {
        let Some((last, parents)) = path.split_last() else {
            return;
        };
        let mut object = self;
        for key in parents {
            let member = object.entry(*key).or_insert(Value::Null);
            let Some(next) = object_mut(member) else {
                return;
            };
            object = next;
        }
        object.insert((*last).to_owned(), value);
    }
}

/// Typed reads of one member, for [`Value`] and JSON object maps: the
/// `value.get(key).and_then(Value::as_str)` chain each crate kept its own
/// `text`/`flag`/`number` helper for. A missing member, a non-object
/// `self` and a member of another type all read as absent; nothing here
/// coerces (a `"7"` is not a `u64`).
///
/// ```
/// use cmux_json::JsonGet as _;
/// use serde_json::json;
///
/// let record = json!({ "id": "w1", "count": 3, "pinned": true, "tabs": [1, 2] });
/// assert_eq!(record.get_str("id"), Some("w1"));
/// assert_eq!(record.get_string("id").as_deref(), Some("w1"));
/// assert_eq!(json!({ "id": "" }).get_nonempty_str("id"), None);
/// assert_eq!(record.get_u64("count"), Some(3));
/// assert_eq!(record.get_bool("pinned"), Some(true));
/// assert_eq!(record.get_array("tabs").len(), 2);
/// assert_eq!(record.get_str("count"), None);
/// assert!(record.get_array("missing").is_empty());
/// ```
pub trait JsonGet {
    /// The member `key`, when `self` is an object that has it.
    fn member(&self, key: &str) -> Option<&Value>;

    /// Member `key` as a string.
    fn get_str(&self, key: &str) -> Option<&str> {
        self.member(key).and_then(Value::as_str)
    }

    /// Member `key` as a string that is not empty: `""` reads as absent,
    /// for ids and names where an empty value means "not set".
    fn get_nonempty_str(&self, key: &str) -> Option<&str> {
        self.get_str(key).filter(|text| !text.is_empty())
    }

    /// Member `key` as an owned string.
    fn get_string(&self, key: &str) -> Option<String> {
        self.get_str(key).map(str::to_owned)
    }

    /// Member `key` as an unsigned integer.
    fn get_u64(&self, key: &str) -> Option<u64> {
        self.member(key).and_then(Value::as_u64)
    }

    /// Member `key` as a boolean.
    fn get_bool(&self, key: &str) -> Option<bool> {
        self.member(key).and_then(Value::as_bool)
    }

    /// Member `key`'s elements; empty when it is missing or not an array.
    fn get_array(&self, key: &str) -> &[Value] {
        self.member(key).and_then(Value::as_array).map_or(&[], Vec::as_slice)
    }
}

impl JsonGet for Value {
    fn member(&self, key: &str) -> Option<&Value> {
        self.get(key)
    }
}

impl JsonGet for Map<String, Value> {
    fn member(&self, key: &str) -> Option<&Value> {
        self.get(key)
    }
}

/// The object inside `value`, turning null into an empty object first.
fn object_mut(value: &mut Value) -> Option<&mut Map<String, Value>> {
    if value.is_null() {
        *value = Value::Object(Map::new());
    }
    value.as_object_mut()
}

#[cfg(test)]
mod tests;
