//! Page keys: single keys an extension's command answers on a browser page.
//!
//! A catalog op asks for one with a `keyboard` entry whose `when` names
//! `browserFocused` as one of its terms. The Mac app carries each raw
//! predicate beside the key and evaluates it again at dispatch time. The app
//! can report a letter, Shift plus a letter, or `/`; the extension can replace
//! those defaults in `cmux.keys`.

use std::collections::BTreeSet;

use serde_json::{Map, Value};

pub(super) const OVERRIDES_KEY: &str = "cmux.keys";
const MAX_KEYS: usize = 4;
const PAGE_TERM: &str = "browserFocused";

pub(super) fn is_page_key(key: &str) -> bool {
    let bare = key.strip_prefix("shift+").unwrap_or(key);
    bare.len() == 1 && bare.chars().all(|c| c.is_ascii_lowercase() || c == '/')
}

/// A browser term makes a catalog key eligible; the full predicate is carried
/// to the client and evaluated there.
fn names_page(when: &str) -> bool {
    when.split(['&', '|']).map(str::trim).any(|term| term == PAGE_TERM)
}

fn defaults(entry: &Value) -> Vec<(String, String)> {
    entry
        .get("keyboard")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|k| k.get("when").and_then(Value::as_str).is_some_and(names_page))
        .filter_map(|k| {
            let key = k.get("key").and_then(Value::as_str)?;
            let when = k.get("when").and_then(Value::as_str)?;
            is_page_key(key).then(|| (key.to_string(), when.to_string()))
        })
        .take(MAX_KEYS)
        .collect()
}

fn effective(op: &str, entry: &Value, overrides: Option<&Value>) -> Vec<(String, String)> {
    let defaults = defaults(entry);
    if defaults.is_empty() {
        return defaults;
    }
    let Some(bound) = overrides.and_then(|o| o.get(op)).and_then(Value::as_array) else {
        return defaults;
    };
    let mut keys = Vec::new();
    for key in bound.iter().filter_map(Value::as_str) {
        if !is_page_key(key) {
            return defaults;
        }
        if !keys.iter().any(|k| k == key) && keys.len() < MAX_KEYS {
            keys.push(key.to_string());
        }
    }
    if keys.is_empty() {
        return Vec::new();
    }
    let predicates: BTreeSet<&str> = defaults.iter().map(|(_, when)| when.as_str()).collect();
    if predicates.len() != 1 {
        return defaults;
    }
    let when = predicates.into_iter().next().unwrap_or(PAGE_TERM).to_string();
    keys.into_iter().map(|key| (key, when.clone())).collect()
}

pub(super) fn keys(op: &str, entry: &Value, overrides: Option<&Value>) -> Vec<String> {
    effective(op, entry, overrides).into_iter().map(|(key, _)| key).collect()
}

pub(super) fn when_map(op: &str, entry: &Value, overrides: Option<&Value>) -> Value {
    Value::Object(
        effective(op, entry, overrides)
            .into_iter()
            .map(|(key, when)| (key, Value::String(when)))
            .collect::<Map<String, Value>>(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn entry() -> Value {
        json!({ "keyboard": [
            { "key": "f", "when": "browserFocused" },
            { "key": "cmd+f", "when": "browserFocused" },
            { "key": "g", "when": "paneFocused:editor" },
            { "key": "shift+f", "when": "browserFocused && !readOnly" },
            { "key": "shift+g", "when": "browserFocused || paneFocused:editor" },
            { "key": "h" }
        ] })
    }

    fn uniform_entry() -> Value {
        json!({ "keyboard": [
            { "key": "f", "when": "browserFocused" },
            { "key": "shift+f", "when": "browserFocused" }
        ] })
    }

    #[test]
    fn only_bare_keys_on_a_page_are_page_keys() {
        assert_eq!(keys("x.hints", &entry(), None), vec!["f", "shift+f", "shift+g"]);
        assert_eq!(
            when_map("x.hints", &entry(), None),
            json!({ "f": "browserFocused", "shift+f": "browserFocused && !readOnly",
                    "shift+g": "browserFocused || paneFocused:editor" })
        );
        assert!(is_page_key("/") && is_page_key("shift+d") && is_page_key("a"));
        assert!(
            !is_page_key("cmd+f")
                && !is_page_key("alt+f")
                && !is_page_key("F")
                && !is_page_key("1")
        );
        assert!(!is_page_key("enter") && !is_page_key("shift+") && !is_page_key(""));
        assert!(!names_page("!browserFocused"));
        assert!(names_page("browserFocused && !readOnly"));
        assert!(names_page("browserFocused || paneFocused:editor"));
    }

    #[test]
    fn overrides_replace_defaults_but_invalid_values_do_not_unbind() {
        let overrides = json!({ "x.hints": ["t", "shift+t", "t"] });
        assert_eq!(keys("x.hints", &uniform_entry(), Some(&overrides)), vec!["t", "shift+t"]);
        assert!(keys("x.hints", &uniform_entry(), Some(&json!({ "x.hints": [] }))).is_empty());
        assert_eq!(
            keys("x.hints", &uniform_entry(), Some(&json!({ "x.hints": ["cmd+t"] }))),
            vec!["f", "shift+f"]
        );
        // A single override list cannot safely choose among heterogeneous raw predicates.
        assert_eq!(keys("x.hints", &entry(), Some(&overrides)), vec!["f", "shift+f", "shift+g"]);
    }
}
