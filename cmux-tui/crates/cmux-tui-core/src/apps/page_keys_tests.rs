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
        !is_page_key("cmd+f") && !is_page_key("alt+f") && !is_page_key("F") && !is_page_key("1")
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
