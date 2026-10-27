//! serde_json's `value[key]` read and write without the index operator
//! (plans/cmux-next/rust-panic-free.md), the same as cmux-tui-core's
//! `panic_free::JsonFields`. The index write panics when it meets a value
//! that is not an object or Null.

use serde_json::Value;

/// Panic-free stand-ins for serde_json's `value[key]` read and write.
pub(crate) trait JsonFields {
    /// `value[key]` without the index operator: Null when the key is absent
    /// or the value is not an object.
    fn field(&self, key: &str) -> &Value;
    /// `value[key] = field` without the panic: Null becomes an object (as
    /// `IndexMut` does); any other non-object value is left unchanged.
    fn insert(&mut self, key: &str, field: Value);
}

static JSON_NULL: Value = Value::Null;

impl JsonFields for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }

    fn insert(&mut self, key: &str, field: Value) {
        if self.is_null() {
            *self = Value::Object(serde_json::Map::new());
        }
        if let Some(object) = self.as_object_mut() {
            object.insert(key.to_owned(), field);
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::JsonFields;

    #[test]
    fn json_fields_read_and_write_like_the_index_operator_without_panicking() {
        let mut object = json!({"a": 1});
        assert_eq!(object.field("a"), &json!(1));
        assert_eq!(object.field("missing"), &Value::Null);
        object.insert("b", json!(2));
        assert_eq!(object, json!({"a": 1, "b": 2}));

        let mut null = Value::Null;
        null.insert("a", json!(1));
        assert_eq!(null, json!({"a": 1}));

        let mut array = json!([1]);
        array.insert("a", json!(1));
        assert_eq!(array, json!([1]));
        assert_eq!(array.field("a"), &Value::Null);
    }
}
