//! Page keys: single keys an extension's command answers on a browser page.
//!
//! A catalog op asks for one with a `keyboard` entry whose `when` names `browserFocused`
//! (`{"key": "f", "when": "browserFocused"}`). The Mac app runs the op when the person presses
//! that key on a page that left it alone while no text field had focus: the same report the
//! built-in single-key browser actions use (link hints, `j` scroll), so a key typed into a field
//! never reaches an extension. A page key is a letter, Shift plus a letter, or `/`.
//!
//! The person rebinds them in the extension's own settings: the extension keeps
//! `{"<op>": ["<key>", ...]}` under its storage key [`OVERRIDES_KEY`], and `apps-list` answers
//! each op's keys from it (an empty list unbinds the op). A write of that key tells every
//! client (`apps-changed`), so the app routes the new keys at once.
//!
//! `apps-list` gives each palette command its keys as `page_keys`; the app reads nothing else.

use serde_json::Value;

/// The storage key an extension keeps the person's page key bindings under.
pub(super) const OVERRIDES_KEY: &str = "cmux.keys";
/// The most keys one op answers.
const MAX_KEYS: usize = 4;
/// The `when` term that makes a `keyboard` entry a page key.
const PAGE_TERM: &str = "browserFocused";

/// Whether `key` is a key the app can report from a page: `a` to `z` or `/`, with at most Shift.
pub(super) fn is_page_key(key: &str) -> bool {
    let bare = key.strip_prefix("shift+").unwrap_or(key);
    bare.len() == 1 && bare.chars().all(|c| c.is_ascii_lowercase() || c == '/')
}

/// Whether a `when` condition asks for a browser page: `browserFocused` as one of its terms,
/// not negated.
fn names_page(when: &str) -> bool {
    when.split(['&', '|']).map(str::trim).any(|term| term == PAGE_TERM)
}

/// The page keys an op's catalog entry asks for (its `keyboard` entries on a page).
fn defaults(entry: &Value) -> Vec<String> {
    entry
        .get("keyboard")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|k| k.get("when").and_then(Value::as_str).is_some_and(names_page))
        .filter_map(|k| k.get("key").and_then(Value::as_str))
        .filter(|key| is_page_key(key))
        .map(str::to_string)
        .take(MAX_KEYS)
        .collect()
}

/// The keys `op` answers: the person's binding from `overrides` when it is a list of page keys,
/// else the catalog's defaults. Only an op that has default page keys can be rebound, so an
/// extension cannot claim keys for an op its catalog never offered on a page.
pub(super) fn keys(op: &str, entry: &Value, overrides: Option<&Value>) -> Vec<String> {
    let defaults = defaults(entry);
    if defaults.is_empty() {
        return defaults;
    }
    let Some(bound) = overrides.and_then(|o| o.get(op)).and_then(Value::as_array) else {
        return defaults;
    };
    let mut keys: Vec<String> = Vec::new();
    for key in bound.iter().filter_map(Value::as_str) {
        if !is_page_key(key) {
            // A binding cmux cannot route is ignored whole, so a typo never unbinds the op.
            return defaults;
        }
        if !keys.iter().any(|k| k == key) && keys.len() < MAX_KEYS {
            keys.push(key.to_string());
        }
    }
    keys
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
            { "key": "h" }
        ] })
    }

    #[test]
    fn only_bare_keys_on_a_page_are_page_keys() {
        assert_eq!(keys("x.hints", &entry(), None), vec!["f", "shift+f"]);
        assert!(is_page_key("/") && is_page_key("shift+d") && is_page_key("a"));
        assert!(
            !is_page_key("cmd+f")
                && !is_page_key("alt+f")
                && !is_page_key("F")
                && !is_page_key("1")
        );
        assert!(!is_page_key("enter") && !is_page_key("shift+") && !is_page_key(""));
        assert!(!names_page("!browserFocused"));
    }

    #[test]
    fn the_persons_binding_replaces_the_defaults() {
        let overrides = json!({ "x.hints": ["t", "shift+t", "t"], "x.other": ["q"] });
        assert_eq!(keys("x.hints", &entry(), Some(&overrides)), vec!["t", "shift+t"]);
        let unbound = json!({ "x.hints": [] });
        assert!(
            keys("x.hints", &entry(), Some(&unbound)).is_empty(),
            "an empty list unbinds the op"
        );
        let typo = json!({ "x.hints": ["t", "cmd+t"] });
        assert_eq!(
            keys("x.hints", &entry(), Some(&typo)),
            vec!["f", "shift+f"],
            "a key cmux cannot route keeps the defaults"
        );
    }

    #[test]
    fn an_op_with_no_page_key_cannot_be_given_one() {
        let overrides = json!({ "x.save": ["s"] });
        assert!(
            keys("x.save", &json!({ "palette": { "title": "Save" } }), Some(&overrides)).is_empty()
        );
    }
}
