//! The last check before a report leaves the Mac: every key and string value of the encoded JSON
//! that could carry private data. A string may hold only letters, digits, space and `. _ + ( ) -`,
//! at most 128 characters, no run of 32 or more letters and digits mixing both (a token), and
//! none of the person's words. A finding names the JSON path only, never the value.

use serde::Serialize;
use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

use crate::classify::{is_uuid, normalized_terms};

pub const MAX_STRING_LENGTH: usize = 128;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LeakKind {
    #[serde(rename = "notJSON")]
    NotJson,
    UnsafeCharacter,
    TooLong,
    Token,
    PersonalTerm,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Finding {
    pub kind: LeakKind,
    pub path: String,
}

impl LeakKind {
    pub fn raw(self) -> &'static str {
        match self {
            Self::NotJson => "notJSON",
            Self::UnsafeCharacter => "unsafeCharacter",
            Self::TooLong => "tooLong",
            Self::Token => "token",
            Self::PersonalTerm => "personalTerm",
        }
    }
}

impl Finding {
    /// The finding as a log line (kind and path only).
    pub fn description(&self) -> String {
        format!("{} at {}", self.kind.raw(), self.path)
    }
}

pub struct Scanner {
    terms: Vec<String>,
}

impl Scanner {
    /// Terms under 4 letters, and words of the report's own vocabulary, are ignored.
    pub fn new(forbidden_terms: &[String]) -> Self {
        Self { terms: normalized_terms(forbidden_terms) }
    }

    pub fn findings(&self, json: &[u8]) -> Vec<Finding> {
        let Ok(root) = serde_json::from_slice::<Value>(json) else {
            return vec![Finding { kind: LeakKind::NotJson, path: "$".to_owned() }];
        };
        let mut found = Vec::new();
        self.walk(&root, "$", &mut found);
        found
    }

    fn walk(&self, value: &Value, path: &str, found: &mut Vec<Finding>) {
        match value {
            Value::Object(object) => {
                for (key, child) in object {
                    // Keys are the schema's names: checked for shape, not for personal terms.
                    match self.kind(key, false) {
                        Some(kind) => {
                            let at = format!("{path}.<key>");
                            found.push(Finding { kind, path: at.clone() });
                            self.walk(child, &at, found);
                        }
                        None => self.walk(child, &format!("{path}.{key}"), found),
                    }
                }
            }
            Value::Array(items) => {
                for (index, child) in items.iter().enumerate() {
                    self.walk(child, &format!("{path}[{index}]"), found);
                }
            }
            Value::String(text) => {
                if let Some(kind) = self.kind(text, true) {
                    found.push(Finding { kind, path: path.to_owned() });
                }
            }
            _ => {}
        }
    }

    /// What is wrong with `text`, `None` when it may be sent.
    pub fn kind(&self, text: &str, personal: bool) -> Option<LeakKind> {
        if text.graphemes(true).count() > MAX_STRING_LENGTH {
            return Some(LeakKind::TooLong);
        }
        if !text.bytes().all(|byte| byte.is_ascii_alphanumeric() || b" ._+()-".contains(&byte)) {
            return Some(LeakKind::UnsafeCharacter);
        }
        if is_uuid(text) {
            return None;
        }
        if has_token_run(text) {
            return Some(LeakKind::Token);
        }
        let lowered = text.to_lowercase();
        if personal && self.terms.iter().any(|term| lowered.contains(term.as_str())) {
            return Some(LeakKind::PersonalTerm);
        }
        None
    }
}

/// A run of 32 or more letters and digits holding both.
pub fn has_token_run(text: &str) -> bool {
    let (mut length, mut letters, mut digits) = (0, false, false);
    for character in text.chars() {
        if character.is_ascii_alphanumeric() {
            length += 1;
            letters |= character.is_ascii_alphabetic();
            digits |= character.is_ascii_digit();
            if length >= 32 && letters && digits {
                return true;
            }
        } else {
            (length, letters, digits) = (0, false, false);
        }
    }
    false
}
