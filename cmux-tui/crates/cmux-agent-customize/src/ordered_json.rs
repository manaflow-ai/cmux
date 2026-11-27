//! Edits one top-level member of a JSON settings file and leaves the rest as it was written.
//!
//! The workspace's `serde_json` keeps maps sorted (no `preserve_order`), so parsing a person's
//! `~/.claude/settings.json` into a `Value` and writing it back would reorder every key. Here the
//! top-level members are kept in order with each value's own text ([`RawValue`]), and only the
//! member being changed is written anew.

use serde::de::{Deserializer, MapAccess, Visitor};
use serde_json::value::RawValue;
use std::fmt;

/// A JSON object's members in file order, each value as its original text.
pub(crate) struct Members(pub(crate) Vec<(String, Box<RawValue>)>);

impl<'de> serde::Deserialize<'de> for Members {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Ordered;
        impl<'de> Visitor<'de> for Ordered {
            type Value = Members;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a JSON object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Members, A::Error> {
                let mut members: Vec<(String, Box<RawValue>)> = Vec::new();
                while let Some((key, value)) = map.next_entry::<String, Box<RawValue>>()? {
                    // A repeated key: the last one wins, as in every JSON reader the CLIs use.
                    members.retain(|(existing, _)| *existing != key);
                    members.push((key, value));
                }
                Ok(Members(members))
            }
        }
        deserializer.deserialize_map(Ordered)
    }
}

impl Members {
    /// The members of `text`; an empty or blank file is an empty object.
    pub(crate) fn parse(text: &str) -> Result<Self, serde_json::Error> {
        if text.trim().is_empty() {
            return Ok(Self(Vec::new()));
        }
        serde_json::from_str(text)
    }

    pub(crate) fn get(&self, key: &str) -> Option<&RawValue> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_ref())
    }

    /// Sets `key` (in place when present, else at the end); `None` removes it.
    pub(crate) fn set(&mut self, key: &str, value: Option<Box<RawValue>>) {
        match (self.0.iter().position(|(k, _)| k == key), value) {
            (Some(at), Some(value)) => {
                if let Some(entry) = self.0.get_mut(at) {
                    entry.1 = value;
                }
            }
            (Some(at), None) => {
                self.0.remove(at);
            }
            (None, Some(value)) => self.0.push((key.to_owned(), value)),
            (None, None) => {}
        }
    }

    /// The object as text, `indent` spaces deep, members one per line. Values keep their text.
    pub(crate) fn render(&self, indent: usize) -> String {
        if self.0.is_empty() {
            return "{}".to_owned();
        }
        let pad = " ".repeat(indent + 2);
        let lines: Vec<String> = self
            .0
            .iter()
            .map(|(key, value)| {
                let key = serde_json::to_string(key).unwrap_or_default();
                format!("{pad}{key}: {}", value.get())
            })
            .collect();
        format!("{{\n{}\n{}}}", lines.join(",\n"), " ".repeat(indent))
    }
}

/// A raw JSON string value (`None` only if serde_json cannot write a string, which it always can).
pub(crate) fn raw_string(text: &str) -> Option<Box<RawValue>> {
    serde_json::value::to_raw_value(text).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_order_and_untouched_text() {
        let text = "{\n  \"zeta\": 1,\n  \"alpha\": {\"b\": 2,   \"a\": 1},\n  \"env\": {\"TOKEN\": \"x\"}\n}\n";
        let mut members = Members::parse(text).unwrap();
        assert_eq!(
            members.0.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(),
            ["zeta", "alpha", "env"]
        );
        members.set("new", raw_string("v"));
        assert_eq!(
            members.render(0),
            "{\n  \"zeta\": 1,\n  \"alpha\": {\"b\": 2,   \"a\": 1},\n  \"env\": {\"TOKEN\": \"x\"},\n  \"new\": \"v\"\n}"
        );
        members.set("alpha", None);
        assert!(members.get("alpha").is_none());
        assert_eq!(Members::parse("  ").unwrap().render(0), "{}");
        assert!(Members::parse("[1]").is_err());
    }
}
