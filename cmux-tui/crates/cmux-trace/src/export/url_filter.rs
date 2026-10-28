//! The URL filter on Chromium's JSON trace (p09-observability task 133): an agent can start a
//! recording (`trace.start`), so a page's address never reaches the export. Before an event is
//! written, every URL-like value is replaced with `__stripped__`, the marker Chromium's own JSON
//! writer puts where its argument filter removed args (`base/trace_event/trace_event_impl.cc`,
//! `AppendAsJSON`; the predicate is `chrome/common/trace_event_args_allowlist.cc`).
//!
//! URL-like is:
//! - an argument named `url`, `src` or `href` (any case), or a name ending in `url`, `_src` or
//!   `_href` (`frame_url`, `documentURL`), whatever its value;
//! - a string that starts with `data:` (a data URI) or holds a `scheme://` anywhere.
//!
//! Nested objects and arrays are filtered member by member and written again as JSON; a value
//! with nothing to strip keeps its text as Chromium wrote it. Event and track names that look like
//! a URL are stripped the same way.

use crate::json::Value;

/// What a stripped value is written as.
pub(super) const STRIPPED: &str = "__stripped__";

/// Whether an argument named `key` holds a URL, whatever its value.
pub(super) fn is_url_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    matches!(key.as_str(), "src" | "href")
        || key.ends_with("url")
        || key.ends_with("_src")
        || key.ends_with("_href")
}

/// Whether `text` is a data URI or holds a `scheme://` URL.
pub(super) fn is_url_text(text: &str) -> bool {
    let trimmed = text.trim_start();
    if trimmed.len() >= 5 && trimmed[..5].eq_ignore_ascii_case("data:") {
        return true;
    }
    let bytes = text.as_bytes();
    let mut from = 0;
    while let Some(found) = text[from..].find("://") {
        let at = from + found;
        // A scheme is a letter, then letters, digits, `+`, `-` or `.` (RFC 3986, section 3.1): the run
        // of those characters right before `://` holds a letter.
        let start = bytes[..at]
            .iter()
            .rposition(|&byte| {
                !(byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.'))
            })
            .map_or(0, |before| before + 1);
        if bytes[start..at].iter().any(u8::is_ascii_alphabetic) {
            return true;
        }
        from = at + 3;
    }
    false
}

/// `text` itself, or the marker when it looks like a URL.
pub(super) fn scrub(text: &str) -> &str {
    if is_url_text(text) { STRIPPED } else { text }
}

/// How many values of `args` the filter strips.
pub(super) fn stripped_in(args: Option<&Value<'_>>) -> u64 {
    let Some(entries) = args.and_then(Value::as_object) else { return 0 };
    entries
        .iter()
        .map(|(key, value)| if is_url_key(key) { 1 } else { stripped_values(value) })
        .sum()
}

fn stripped_values(value: &Value<'_>) -> u64 {
    match value {
        Value::String(text) => u64::from(is_url_text(text)),
        Value::Array(items, _) => items.iter().map(stripped_values).sum(),
        Value::Object(entries, _) => entries
            .iter()
            .map(|(key, value)| if is_url_key(key) { 1 } else { stripped_values(value) })
            .sum(),
        Value::Null | Value::Bool(_) | Value::Number(_) => 0,
    }
}

/// A nested value's JSON with its URL-like members stripped; None when it has none (its text as
/// written is kept).
pub(super) fn nested_json(value: &Value<'_>) -> Option<String> {
    if stripped_values(value) == 0 {
        return None;
    }
    let mut out = String::new();
    write_json(&mut out, value);
    Some(out)
}

fn write_json(out: &mut String, value: &Value<'_>) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(text) => out.push_str(text),
        Value::String(text) => write_string(out, scrub(text)),
        Value::Array(items, _) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_json(out, item);
            }
            out.push(']');
        }
        Value::Object(entries, _) => {
            out.push('{');
            for (index, (key, item)) in entries.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_string(out, key);
                out.push(':');
                if is_url_key(key) {
                    write_string(out, STRIPPED);
                } else {
                    write_json(out, item);
                }
            }
            out.push('}');
        }
    }
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if u32::from(control) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", u32::from(control)));
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json;

    #[test]
    fn export_filter_url_keys() {
        for key in
            ["url", "URL", "src", "href", "frame_url", "documentURL", "image_src", "link_href"]
        {
            assert!(is_url_key(key), "{key}");
        }
        for key in ["src_file", "src_func", "name", "id", "hrefs_count", "source"] {
            assert!(!is_url_key(key), "{key}");
        }
    }

    #[test]
    fn export_filter_url_text() {
        for text in [
            "https://example.com/a",
            "chrome-extension://abc/x.js",
            "  data:text/html,<p>hi",
            "DATA:image/png;base64,AAAA",
            "loading blob:https://example.com/1 now",
            "file:///Users/me/secret.txt",
            "a+b.c-d://host",
        ] {
            assert!(is_url_text(text), "{text}");
        }
        for text in ["a.cc", "://no-scheme", "1://digit-first", "metadata: 3", "Renderer", ""] {
            assert!(!is_url_text(text), "{text}");
        }
    }

    #[test]
    fn export_filter_nested_json_keeps_the_rest() {
        let parsed = json::parse(
            r#"{"frame":"F1","url":"about:blank","list":["x","https://e.com/\"q"],"n":2,"ok":true,"z":null}"#,
        )
        .unwrap();
        let out = nested_json(&parsed).expect("something to strip");
        assert_eq!(
            out,
            r#"{"frame":"F1","url":"__stripped__","list":["x","__stripped__"],"n":2,"ok":true,"z":null}"#
        );
        assert_eq!(json::parse(&out).unwrap().get("frame").and_then(Value::as_str), Some("F1"));
        let clean = json::parse(r#"{"a":[1,"b"]}"#).unwrap();
        assert_eq!(nested_json(&clean), None, "a clean value keeps its own text");
    }

    #[test]
    fn export_filter_counts_and_names() {
        let args = json::parse(r#"{"url":"x","src_file":"a.cc","data":{"href":"y","t":"ws://h"}}"#)
            .unwrap();
        assert_eq!(stripped_in(Some(&args)), 3);
        assert_eq!(scrub("Navigate https://example.com"), STRIPPED);
        assert_eq!(scrub("RunTask"), "RunTask");
    }
}
