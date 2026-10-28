//! Panic-free stand-ins for serde_json's `value[key]` read and write
//! (plans/cmux-next/rust-panic-free.md; the same helper as cmux-tui-core's
//! `panic_free::JsonFields`).
//!
//! `value[key] = field` panics when `value` is neither an object nor null,
//! and clippy's `indexing_slicing` flags reads and writes alike. CDP replies,
//! provider frames and REPL calls are outside data, so both go through this
//! trait.

use serde_json::Value;

/// `value.field(key)` for `value[key]`, `value.insert(key, field)` for
/// `value[key] = field`.
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
#[path = "panic_free_tests.rs"]
mod tests;
