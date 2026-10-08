//! Where an app-rendered browser tab goes and which tab the app made
//! (the end-to-end paths are in tests/browser_open_app.rs).

use serde_json::{Map, Value, json};

use super::*;

fn object(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

#[test]
fn no_parent_means_no_named_pane() {
    let route = object(json!({"machine": "current", "session": "current"}));
    let params =
        object(json!({"url": "https://a.test", "machine": "current", "session": "current"}));
    assert_eq!(named_pane_tab(&route, &params), None);
}

#[test]
fn a_named_workspace_resolves_to_its_current_screen_pane_and_tab() {
    let route = object(json!({"session": "current"}));
    let params = object(json!({"workspace": "ws_a"}));
    assert_eq!(
        Value::Object(named_pane_tab(&route, &params).unwrap()),
        json!({"session": "current", "workspace": "ws_a", "screen": "current",
               "pane": "current", "tab": "current"})
    );
}

#[test]
fn a_named_pane_id_gets_no_ancestors_it_did_not_name() {
    // An exact pane id resolves alone; a `current` screen above it could be
    // another screen and fail the parent check.
    let route = Map::new();
    let params = object(json!({"pane": "pane_b"}));
    assert_eq!(
        Value::Object(named_pane_tab(&route, &params).unwrap()),
        json!({"pane": "pane_b", "tab": "current"})
    );
}

#[test]
fn the_created_tab_is_the_first_tab_id_in_created() {
    let reply = json!({"created": ["ws_x", "tab_new", "tab_other"]});
    assert_eq!(created_tab(&reply).as_deref(), Some("tab_new"));
    assert_eq!(created_tab(&json!({"created": []})), None);
    assert_eq!(created_tab(&json!({"ran": true})), None);
}

#[test]
fn open_browser_targets_a_tab_of_the_pane_or_nothing() {
    let params = open_browser_params("https://a.test", Some("tab_c"));
    assert_eq!(params["action"], "openBrowser");
    assert_eq!(params["args"], json!({"url": "https://a.test"}));
    assert_eq!(params["target"], "tab:tab_c");
    assert_eq!(params["wait"], true);
    assert!(open_browser_params("https://a.test", None).get("target").is_none());
}
