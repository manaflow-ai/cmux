//! How the Swift host read a `WKScriptMessage` body (`[String: Any]` from JSON), as functions on
//! `serde_json::Value`: which casts succeeded, how `NSNumber` converted, how `String.count` counted.
//! The decoders read the page's params only through these, so each keeps the cast it had.

use serde_json::{Map, Number, Value};
use unicode_segmentation::UnicodeSegmentation;

/// The `params` of a request: `object["params"] as? [String: Any]`, nil when it is not an object.
#[derive(Clone, Copy)]
pub struct Params<'a>(pub Option<&'a Map<String, Value>>);

/// A key `params?["k"].map { $0 as? T }`: absent, or there with a value (`None` when the cast failed).
pub enum Present<T> {
    Absent,
    Is(Option<T>),
}

impl<'a> Params<'a> {
    pub fn get(&self, key: &str) -> Option<&'a Value> {
        self.0.and_then(|map| map.get(key))
    }

    /// `params?[key] as? String`.
    pub fn string(&self, key: &str) -> Option<&'a str> {
        self.get(key).and_then(Value::as_str)
    }

    /// `params?[key] as? Bool`.
    pub fn boolean(&self, key: &str) -> Option<bool> {
        self.get(key).and_then(as_bool)
    }

    /// `params?[key] as? Bool == true`.
    pub fn is_true(&self, key: &str) -> bool {
        self.boolean(key) == Some(true)
    }

    /// `(params?[key] as? NSNumber)?.intValue`.
    pub fn ns_int(&self, key: &str) -> Option<i64> {
        self.get(key).and_then(ns_int)
    }

    /// `params?[key] as? Int`.
    pub fn int(&self, key: &str) -> Option<i64> {
        self.get(key).and_then(as_int)
    }

    /// `params?[key] as? Double`.
    pub fn double(&self, key: &str) -> Option<f64> {
        self.get(key).and_then(as_double)
    }

    /// `params?[key] as? [String]`: every element a string.
    pub fn strings(&self, key: &str) -> Option<Vec<&'a str>> {
        self.get(key).and_then(Value::as_array)?.iter().map(Value::as_str).collect()
    }

    /// `params?[key].map { $0 as? String }`.
    pub fn present_string(&self, key: &str) -> Present<&'a str> {
        match self.get(key) {
            None => Present::Absent,
            Some(value) => Present::Is(value.as_str()),
        }
    }

    /// `Set(params.keys) == [only]`, with params there.
    pub fn only_key(&self, only: &str) -> bool {
        self.0.is_some_and(|map| map.len() == 1 && map.contains_key(only))
    }
}

/// `value as? Bool` on a bridged JSON value: `true`/`false`, and the numbers 0 and 1 (an
/// `NSNumber` casts to `Bool` when it is exactly one of them).
pub fn as_bool(value: &Value) -> Option<bool> {
    match value {
        Value::Bool(flag) => Some(*flag),
        Value::Number(number) => match number.as_f64() {
            Some(0.0) => Some(false),
            Some(1.0) => Some(true),
            _ => None,
        },
        _ => None,
    }
}

/// `value as? Double`: any number, and a boolean as 0 or 1.
pub fn as_double(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64(),
        Value::Bool(flag) => Some(if *flag { 1.0 } else { 0.0 }),
        _ => None,
    }
}

/// `value as? Int`: an integral number that fits, and a boolean as 0 or 1.
pub fn as_int(value: &Value) -> Option<i64> {
    match value {
        Value::Bool(flag) => Some(i64::from(*flag)),
        Value::Number(number) => number_int(number),
        _ => None,
    }
}

fn number_int(number: &Number) -> Option<i64> {
    if let Some(int) = number.as_i64() {
        return Some(int);
    }
    if number.as_u64().is_some() {
        return None;
    }
    let float = number.as_f64()?;
    if float.fract() == 0.0 { whole_to_int(float) } else { None }
}

/// A finite whole number as `i64`, nil when it does not fit (no `as` cast, which would saturate).
fn whole_to_int(float: f64) -> Option<i64> {
    if !float.is_finite() {
        return None;
    }
    format!("{float:.0}").parse::<i64>().ok()
}

/// `(value as? NSNumber)?.intValue`: a number or boolean, a fraction cut toward zero; a value
/// that does not fit answers nil here (Foundation clamps it; no page sends one).
pub fn ns_int(value: &Value) -> Option<i64> {
    match value {
        Value::Bool(flag) => Some(i64::from(*flag)),
        Value::Number(number) => {
            if let Some(int) = number.as_i64() {
                return Some(int);
            }
            if number.as_u64().is_some() {
                return Some(i64::MAX);
            }
            number.as_f64().and_then(|float| whole_to_int(float.trunc()))
        }
        _ => None,
    }
}

/// `value as? NSNumber` that is no boolean (`CFGetTypeID(number) != CFBooleanGetTypeID()`).
pub fn plain_number(value: &Value) -> Option<&Number> {
    match value {
        Value::Number(number) => Some(number),
        _ => None,
    }
}

/// Swift's `String.prefix(n)`: the first `n` extended grapheme clusters.
pub fn prefix(text: &str, limit: usize) -> String {
    text.graphemes(true).take(limit).collect()
}

/// `text.count <= limit` without counting past it.
pub fn count_within(text: &str, limit: usize) -> bool {
    text.graphemes(true).take(limit.saturating_add(1)).count() <= limit
}

/// `text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`.
pub fn is_blank(text: &str) -> bool {
    text.chars().all(char::is_whitespace)
}

/// `1...limit` UTF-8 bytes, the length caps most ids take.
pub fn bytes_within(text: &str, limit: usize) -> bool {
    text.len() <= limit
}

/// A non-empty string of at most `limit` UTF-8 bytes.
pub fn id_bytes(text: Option<&str>, limit: usize) -> Option<&str> {
    text.filter(|text| !text.is_empty() && text.len() <= limit)
}

/// A non-empty string of at most `limit` characters.
pub fn id_chars(text: Option<&str>, limit: usize) -> Option<&str> {
    text.filter(|text| !text.is_empty() && count_within(text, limit))
}
