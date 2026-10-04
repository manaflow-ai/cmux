//! Argument checks that mirror the catalog input schemas. Ids are checked
//! before they enter a path, so no argument can add a path segment or query.

use super::error::CloudError;
use serde_json::{Map, Value};

static EMPTY: std::sync::OnceLock<Map<String, Value>> = std::sync::OnceLock::new();

/// The args object; `null` is `{}`. Keys outside `allowed` are refused.
pub(crate) fn object<'a>(
    args: &'a Value,
    allowed: &[&str],
) -> Result<&'a Map<String, Value>, CloudError> {
    let map = match args {
        Value::Null => EMPTY.get_or_init(Map::new),
        Value::Object(map) => map,
        _ => return Err(CloudError::invalid("args must be an object")),
    };
    if let Some(extra) = map.keys().find(|k| !allowed.contains(&k.as_str())) {
        return Err(CloudError::invalid(format!("unknown argument {extra}")));
    }
    Ok(map)
}

/// A required machine or snapshot id: `[A-Za-z0-9][A-Za-z0-9_-]{0,127}`.
pub(crate) fn id<'a>(map: &'a Map<String, Value>, field: &str) -> Result<&'a str, CloudError> {
    let value = map
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| CloudError::invalid(format!("{field} is required")))?;
    let mut chars = value.chars();
    let first_ok = chars.next().is_some_and(|c| c.is_ascii_alphanumeric());
    let rest_ok = chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    if !first_ok || !rest_ok || value.len() > 128 {
        return Err(CloudError::invalid(format!("{field} is not a valid id")));
    }
    Ok(value)
}

/// An optional string of 1 to `max` characters.
pub(crate) fn text<'a>(
    map: &'a Map<String, Value>,
    field: &str,
    max: usize,
) -> Result<Option<&'a str>, CloudError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.is_empty() && s.chars().count() <= max => Ok(Some(s)),
        Some(_) => {
            Err(CloudError::invalid(format!("{field} must be text of 1 to {max} characters")))
        }
    }
}

/// An optional integer in `min..=max` that is a multiple of `step`.
pub(crate) fn int(
    map: &Map<String, Value>,
    field: &str,
    min: i64,
    max: i64,
    step: i64,
) -> Result<Option<i64>, CloudError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_i64() {
            Some(n) if (min..=max).contains(&n) && n % step == 0 => Ok(Some(n)),
            _ => Err(CloudError::invalid(format!(
                "{field} must be an integer from {min} to {max} in steps of {step}"
            ))),
        },
    }
}

/// A machine display name as the Cloud API accepts it
/// (`web/services/vms/displayName.ts`): 1 to 64 characters after trimming,
/// no control characters. `None` when absent or null.
pub(crate) fn display_name<'a>(
    map: &'a Map<String, Value>,
    field: &str,
) -> Result<Option<&'a str>, CloudError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            let t = s.trim();
            if t.is_empty() || t.chars().count() > 64 || t.chars().any(char::is_control) {
                Err(CloudError::invalid(format!(
                    "{field} must be 1 to 64 characters without control characters"
                )))
            } else {
                Ok(Some(t))
            }
        }
        Some(_) => Err(CloudError::invalid(format!("{field} must be text or null"))),
    }
}

/// An optional machine kind: `[a-z][a-z0-9-]{0,31}`.
pub(crate) fn kind<'a>(
    map: &'a Map<String, Value>,
    field: &str,
) -> Result<Option<&'a str>, CloudError> {
    let Some(value) = text(map, field, 32)? else { return Ok(None) };
    let mut chars = value.chars();
    let ok = chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    if ok {
        Ok(Some(value))
    } else {
        Err(CloudError::invalid(format!("{field} is not a machine kind")))
    }
}
