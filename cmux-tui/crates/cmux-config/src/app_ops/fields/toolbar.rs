//! Swift `PaneToolbarButtonsSetting.parse` and `BrowserToolbarButtonsSetting.parse`: the pinned toolbar
//! buttons, with the schema's button lists (`tabs.toolbarButtons`, `browser.toolbarButtons`).

use serde_json::{Value, json};

use super::reader::{choices_of, default_of, invalid, quoted, value_at};

fn fallback(key: &str) -> Vec<Value> {
    default_of(key).as_array().cloned().unwrap_or_default()
}

pub(super) fn pane(root: &Value) -> (Value, Vec<Value>) {
    let key = "tabs.toolbarButtons";
    let values = choices_of(key);
    let Some(value) = value_at(root, &["tabs", "toolbarButtons"]) else {
        return (json!({"pinned": fallback(key)}), vec![]);
    };
    let Some(items) = value.as_array() else {
        let diag = invalid(key, "expected an array of action ids");
        return (json!({"pinned": fallback(key)}), vec![diag]);
    };
    let mut diags = vec![];
    let known: Vec<&str> = items
        .iter()
        .filter_map(Value::as_str)
        .filter(|id| values.iter().any(|v| v == id))
        .collect();
    if known.len() != items.len() {
        diags.push(invalid(key, format!("expected action ids: {}", quoted(&values))));
    }
    // The user's order; a repeated id keeps its first place.
    let mut ids: Vec<&str> = vec![];
    for id in &known {
        if !ids.contains(id) {
            ids.push(id);
        }
    }
    if ids.len() != known.len() {
        diags.push(invalid(key, "an action id is listed more than once"));
    }
    (json!({"pinned": ids}), diags)
}

pub(super) fn browser(root: &Value) -> (Value, Vec<Value>) {
    let key = "browser.toolbarButtons";
    let values = choices_of(key);
    let Some(value) = value_at(root, &["browser", "toolbarButtons"]) else {
        return (json!({"pinned": fallback(key)}), vec![]);
    };
    let Some(items) = value.as_array() else {
        let diag = invalid(key, "expected an array of button ids");
        return (json!({"pinned": fallback(key)}), vec![diag]);
    };
    let ids: Vec<&str> = items
        .iter()
        .filter_map(Value::as_str)
        .filter(|id| values.iter().any(|v| v == id))
        .collect();
    let mut diags = vec![];
    if ids.len() != items.len() {
        diags.push(invalid(key, format!("expected button ids: {}", quoted(&values))));
    }
    // Always in toolbar order.
    let pinned: Vec<&String> = values.iter().filter(|v| ids.contains(&v.as_str())).collect();
    (json!({"pinned": pinned}), diags)
}
