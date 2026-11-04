//! Non-panicking writes into [`serde_json::Value`].
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

/// The object inside `value`, turning null into an empty object first.
fn object_mut(value: &mut Value) -> Option<&mut Map<String, Value>> {
    if value.is_null() {
        *value = Value::Object(Map::new());
    }
    value.as_object_mut()
}

#[cfg(test)]
mod tests {
    use super::JsonSet as _;
    use serde_json::{Map, Value, json};

    #[test]
    fn set_writes_objects_and_null() {
        let mut object = json!({ "a": 1 });
        object.set("b", json!("two"));
        object.set("a", json!([3]));
        assert_eq!(object, json!({ "a": [3], "b": "two" }));

        let mut null = Value::Null;
        assert!(null.set("k", json!(true)));
        assert_eq!(null, json!({ "k": true }));
    }

    #[test]
    fn set_leaves_non_objects_unchanged() {
        for start in [json!([1]), json!("s"), json!(4), json!(false)] {
            let mut value = start.clone();
            assert!(!value.set("k", json!(1)));
            assert!(value.object_mut().is_none());
            value.set_path(&["k", "j"], json!(1));
            assert_eq!(value, start);
        }
    }

    #[test]
    fn set_path_creates_parents_and_stops_at_non_objects() {
        let mut value = json!({ "error": null, "meta": { "keep": 1 } });
        value.set_path(&["error", "data"], json!(5));
        value.set_path(&["meta", "acpmux", "source"], json!("peer"));
        assert_eq!(
            value,
            json!({ "error": { "data": 5 }, "meta": { "keep": 1, "acpmux": { "source": "peer" } } })
        );

        let mut blocked = json!({ "error": "text" });
        blocked.set_path(&["error", "data"], json!(5));
        assert_eq!(blocked, json!({ "error": "text" }));

        let mut empty = json!({});
        empty.set_path(&[], json!(5));
        assert_eq!(empty, json!({}));
    }

    #[test]
    fn map_set_inserts() {
        let mut map = Map::new();
        map.set("k", json!(1));
        map.set_path(&["a", "b"], json!(2));
        assert_eq!(Value::Object(map), json!({ "k": 1, "a": { "b": 2 } }));
    }
}
