//! JSON field access without `Index`/`IndexMut`. `value["key"] = x` panics
//! when the value is not an object (or null); reads go through the same
//! helper so the crate has no indexing for clippy to check by hand.

use serde_json::{Map, Value};

pub(crate) trait JsonFieldExt {
    /// The field `key`, or null when it is missing or this is not an object
    /// (what `value["key"]` returns).
    fn field(&self, key: &str) -> &Value;

    /// Insert `key` into this object, as `value[key] = field` does: a null
    /// value becomes an empty object first. Returns false, and changes nothing,
    /// when the value is neither an object nor null.
    fn set_field(&mut self, key: &str, field: Value) -> bool;
}

impl JsonFieldExt for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&Value::Null)
    }

    fn set_field(&mut self, key: &str, field: Value) -> bool {
        if self.is_null() {
            *self = Value::Object(Map::new());
        }
        match self {
            Value::Object(map) => {
                map.insert(key.to_owned(), field);
                true
            }
            _ => false,
        }
    }
}
