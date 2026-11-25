//! JSON text as Apple's `JSONSerialization` writes it with `.prettyPrinted` and `.sortedKeys`: two-space
//! indent, `"key" : value`, keys in byte order, an empty array or object as its brackets around a blank
//! line, and `/` escaped as `\/` unless `.withoutEscapingSlashes` (`escape_slashes: false`).

use serde_json::Value;

/// `value` as Apple's pretty, sorted text (no trailing newline, like `JSONSerialization`).
pub fn pretty(value: &Value, escape_slashes: bool) -> String {
    let mut out = String::new();
    write(&mut out, value, 0, escape_slashes);
    out
}

fn write(out: &mut String, value: &Value, depth: usize, slashes: bool) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => out.push_str(&number.to_string()),
        Value::String(text) => string(out, text, slashes),
        Value::Array(items) => {
            out.push_str("[\n");
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push_str(",\n");
                }
                indent(out, depth + 1);
                write(out, item, depth + 1, slashes);
            }
            out.push('\n');
            indent(out, depth);
            out.push(']');
        }
        Value::Object(map) => {
            out.push_str("{\n");
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            for (index, key) in keys.iter().enumerate() {
                if index > 0 {
                    out.push_str(",\n");
                }
                indent(out, depth + 1);
                string(out, key, slashes);
                out.push_str(" : ");
                write(out, &map[key.as_str()], depth + 1, slashes);
            }
            out.push('\n');
            indent(out, depth);
            out.push('}');
        }
    }
}

fn indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn string(out: &mut String, text: &str, slashes: bool) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' if slashes => out.push_str("\\/"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}
