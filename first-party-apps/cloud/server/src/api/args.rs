//! Argument checks that mirror the catalog input schemas. A request that
//! passes them is forwarded to the backend with the same fields, so a bad
//! argument never costs a backend call.

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

/// A required machine, snapshot or plan id: `[A-Za-z0-9][A-Za-z0-9_-]{0,127}`.
pub(crate) fn id<'a>(map: &'a Map<String, Value>, field: &str) -> Result<&'a str, CloudError> {
    let value = map
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| CloudError::invalid(format!("{field} is required")))?;
    check_id(field, value)
}

/// An optional id (same rule as [`id`]).
pub(crate) fn opt_id<'a>(
    map: &'a Map<String, Value>,
    field: &str,
) -> Result<Option<&'a str>, CloudError> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => check_id(field, s).map(Some),
        Some(_) => Err(CloudError::invalid(format!("{field} is not a valid id"))),
    }
}

fn check_id<'a>(field: &str, value: &'a str) -> Result<&'a str, CloudError> {
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

/// A machine name (the backend's `DisplayName`): 1 to 80 characters after
/// trimming, no control characters. `None` when absent.
pub(crate) fn name<'a>(
    map: &'a Map<String, Value>,
    field: &str,
) -> Result<Option<&'a str>, CloudError> {
    match map.get(field) {
        None => Ok(None),
        Some(Value::String(s)) => {
            let t = s.trim();
            if t.is_empty() || t.chars().count() > 80 || t.chars().any(char::is_control) {
                Err(CloudError::invalid(format!(
                    "{field} must be 1 to 80 characters without control characters"
                )))
            } else {
                Ok(Some(t))
            }
        }
        Some(_) => Err(CloudError::invalid(format!("{field} must be text"))),
    }
}

/// A machine size `{cpu?, memory_mb?, disk_mb?}` with at least one field,
/// each a positive integer within the provider's range. The plan decides
/// which sizes are allowed (the backend answers `cloud.size.locked`); this
/// only refuses shapes no plan has.
pub(crate) fn size(map: &Map<String, Value>, field: &str) -> Result<Value, CloudError> {
    let size = map.get(field).ok_or_else(|| CloudError::invalid(format!("{field} is required")))?;
    let fields = object(size, &["cpu", "memory_mb", "disk_mb"])?;
    if fields.is_empty() {
        return Err(CloudError::invalid(format!("{field} needs cpu, memory_mb or disk_mb")));
    }
    if let Some((key, _)) = fields.iter().find(|(_, v)| v.is_null()) {
        return Err(CloudError::invalid(format!("{field}.{key} must be an integer")));
    }
    for (key, min, max) in
        [("cpu", 1, 64), ("memory_mb", 512, 262_144), ("disk_mb", 1024, 1_048_576)]
    {
        int(fields, key, min, max, 1)?;
    }
    Ok(size.clone())
}

/// The present fields of `map` among `fields`, unchanged: the params a
/// checked request sends to the backend.
pub(crate) fn params(map: &Map<String, Value>, fields: &[&str]) -> Value {
    let mut out = Map::new();
    for field in fields {
        if let Some(v) = map.get(*field) {
            out.insert((*field).to_owned(), v.clone());
        }
    }
    Value::Object(out)
}
