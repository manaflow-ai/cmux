//! `value[key] = field` without indexing: serde_json's `IndexMut` panics on a value that is not an
//! object (clippy::indexing_slicing, plans/cmux-next/rust-panic-free.md).
use serde_json::Value;

/// Sets `key` on a JSON object; a no-op on anything else.
pub(crate) fn put(value: &mut Value, key: &str, field: Value) {
    if let Some(map) = value.as_object_mut() {
        map.insert(key.into(), field);
    }
}
