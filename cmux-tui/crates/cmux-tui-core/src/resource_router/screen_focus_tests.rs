//! A programmatic `screen.create` (CLI, socket, SDK) keeps the caller's
//! focus unless it passes `focus: true` (socket focus policy). The user's
//! own new screen (the TUI's `new-screen`) still shows the new screen.

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::resource_api::public_session_snapshot;

fn send(mux: &Arc<Mux>, operation: &str, fields: Value, key: Option<&str>) -> Value {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let mut envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("screen-focus-{operation}"),
        "operation":operation,
        "params":params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let response = handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

/// A focused workspace with one terminal pane; returns that pane's id.
fn focused_workspace(mux: &Arc<Mux>, key: &str) -> String {
    let created =
        send(mux, "workspace.create", json!({"initial_content":"terminal","name":key}), Some(key));
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    send(mux, "workspace.focus", json!({"workspace":workspace}), Some(&format!("{key}-focus")));
    created["value"]["pane_id"].as_str().unwrap().to_string()
}

/// The one record of `kind` (`screens`, `panes`) that `session.snapshot`
/// reports as focused.
fn focused(mux: &Arc<Mux>, kind: &str) -> String {
    let snapshot = public_session_snapshot(mux).unwrap();
    let focused = snapshot[kind]
        .as_array()
        .unwrap()
        .iter()
        .filter(|record| record["focused"] == true)
        .map(|record| record["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(focused.len(), 1, "exactly one of {kind} is focused: {snapshot}");
    focused[0].clone()
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("screen-focus", SurfaceOptions::default())
}

/// `screen.create` keeps the caller's focus (bench round 3, T8/T9: the new
/// screen took the daemon focus, and a reconnected TUI then showed it).
#[test]
fn w4j_screen_create_keeps_the_callers_focus() {
    let mux = mux();
    let home = focused_workspace(&mux, "screen-keep");
    let screen = focused(&mux, "screens");
    send(&mux, "screen.create", json!({"name":"background"}), Some("screen-keep-create"));
    let snapshot = public_session_snapshot(&mux).unwrap();
    assert_eq!(snapshot["screens"].as_array().unwrap().len(), 2, "{snapshot}");
    assert_eq!(focused(&mux, "screens"), screen, "screen.create without focus moved the focus");
    assert_eq!(focused(&mux, "panes"), home);
}

#[test]
fn w4j_screen_create_with_focus_true_focuses_the_new_screen() {
    let mux = mux();
    let home = focused_workspace(&mux, "screen-focus");
    let screen = focused(&mux, "screens");
    send(&mux, "screen.create", json!({"name":"shown","focus":true}), Some("screen-focus-create"));
    assert_ne!(focused(&mux, "screens"), screen);
    assert_ne!(focused(&mux, "panes"), home);
}
