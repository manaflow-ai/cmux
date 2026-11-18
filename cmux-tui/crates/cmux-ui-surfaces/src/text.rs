//! Plain-text hygiene for every string that reaches a renderer.

use crate::caps;
use serde_json::Value;

/// Cap a string at [`caps::STRING_BYTES`] (on a char boundary, with an
/// ellipsis) and drop control characters other than newline and tab. The
/// result is still drawn as text, never parsed as markup.
pub(crate) fn clean(s: &str) -> String {
    let mut out = String::with_capacity(s.len().min(caps::STRING_BYTES));
    for ch in s.chars() {
        if ch.is_control() && ch != '\n' && ch != '\t' {
            continue;
        }
        if out.len() + ch.len_utf8() > caps::STRING_BYTES - 3 {
            out.push('…');
            return out;
        }
        out.push(ch);
    }
    out
}

/// The A2UI rule for a value shown as text: null is empty, strings as is,
/// anything else as compact JSON.
pub(crate) fn display(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Array(items) if items.iter().all(Value::is_string) => {
            items.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", ")
        }
        other => other.to_string(),
    }
}
