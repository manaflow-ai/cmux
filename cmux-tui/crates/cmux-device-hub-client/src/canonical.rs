//! Canonical JSON (PROTOCOL.md, "Computer Use approvals"): object keys sorted
//! by code point, no whitespace, integers only, and strings escaped only for
//! `"`, `\`, `\b \f \n \r \t` and other U+0000-U+001F as `\u00xx` (lowercase
//! hex). Everything else, `/` and non-ASCII included, is its UTF-8 bytes.

use serde_json::Value;
use sha2::{Digest, Sha256};

/// A value canonical JSON cannot encode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalError(pub String);

impl std::fmt::Display for CanonicalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "canonical JSON: {}", self.0)
    }
}

impl std::error::Error for CanonicalError {}

/// The canonical JSON text of `value`.
pub fn canonical_json(value: &Value) -> Result<String, CanonicalError> {
    let mut out = String::new();
    write_value(value, &mut out)?;
    Ok(out)
}

/// Lowercase hex SHA-256 of the canonical JSON of `value`.
pub fn canonical_sha256(value: &Value) -> Result<String, CanonicalError> {
    Ok(hex::encode(Sha256::digest(canonical_json(value)?.as_bytes())))
}

fn write_value(value: &Value, out: &mut String) -> Result<(), CanonicalError> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(number) => {
            if let Some(n) = number.as_i64() {
                out.push_str(&n.to_string());
            } else if let Some(n) = number.as_u64() {
                out.push_str(&n.to_string());
            } else {
                return Err(CanonicalError(format!("{number} is not an integer")));
            }
        }
        Value::String(text) => write_string(text, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_value(item, out)?;
            }
            out.push(']');
        }
        Value::Object(map) => {
            // Byte order of UTF-8 is code point order. Sorted here, not by the
            // map: serde_json's `preserve_order` feature may be on in the build.
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
            out.push('{');
            for (index, (key, item)) in entries.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write_value(item, out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn write_string(text: &str, out: &mut String) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn sorts_keys_and_escapes_only_controls() {
        let value = json!({"b": [1, true, null], "a": "\u{1}/é\"\\"});
        assert_eq!(
            canonical_json(&value).unwrap(),
            "{\"a\":\"\\u0001/é\\\"\\\\\",\"b\":[1,true,null]}"
        );
    }

    #[test]
    fn refuses_fractions() {
        assert!(canonical_json(&json!({"a": 1.5})).is_err());
    }
}
