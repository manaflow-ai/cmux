//! The Swift casts the readers make on `JSONSerialization` output, with the same answers.
//!
//! - `as? String`: a string only.
//! - `as? Int`: a number that is exactly an integer in range (`2.0` is 2, `2.5` is nil), or a
//!   boolean (Foundation's booleans are `NSNumber`s, 1 and 0).
//! - `as? Bool`: a boolean, or the number 0 or 1.
//! - `as? Double` / `NSNumber.doubleValue`: any number, or a boolean as 1 or 0.
//! - `as? [[String: Any]]`, `as? [String]`: all or nothing, so one element of another type makes
//!   the whole array nil.
//! - `dictionary[key] != nil`: the key is present, even with `null` (`NSNull` is a value).

use serde_json::{Map, Value};

pub type Object = Map<String, Value>;

pub fn string(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str)
}

/// `as? String` that is not empty (`flatMap { $0.isEmpty ? nil : $0 }`).
pub fn non_empty(value: Option<&Value>) -> Option<&str> {
    string(value).filter(|text| !text.is_empty())
}

pub fn int(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Bool(flag) => Some(i64::from(*flag)),
        Value::Number(number) => {
            if let Some(whole) = number.as_i64() {
                return Some(whole);
            }
            if number.is_u64() {
                return None;
            }
            let float = number.as_f64()?;
            // -2^63 and 2^63 are exact doubles; an i64 holds the first, not the second.
            #[allow(
                clippy::cast_possible_truncation,
                reason = "the value is integral and inside i64's range, checked first"
            )]
            let whole = (float.fract() == 0.0
                && (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&float))
            .then_some(float as i64);
            whole
        }
        _ => None,
    }
}

pub fn boolean(value: Option<&Value>) -> Option<bool> {
    match value? {
        Value::Bool(flag) => Some(*flag),
        Value::Number(_) => {
            let number = double(value)?;
            if number == 0.0 {
                Some(false)
            } else if number == 1.0 {
                Some(true)
            } else {
                None
            }
        }
        _ => None,
    }
}

pub fn double(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Bool(flag) => Some(if *flag { 1.0 } else { 0.0 }),
        Value::Number(number) => number.as_f64(),
        _ => None,
    }
}

pub fn object(value: Option<&Value>) -> Option<&Object> {
    value.and_then(Value::as_object)
}

/// `as? [[String: Any]]`: every element an object, else nil.
pub fn objects(value: Option<&Value>) -> Option<Vec<&Object>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}

/// `as? [String]`: every element a string, else nil.
pub fn strings(value: Option<&Value>) -> Option<Vec<&str>> {
    value?.as_array()?.iter().map(Value::as_str).collect()
}

/// `JSONSerialization.jsonObject(with:)` (an error when not JSON), then `as? [String: Any]`.
pub fn parse_object(bytes: &[u8]) -> Result<Option<Object>, serde_json::Error> {
    Ok(match serde_json::from_slice::<Value>(bytes)? {
        Value::Object(map) => Some(map),
        _ => None,
    })
}

/// `try? JSONSerialization.jsonObject(with:) as? [String: Any]`.
pub fn object_or_none(bytes: &[u8]) -> Option<Object> {
    parse_object(bytes).ok().flatten()
}
