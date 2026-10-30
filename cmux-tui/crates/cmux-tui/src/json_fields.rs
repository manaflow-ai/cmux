//! serde_json's `value[key]` read without the index operator (writes: `cmux_json::JsonSet`)
//! (plans/cmux-next/rust-panic-free.md), the same as cmux-tui-core's
//! `panic_free::JsonFields`. The index write panics when it meets a value
//! that is not an object or Null.

use serde_json::Value;

/// Panic-free stand-in for serde_json's `value[key]` read.
pub(crate) trait JsonFields {
    /// `value[key]` without the index operator: Null when the key is absent
    /// or the value is not an object.
    fn field(&self, key: &str) -> &Value;
}

static JSON_NULL: Value = Value::Null;

impl JsonFields for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::JsonFields;

    #[test]
    fn json_fields_read_like_the_index_operator_without_panicking() {
        let object = json!({"a": 1});
        assert_eq!(object.field("a"), &json!(1));
        assert_eq!(object.field("missing"), &Value::Null);
        assert_eq!(json!([1]).field("a"), &Value::Null);
        assert_eq!(Value::Null.field("a"), &Value::Null);
    }
}
