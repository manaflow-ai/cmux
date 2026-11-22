//! The canonical JSON bytes and digest a gesture ticket binds a question's
//! answers and annotations by (CmuxNextAgentPane `AcpmuxSecretKey
//! .canonicalJSON`, `canonicalDigest`; acpmux `hub/approvers.rs`
//! `canonical_json` writes the same bytes): object keys in UTF-8 byte order,
//! no whitespace, and only `"`, `\` and control characters escaped (`\b \f
//! \n \r \t`, else `\u00xx`). A float that is not integral, or not below
//! 1e15 in size, has no canonical form (Swift returns nil), so the value has
//! no digest.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fmt::Write;

/// The canonical JSON of `value`, or None (a number with no canonical form).
pub fn canonical_json(value: &Value) -> Option<String> {
    let mut out = String::new();
    write_json(value, &mut out).then_some(out)
}

/// The lower-case hex sha256 of [`canonical_json`].
pub fn canonical_digest(value: &Value) -> Option<String> {
    let text = canonical_json(value)?;
    let mut hex = String::with_capacity(64);
    for byte in Sha256::digest(text.as_bytes()) {
        let _ = write!(hex, "{byte:02x}");
    }
    Some(hex)
}

fn write_json(value: &Value, out: &mut String) -> bool {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            if n.is_f64() {
                // Swift: an integral Double below 1e15 is written as Int64.
                let Some(f) = n.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 1e15) else {
                    return false;
                };
                let _ = write!(out, "{f:.0}");
            } else {
                let _ = write!(out, "{n}");
            }
        }
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                if !write_json(item, out) {
                    return false;
                }
            }
            out.push(']');
        }
        Value::Object(object) => {
            let mut keys: Vec<&String> = object.keys().collect();
            keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
            out.push('{');
            for (i, key) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_string(key, out);
                out.push(':');
                if !object.get(key).is_some_and(|item| write_json(item, out)) {
                    return false;
                }
            }
            out.push('}');
        }
    }
    true
}

fn write_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if u32::from(c) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", u32::from(c));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}
