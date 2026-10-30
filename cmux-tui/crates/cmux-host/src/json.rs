//! Non-panicking JSON field reads for outside input (cloud replies, saved
//! files, the daemon's answers).

use serde_json::Value;

static NULL: Value = Value::Null;

/// `value.field("k")` reads like `value["k"]`: the field, or `Null` when
/// it is missing or `value` is not an object. It never panics.
pub(crate) trait JsonField {
    fn field(&self, key: &str) -> &Value;
}

impl JsonField for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&NULL)
    }
}
