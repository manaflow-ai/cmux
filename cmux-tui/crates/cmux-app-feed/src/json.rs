//! The JSON `JSONSerialization` writes with `.sortedKeys` and `.withoutEscapingSlashes`, and the
//! small readers the rules share.

use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

/// `value` as compact sorted-key JSON, slashes unescaped, an integral number without a fraction
/// (Foundation writes `2.0` as `2`). Keys sort by their UTF-8 bytes.
pub fn canonical(value: &Value) -> String {
    let mut out = String::new();
    write(value, &mut out);
    out
}

fn write(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => out.push_str(&number_text(number)),
        Value::String(text) => write_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            out.push('{');
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write(&map[key], out);
            }
            out.push('}');
        }
    }
}

fn number_text(number: &serde_json::Number) -> String {
    if number.is_i64() || number.is_u64() {
        return number.to_string();
    }
    match number.as_f64() {
        Some(float) if float.is_finite() && float.fract() == 0.0 && float.abs() < 1e15 => {
            format!("{}", float as i64)
        }
        _ => number.to_string(),
    }
}

fn write_string(text: &str, out: &mut String) {
    // serde_json escapes exactly `"`, `\` and the C0 controls (`\b \f \n \r \t`, else `\u00xx`),
    // and never `/`: Foundation's writer with `.withoutEscapingSlashes`.
    out.push_str(&Value::String(text.to_owned()).to_string());
}

/// The lowercase hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `value[key]` when it is a string.
pub fn str_at<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// `value[key]` when it is an object.
pub fn obj_at<'a>(value: &'a Value, key: &str) -> Option<&'a Map<String, Value>> {
    value.get(key).and_then(Value::as_object)
}

/// `value[key]` when it is an array.
pub fn arr_at<'a>(value: &'a Value, key: &str) -> Option<&'a Vec<Value>> {
    value.get(key).and_then(Value::as_array)
}

/// Whether `value[key]` is the JSON boolean `true` (a `1` is not).
pub fn is_true(value: &Value, key: &str) -> bool {
    value.get(key) == Some(&Value::Bool(true))
}

/// An empty object, for a missing request.
pub fn empty() -> Value {
    Value::Object(Map::new())
}
