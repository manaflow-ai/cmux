//! JSON value helpers with the semantics of the Swift `JSONValue`: every
//! number is a double, so `1` and `1.0` are the same value.

use serde_json::{Map, Number, Value};

/// `value` with every number in the one form Swift's `JSONValue` would give
/// it: an exact integer below 1e15 as an integer, anything else as a double.
/// Every value that enters the crate passes through here, so `==` agrees
/// with Swift's equality.
pub fn canonical(value: Value) -> Value {
    match value {
        Value::Number(number) => number_value(number.as_f64().unwrap_or(0.0)),
        Value::Array(items) => Value::Array(items.into_iter().map(canonical).collect()),
        Value::Object(members) => {
            Value::Object(members.into_iter().map(|(key, item)| (key, canonical(item))).collect())
        }
        other => other,
    }
}

/// A JSON number for `x` in canonical form (null for a non-finite value).
pub fn number_value(x: f64) -> Value {
    if is_exact_integer(x) {
        Value::Number(Number::from(x as i64))
    } else {
        Number::from_f64(x).map_or(Value::Null, Value::Number)
    }
}

pub(crate) fn is_exact_integer(x: f64) -> bool {
    x.is_finite() && x.fract() == 0.0 && x.abs() < 1e15
}

/// The value at a key path, or `None` when any step is missing.
pub fn value_at<'a, S: AsRef<str>>(root: &'a Value, path: &[S]) -> Option<&'a Value> {
    let mut current = root;
    for key in path {
        current = current.as_object()?.get(key.as_ref())?;
    }
    Some(current)
}

/// `value` wrapped in one object per path component.
pub fn nest(value: Value, path: &[String]) -> Value {
    path.iter().rev().fold(value, |inner, key| {
        let mut members = Map::new();
        members.insert(key.clone(), inner);
        Value::Object(members)
    })
}

/// A copy of `root` with `value` at `path`, creating objects along the way;
/// a non-object in the way is replaced (Swift `JSONValue.setting`).
pub fn with_value(root: &Value, value: Value, path: &[String]) -> Value {
    let Some((head, rest)) = path.split_first() else {
        return value;
    };
    let mut members = root.as_object().cloned().unwrap_or_default();
    let child = members.get(head).cloned().unwrap_or_else(|| Value::Object(Map::new()));
    members.insert(head.clone(), with_value(&child, value, rest));
    Value::Object(members)
}

/// Whether `value` is an object with no members.
pub(crate) fn is_empty_object(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Object(members)) if members.is_empty())
}

/// Number of characters, as Swift's `String.count` (scalar count; the
/// settings keys and names this measures are not composed graphemes).
pub(crate) fn char_count(text: &str) -> usize {
    text.chars().count()
}
