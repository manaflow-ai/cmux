//! The bytes a Computer Use app approval is bound to
//! (docs/computer-use-approvals.md, "The approval question").
//!
//! A request's `digest` is the lowercase hex SHA-256 of the canonical JSON of
//! the request object without its `digest` key. Every answer (the app's card,
//! the phone, polkit, Windows Hello, the device hub's signature over
//! `"cmux-cu-approval-v1\n<digest>\n<decision>"`) names that digest, so the
//! Swift host, the Rust host (Windows, Linux) and the hub must produce the
//! same bytes. `schemas/computer-use/approval-fixtures.json` is the shared
//! conformance fixture every implementation tests against.
//!
//! Canonical JSON here:
//! - object keys sorted by their UTF-8 bytes, at every depth;
//! - no whitespace between tokens;
//! - strings as UTF-8, escaping only `"`, `\` and the control characters
//!   below U+0020: `\b \f \n \r \t` by name, the rest as `\u00xx` (lowercase
//!   hex); `/` and non-ASCII characters are written as they are;
//! - numbers only as integers (`i64` or `u64`, no exponent, no fraction):
//!   a float has no single spelling across Swift and Rust, so it is refused.
//!
//! Nothing here decides an approval: it only computes and checks bytes.

// The crash ratchet keeps this crate at zero production panics.
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

use serde_json::Value;
use sha2::{Digest as _, Sha256};

/// The key a request carries its own digest under; never part of the digest.
pub const DIGEST_KEY: &str = "digest";

/// The prefix of the text a deciding device signs (device hub approvals).
pub const SIGNATURE_DOMAIN: &str = "cmux-cu-approval-v1";

/// Why a value has no canonical form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CanonicalError {
    /// A number with a fraction or an exponent.
    Float(String),
    /// The request is not a JSON object.
    NotAnObject,
}

impl std::fmt::Display for CanonicalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Float(n) => {
                write!(f, "the number {n} is not an integer; canonical JSON has none")
            }
            Self::NotAnObject => f.write_str("an approval request is a JSON object"),
        }
    }
}

impl std::error::Error for CanonicalError {}

/// The canonical JSON text of `value`.
pub fn canonical(value: &Value) -> Result<String, CanonicalError> {
    let mut out = String::new();
    write(value, &mut out)?;
    Ok(out)
}

/// The digest of `request`: SHA-256 of the canonical JSON of the object
/// without its `digest` key, as 64 lowercase hex characters.
pub fn digest(request: &Value) -> Result<String, CanonicalError> {
    let object = request.as_object().ok_or(CanonicalError::NotAnObject)?;
    let mut without = object.clone();
    without.remove(DIGEST_KEY);
    let text = canonical(&Value::Object(without))?;
    Ok(hex(&Sha256::digest(text.as_bytes())))
}

/// Whether `request` carries the digest of its own content. A missing,
/// malformed or different digest is `false` (fail closed).
pub fn verify(request: &Value) -> bool {
    let Some(claimed) = request.get(DIGEST_KEY).and_then(Value::as_str) else {
        return false;
    };
    match digest(request) {
        // Constant-time: the digest is public, but answers compare it often.
        Ok(actual) => constant_time_eq(actual.as_bytes(), claimed.as_bytes()),
        Err(_) => false,
    }
}

/// The text a deciding device signs for `decision` on the request with `digest`.
pub fn signed_text(digest: &str, decision: &str) -> String {
    format!("{SIGNATURE_DOMAIN}\n{digest}\n{decision}")
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from(DIGITS[usize::from(byte >> 4)]));
        out.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    out
}

