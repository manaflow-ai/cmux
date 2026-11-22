//! Reading JSON the way the app's decoders did: a lenient field drops itself when it has another
//! type, a strict one fails the whole value ([`Strict`]).

use serde_json::{Map, Value};

/// A strict read's failure: the field and what was wrong.
pub(crate) type Strict<T> = Result<T, String>;

/// The number as an exact integer (a whole `3.0` counts), else nil.
pub(crate) fn int(value: &Value) -> Option<i64> {
    if let Some(int) = value.as_i64() {
        return Some(int);
    }
    whole(value.as_f64()?)
}

/// `float` as an integer when it is one exactly (as Swift's `Int(exactly:)`), within 2^53.
pub(crate) fn whole(float: f64) -> Option<i64> {
    if float.fract() != 0.0 || float.abs() >= 9.0e15 {
        return None;
    }
    // Whole and within 2^53: the cast is exact.
    #[allow(clippy::cast_possible_truncation, reason = "checked whole and within 2^53 above")]
    let int = float as i64;
    Some(int)
}

/// A present, non-null field (`None` for absent and null alike, as `decodeIfPresent`).
pub(crate) fn present<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a Value> {
    object.get(key).filter(|value| !value.is_null())
}

/// A strict optional string: absent or null is nil, any other type fails.
pub(crate) fn string(object: &Map<String, Value>, key: &str) -> Strict<Option<String>> {
    match present(object, key) {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(format!("{key}: not a string")),
    }
}

/// A strict optional number.
pub(crate) fn number(object: &Map<String, Value>, key: &str) -> Strict<Option<f64>> {
    match present(object, key) {
        None => Ok(None),
        Some(value) => value.as_f64().map(Some).ok_or_else(|| format!("{key}: not a number")),
    }
}

/// A strict optional integer.
pub(crate) fn integer(object: &Map<String, Value>, key: &str) -> Strict<Option<i64>> {
    match present(object, key) {
        None => Ok(None),
        Some(value) => int(value).map(Some).ok_or_else(|| format!("{key}: not an integer")),
    }
}

/// A strict optional boolean.
pub(crate) fn boolean(object: &Map<String, Value>, key: &str) -> Strict<Option<bool>> {
    match present(object, key) {
        None => Ok(None),
        Some(Value::Bool(flag)) => Ok(Some(*flag)),
        Some(_) => Err(format!("{key}: not a boolean")),
    }
}

/// A strict optional list of strings.
pub(crate) fn strings(object: &Map<String, Value>, key: &str) -> Strict<Option<Vec<String>>> {
    match present(object, key) {
        None => Ok(None),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                item.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| format!("{key}: not a list of strings"))
            })
            .collect::<Result<Vec<_>, _>>()
            .map(Some),
        Some(_) => Err(format!("{key}: not a list")),
    }
}

/// The value as an object, else a strict failure naming `what`.
pub(crate) fn object<'a>(value: &'a Value, what: &str) -> Strict<&'a Map<String, Value>> {
    value.as_object().ok_or_else(|| format!("{what}: not an object"))
}

/// A lenient string: nil for any other type.
pub(crate) fn text(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_owned)
}
