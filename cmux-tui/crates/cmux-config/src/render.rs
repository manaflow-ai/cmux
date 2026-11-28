//! JSON text in the exact form Swift's `JSONValue.prettyText` and
//! `compactText` write it: sorted keys, two-space indent, integers without a
//! fraction, and only the escapes Swift's `quote` emits.

use serde_json::Value;

use crate::value::is_exact_integer;

/// Pretty JSON text. `base_indent` prefixes every line after the first so the
/// value can be spliced into an indented document.
pub fn pretty(value: &Value, base_indent: &str) -> String {
    let mut out = String::new();
    render(value, Some("  "), 0, base_indent, &mut out);
    out
}

/// Single-line JSON text with sorted keys.
pub fn compact(value: &Value) -> String {
    let mut out = String::new();
    render(value, None, 0, "", &mut out);
    out
}

fn render(value: &Value, indent: Option<&str>, level: usize, base: &str, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => out.push_str(&format_number(number.as_f64().unwrap_or(0.0))),
        Value::String(text) => out.push_str(&quote(text)),
        Value::Array(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            let Some(unit) = indent else {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    render(item, None, 0, "", out);
                }
                out.push(']');
                return;
            };
            let inner = format!("{base}{}", unit.repeat(level + 1));
            out.push_str("[\n");
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push_str(",\n");
                }
                out.push_str(&inner);
                render(item, indent, level + 1, base, out);
            }
            out.push('\n');
            out.push_str(base);
            out.push_str(&unit.repeat(level));
            out.push(']');
        }
        Value::Object(members) => {
            if members.is_empty() {
                out.push_str("{}");
                return;
            }
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort();
            let Some(unit) = indent else {
                out.push('{');
                for (index, key) in keys.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    out.push_str(&quote(key));
                    out.push(':');
                    render(&members[*key], None, 0, "", out);
                }
                out.push('}');
                return;
            };
            let inner = format!("{base}{}", unit.repeat(level + 1));
            out.push_str("{\n");
            for (index, key) in keys.iter().enumerate() {
                if index > 0 {
                    out.push_str(",\n");
                }
                out.push_str(&inner);
                out.push_str(&quote(key));
                out.push_str(": ");
                render(&members[*key], indent, level + 1, base, out);
            }
            out.push('\n');
            out.push_str(base);
            out.push_str(&unit.repeat(level));
            out.push('}');
        }
    }
}

/// A number as Swift writes it: an exact integer below 1e15 without a
/// fraction, otherwise Swift's shortest `Double` description.
pub fn format_number(x: f64) -> String {
    if is_exact_integer(x) {
        return (x as i64).to_string();
    }
    let magnitude = x.abs();
    if magnitude != 0.0 && !(1e-4..1e16).contains(&magnitude) {
        // Swift: `1e-05`, `1.5e+16` (sign and at least two exponent digits).
        let text = format!("{x:e}");
        let (mantissa, exponent) = text.split_once('e').unwrap_or((&text, "0"));
        let (sign, digits) = match exponent.strip_prefix('-') {
            Some(digits) => ('-', digits),
            None => ('+', exponent),
        };
        return format!("{mantissa}e{sign}{digits:0>2}");
    }
    let text = format!("{x}");
    if text.contains('.') || text.contains("inf") || text.contains("NaN") {
        text
    } else {
        format!("{text}.0")
    }
}

/// JSON string literal for `text` (Swift `JSONValue.quote`).
pub fn quote(text: &str) -> String {
    let mut result = String::with_capacity(text.len() + 2);
    result.push('"');
    for scalar in text.chars() {
        match scalar {
            '"' => result.push_str("\\\""),
            '\\' => result.push_str("\\\\"),
            '\n' => result.push_str("\\n"),
            '\r' => result.push_str("\\r"),
            '\t' => result.push_str("\\t"),
            '\u{08}' => result.push_str("\\b"),
            '\u{0C}' => result.push_str("\\f"),
            other if (other as u32) < 0x20 => {
                result.push_str(&format!("\\u{:04x}", other as u32));
            }
            other => result.push(other),
        }
    }
    result.push('"');
    result
}
