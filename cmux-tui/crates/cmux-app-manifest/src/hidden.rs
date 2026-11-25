//! Characters that hide what code does (extensibility-DESIGN.md 12.1 item 12,
//! step 11): an app's script and its manifest strings are refused when they
//! carry one.
//!
//! - Text-direction controls (U+202A..U+202E, U+2066..U+2069) and the
//!   direction marks (U+200E, U+200F, U+061C) reorder what a reader sees
//!   without changing what a parser reads (the "Trojan Source" class).
//! - Zero-width and invisible characters (U+200B, U+2060..U+2064) and the
//!   tag and supplementary variation-selector blocks (U+E0000..U+E007F,
//!   U+E0100..U+E01EF) carry text no reader sees; an editor extension's
//!   malicious update hid its payload in them.
//!
//! Kept: U+200C and U+200D (needed by Persian, Indic scripts and emoji),
//! U+FE00..U+FE0F (an emoji's presentation), and U+FEFF in a script, where a
//! byte-order mark or a regex that strips one is ordinary. A manifest string
//! refuses U+FEFF too: it never needs one.

use serde_json::Value;

use crate::issue::{Issue, escape};

/// Where a script or a manifest string is read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Context {
    /// A script or other source file.
    Code,
    /// A string in a manifest (names, descriptions, ids, labels).
    ManifestString,
}

/// One hidden character: 1-based line and column (in characters), and its
/// code point as `U+XXXX`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hidden {
    pub line: u32,
    pub column: u32,
    pub code_point: String,
}

impl Hidden {
    /// What it is, never the text around it.
    pub fn describe(&self) -> &'static str {
        describe(self.code_point.as_str())
    }
}

/// Whether `character` is refused in `context`.
pub fn is_hidden(character: char, context: Context) -> bool {
    match character {
        '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' => true,
        '\u{200E}' | '\u{200F}' | '\u{061C}' => true,
        '\u{200B}' | '\u{2060}'..='\u{2064}' => true,
        '\u{E0000}'..='\u{E007F}' | '\u{E0100}'..='\u{E01EF}' => true,
        '\u{FEFF}' => context == Context::ManifestString,
        _ => false,
    }
}

/// The first hidden character in `text`, if any.
pub fn first_hidden(text: &str, context: Context) -> Option<Hidden> {
    for (index, line) in text.split('\n').enumerate() {
        for (column, character) in line.chars().enumerate() {
            if is_hidden(character, context) {
                return Some(Hidden {
                    line: u32::try_from(index).unwrap_or(u32::MAX).saturating_add(1),
                    column: u32::try_from(column).unwrap_or(u32::MAX).saturating_add(1),
                    code_point: format!("U+{:04X}", u32::from(character)),
                });
            }
        }
    }
    None
}

fn describe(code_point: &str) -> &'static str {
    match code_point {
        "U+202A" | "U+202B" | "U+202C" | "U+202D" | "U+202E" | "U+2066" | "U+2067" | "U+2068"
        | "U+2069" | "U+200E" | "U+200F" | "U+061C" => "an invisible text-direction character",
        _ => "an invisible character",
    }
}

/// Every manifest string (keys too) that carries a hidden character, one
/// issue per string, addressed by its JSON pointer. The value is never
/// quoted.
pub(crate) fn manifest_issues(manifest: &Value) -> Vec<Issue> {
    let mut out = Vec::new();
    walk(manifest, String::new(), &mut out);
    out
}

fn walk(value: &Value, at: String, out: &mut Vec<Issue>) {
    match value {
        Value::String(text) => push(text, &at, out),
        Value::Array(items) => {
            for (index, item) in items.iter().enumerate() {
                walk(item, format!("{at}/{index}"), out);
            }
        }
        Value::Object(map) => {
            for (key, item) in map {
                // A key is reported at its object: the pointer would carry
                // the hidden character itself.
                if first_hidden(key, Context::ManifestString).is_some() {
                    push(key, &at, out);
                    continue;
                }
                walk(item, format!("{at}/{}", escape(key)), out);
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn push(text: &str, at: &str, out: &mut Vec<Issue>) {
    if let Some(hidden) = first_hidden(text, Context::ManifestString) {
        out.push(Issue::error(
            at,
            "text.hidden",
            format!(
                "has {} ({}); what you read is not what it says",
                hidden.describe(),
                hidden.code_point
            ),
        ));
    }
}

/// The issue for a script (`at` is the manifest pointer that names it,
/// `file` its package path) that carries a hidden character.
pub(crate) fn script_issue(at: &str, file: &str, text: &str) -> Option<Issue> {
    let hidden = first_hidden(text, Context::Code)?;
    Some(Issue::error(
        at,
        "text.hidden",
        format!(
            "{file}:{}:{} has {} ({}); what you read is not what runs",
            hidden.line,
            hidden.column,
            hidden.describe(),
            hidden.code_point
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn direction_controls_and_invisible_characters_are_found_with_their_position() {
        let found = first_hidden("let a = 1;\nlet b = \"\u{202E}x\";\n", Context::Code);
        assert_eq!(found, Some(Hidden { line: 2, column: 10, code_point: "U+202E".into() }));
        for character in ['\u{2066}', '\u{200F}', '\u{200B}', '\u{2062}', '\u{E0041}', '\u{E0100}']
        {
            assert!(is_hidden(character, Context::Code), "{character:?}");
        }
    }

    #[test]
    fn ordinary_text_passes() {
        // A family emoji (ZWJ), a heart with its presentation selector,
        // Persian with a ZWNJ, and a script that strips a byte-order mark.
        let text = "const a = '\u{1F468}\u{200D}\u{1F4BB} \u{2764}\u{FE0F} \u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}';\ntext.replace(/^\u{FEFF}/, '');\n";
        assert_eq!(first_hidden(text, Context::Code), None);
        assert!(is_hidden('\u{FEFF}', Context::ManifestString));
    }

    #[test]
    fn a_manifest_string_or_key_with_one_is_refused_by_pointer_without_its_value() {
        let manifest = json!({
            "name": "Clock\u{202E}",
            "presentation": { "sidebarItem": { "title\u{200B}": "x" } },
            "files": ["main.js", "ok"]
        });
        let issues = manifest_issues(&manifest);
        let pointers: Vec<&str> = issues.iter().map(|issue| issue.path.as_str()).collect();
        assert_eq!(pointers, ["/name", "/presentation/sidebarItem"]);
        assert!(issues.iter().all(|issue| issue.code == "text.hidden"));
        assert!(!issues[0].message.contains("Clock"));
    }
}
