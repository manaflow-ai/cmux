//! JSON field writes that return an error instead of panicking.
//!
//! `value[key] = field` (serde_json's `IndexMut`) panics when `value` is not
//! an object or null. Request fingerprints, results and snapshots built here
//! use [`set_field`], which turns that case into [`NotAnObject`] for the
//! request to report.

use std::fmt;

use serde_json::{Map, Value};

/// A JSON value that cannot take a field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct NotAnObject {
    pub(crate) key: &'static str,
}

impl fmt::Display for NotAnObject {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "cannot set field {:?} on a JSON value that is not an object", self.key)
    }
}

impl std::error::Error for NotAnObject {}

/// `value[key] = field` for an object; a null becomes an empty object first,
/// as serde_json's `IndexMut` does.
pub(crate) fn set_field(
    value: &mut Value,
    key: &'static str,
    field: Value,
) -> Result<(), NotAnObject> {
    object_mut(value, key)?.insert(key.to_string(), field);
    Ok(())
}

/// [`set_field`] for a key computed at run time (reported by `label`).
pub(crate) fn set_named_field(
    value: &mut Value,
    label: &'static str,
    key: String,
    field: Value,
) -> Result<(), NotAnObject> {
    object_mut(value, label)?.insert(key, field);
    Ok(())
}

fn object_mut<'a>(
    value: &'a mut Value,
    key: &'static str,
) -> Result<&'a mut Map<String, Value>, NotAnObject> {
    if value.is_null() {
        *value = Value::Object(Map::new());
    }
    value.as_object_mut().ok_or(NotAnObject { key })
}

#[cfg(test)]
#[path = "value_fields_tests.rs"]
mod tests;
