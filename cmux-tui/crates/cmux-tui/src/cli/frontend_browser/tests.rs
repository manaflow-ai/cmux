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

#[test]
fn only_a_run_the_app_never_started_counts_as_never_ran() {
    let refused = |error: Value| never_ran(&Failure::Resource(error));
    assert!(refused(
        json!({"code": "unavailable", "details": {"reason": "This page has no tabs."}})
    ));
    assert!(refused(json!({"code": "busy", "details": {"state": "not_run"}})));
    assert!(refused(json!({"code": "timeout", "details": {"not_run": true}})));
    assert!(!refused(json!({"code": "timeout", "details": {"state": "in_progress"}})));
    assert!(!refused(json!({"code": "operation.failed", "details": {}})));
    assert!(!never_ran(&Failure::Transport("broken pipe".into())));
}

#[test]
fn the_default_pane_is_the_daemons_current_one() {
    let route = object(json!({"machine": "current", "session": "current"}));
    let selector = default_pane_tab(&route);
    for key in ["machine", "session", "workspace", "screen", "pane", "tab"] {
        assert_eq!(selector[key], "current", "{key}");
    }
}

#[test]
fn a_failed_reveal_names_the_workspace_and_the_reason() {
    let line = reveal_failure("ws_a", &json!({"code": "unavailable", "message": "no window"}));
    assert_eq!(line, "cmux: tab opened in ws_a, but the window could not show it: no window");
    let line = reveal_failure("ws_a", &json!({"code": "app.unreachable"}));
    assert!(line.ends_with(": app.unreachable"), "{line}");
}
