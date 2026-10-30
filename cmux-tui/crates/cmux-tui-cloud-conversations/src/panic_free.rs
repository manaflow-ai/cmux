//! Panic-free stand-in for serde_json's `value[key]` read
//! (plans/cmux-next/rust-panic-free.md); the same rule as cmux-tui-core's
//! `panic_free::JsonFields`; writes use `cmux_json::JsonSet`. Cloud frames
//! are peer input.

use serde_json::Value;

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