fn write(value: &Value, out: &mut String) -> Result<(), CanonicalError> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                out.push_str(&i.to_string());
            } else if let Some(u) = n.as_u64() {
                out.push_str(&u.to_string());
            } else {
                return Err(CanonicalError::Float(n.to_string()));
            }
        }
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write(item, out)?;
            }
            out.push(']');
        }
        Value::Object(map) => {
            // Sorted here: serde_json's map keeps insertion order when a
            // crate in the build turns on `preserve_order`.
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
            out.push('{');
            for (index, (key, item)) in entries.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                write(item, out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if u32::from(c) < 0x20 => out.push_str(&format!("\\u{:04x}", u32::from(c))),
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const FIXTURES: &str = include_str!("../../../../schemas/computer-use/approval-fixtures.json");

    /// Each case of the shared fixture: `{request, canonical, digest}`.
    fn cases() -> Vec<Value> {
        let fixtures: Value = serde_json::from_str(FIXTURES).unwrap();
        let cases = match &fixtures {
            Value::Array(items) => items.clone(),
            other => other["cases"].as_array().cloned().unwrap_or_default(),
        };
        assert!(!cases.is_empty(), "the fixture has no cases");
        cases
    }

    #[test]
    fn every_fixture_has_its_canonical_bytes_and_digest() {
        for case in cases() {
            let request = &case["request"];
            let mut without = request.as_object().unwrap().clone();
            without.remove(DIGEST_KEY);
            assert_eq!(
                canonical(&Value::Object(without)).unwrap(),
                case["canonical"].as_str().unwrap(),
                "{}",
                case["name"]
            );
            assert_eq!(
                digest(request).unwrap(),
                case["digest"].as_str().unwrap(),
                "{}",
                case["name"]
            );
            let mut signed = request.clone();
            signed[DIGEST_KEY] = case["digest"].clone();
            assert!(verify(&signed), "{}", case["name"]);
        }
    }

    #[test]
    fn a_changed_field_or_digest_never_verifies() {
        for case in cases() {
            let mut signed = case["request"].clone();
            signed[DIGEST_KEY] = case["digest"].clone();
            let mut other_tool = signed.clone();
            other_tool["tool"] = json!("a_tool_no_fixture_names");
            assert!(!verify(&other_tool), "{}", case["name"]);
            let mut upper = signed.clone();
            upper[DIGEST_KEY] = json!(case["digest"].as_str().unwrap().to_uppercase());
            assert!(!verify(&upper), "{}", case["name"]);
            let mut missing = signed;
            missing.as_object_mut().unwrap().remove(DIGEST_KEY);
            assert!(!verify(&missing));
        }
    }

    #[test]
    fn key_order_and_whitespace_do_not_change_the_bytes() {
        let a: Value =
            serde_json::from_str(r#"{ "b": 1, "a": { "y": [1, 2], "x": null } }"#).unwrap();
        let b: Value = serde_json::from_str(r#"{"a":{"x":null,"y":[1,2]},"b":1}"#).unwrap();
        assert_eq!(canonical(&a).unwrap(), r#"{"a":{"x":null,"y":[1,2]},"b":1}"#);
        assert_eq!(digest(&a).unwrap(), digest(&b).unwrap());
    }

    #[test]
    fn strings_escape_only_what_json_requires() {
        let value = json!({"s": "a/b \"q\" \\ \n\t\u{1} Café ✓"});
        assert_eq!(
            canonical(&value).unwrap(),
            "{\"s\":\"a/b \\\"q\\\" \\\\ \\n\\t\\u0001 Café ✓\"}"
        );
    }

    #[test]
    fn floats_and_non_objects_have_no_digest() {
        assert_eq!(digest(&json!({"v": 1.5})), Err(CanonicalError::Float("1.5".into())));
        assert_eq!(digest(&json!([1])), Err(CanonicalError::NotAnObject));
        assert!(!verify(&json!({"v": 1.5, "digest": "00"})));
    }

    #[test]
    fn the_signed_text_names_the_domain_digest_and_decision() {
        assert_eq!(signed_text("ab", "once"), "cmux-cu-approval-v1\nab\nonce");
    }
}
