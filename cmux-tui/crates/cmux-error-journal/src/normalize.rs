//! Turns a message into its template: values (times, ids, paths, URLs, numbers, quoted strings)
//! become placeholders so occurrences that differ only in values fold into one entry. The rules
//! of the Swift `ErrorNormalizer`.

use crate::text::{trim_whitespaces, utf8_prefix};
use regex::{Regex, RegexBuilder};
use std::sync::OnceLock;

const RULES: [(&str, &str); 12] = [
    (r"\x1b\[[0-9;]*[A-Za-z]", ""),
    (r"\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?", "<time>"),
    (r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", "<uuid>"),
    (r"(?i)\b0x[0-9a-f]+\b", "<hex>"),
    (r#"[a-z]+://[^\s"'<>)]+"#, "<url>"),
    (
        r#"(?:~|/(?:Users|private|tmp|var|Applications|Library|opt|System|Volumes))(?:/[^\s"':,()\[\]]+)+"#,
        "<path>",
    ),
    (r#""[^"\n]{0,200}""#, "\"<str>\""),
    (r"'[^'\n]{0,200}'", "'<str>'"),
    (r"\b[A-Za-z]+_[0-9a-f]{6,}\b", "<id>"),
    (r"\b[0-9a-f]*\d[0-9a-f]*[a-f][0-9a-f]*\b|\b[0-9a-f]*[a-f][0-9a-f]*\d[0-9a-f]*\b", "<id>"),
    (r"\d+(?:\.\d+)?", "<n>"),
    (r"\s+", " "),
];

fn rules() -> &'static [(Regex, &'static str)] {
    static RULES_COMPILED: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    RULES_COMPILED.get_or_init(|| {
        RULES
            .iter()
            .filter_map(|(pattern, replacement)| {
                RegexBuilder::new(pattern)
                    .size_limit(64 << 20)
                    .build()
                    .ok()
                    .map(|regex| (regex, *replacement))
            })
            .collect()
    })
}

/// `message` with its values replaced by placeholders, trimmed and cut to `max_bytes` UTF-8 bytes.
pub fn template(message: &str, max_bytes: usize) -> String {
    let mut text = message.to_owned();
    for (rule, replacement) in rules() {
        text = rule.replace_all(&text, regex::NoExpand(replacement)).into_owned();
    }
    utf8_prefix(trim_whitespaces(&text), max_bytes)
}
