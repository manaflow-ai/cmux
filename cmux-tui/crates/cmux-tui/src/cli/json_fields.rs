//! Panic-free stand-ins for serde_json's `value[key]` read and write
//! (plans/cmux-next/rust-panic-free.md), the CLI's copy of the cmux-tui-core
//! helper of the same name.
//!
//! `value[key]` reads never panic in serde_json, but `value[key] = field`
//! panics when `value` is neither an object nor null, and the lint cannot
//! tell the two apart. These methods keep the read semantics and make the
//! write total.

use serde_json::Value;

pub(crate) trait JsonFields {
    /// `value[key]` without the index operator: Null when the key is absent
    /// or the value is not an object.
    fn field(&self, key: &str) -> &Value;
    /// `value[index]` without the index operator: Null when the index is out
    /// of range or the value is not an array.
    fn element(&self, index: usize) -> &Value;
    /// `value[key] = field` without the panic: Null becomes an object (as
    /// `IndexMut` does); any other non-object value is left unchanged.
    fn insert(&mut self, key: &str, field: Value);
    /// `&mut value[key]` without the panic: Null becomes an object and an
    /// absent key becomes Null (as `IndexMut` does); `None` when the value is
    /// neither an object nor null.
    fn field_mut(&mut self, key: &str) -> Option<&mut Value>;
}

static JSON_NULL: Value = Value::Null;

impl JsonFields for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }

    fn element(&self, index: usize) -> &Value {
        self.get(index).unwrap_or(&JSON_NULL)
    }

    fn insert(&mut self, key: &str, field: Value) {
        if let Some(slot) = self.field_mut(key) {
            *slot = field;
        }
    }

    fn field_mut(&mut self, key: &str) -> Option<&mut Value> {
        if self.is_null() {
            *self = Value::Object(serde_json::Map::new());
        }
        Some(self.as_object_mut()?.entry(key).or_insert(Value::Null))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::JsonFields;

    #[test]
    fn reads_match_the_index_operator() {
        let value = json!({"a": {"b": 1}, "list": [10, 20]});
        assert_eq!(value.field("a").field("b"), &value["a"]["b"]);
        assert_eq!(value.field("missing"), &value["missing"]);
        assert_eq!(value.field("list").element(1), &value["list"][1]);
        assert_eq!(value.field("list").element(9), &value["list"][9]);
        assert_eq!(json!(3).field("a"), &json!(3)["a"]);
        assert_eq!(json!("text").element(0), &json!("text")[0]);
    }

    #[test]
    fn writes_match_index_mut_and_never_panic() {
        let mut value = json!({"a": 1});
        value.insert("b", json!(2));
        assert_eq!(value, json!({"a": 1, "b": 2}));

        let mut null = serde_json::Value::Null;
        null.insert("a", json!(1));
        assert_eq!(null, json!({"a": 1}));

        let mut nested = json!({});
        if let Some(after) = nested.field_mut("after") {
            after.insert("other", json!(true));
        }
        assert_eq!(nested, json!({"after": {"other": true}}));

        // `json!(5)["a"] = ..` panics; the helper leaves the value alone.
        let mut number = json!(5);
        number.insert("a", json!(1));
        assert_eq!(number, json!(5));
        assert!(number.field_mut("a").is_none());
    }
}
