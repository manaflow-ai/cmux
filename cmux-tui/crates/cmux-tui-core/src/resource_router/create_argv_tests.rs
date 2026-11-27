//! `tab.create_terminal`, `pane.create` and `screen.create` take `argv` or
//! `shell`, as `pane.split` and `workspace.create` do: the new terminal runs
//! that command instead of a plain shell (`cmux tab create terminal -- htop`
//! opens htop, not a shell that dropped it).

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::resource::TabPublicId;

fn reply(mux: &Arc<Mux>, operation: &str, fields: Value, key: &str) -> Result<Value, String> {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("create-argv-{key}"),
        "operation":operation,
        "params":params,
        "idempotency_key":key,
    });
    handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())
        .map_err(|error| format!("{error:?}"))
}

fn send(mux: &Arc<Mux>, operation: &str, fields: Value, key: &str) -> Value {
    let response =
        reply(mux, operation, fields, key).unwrap_or_else(|error| panic!("{operation}: {error}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"]["value"].clone()
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("create-argv", SurfaceOptions::default())
}

/// A workspace with one terminal; returns `(workspace_id, pane_id)`.
fn workspace(mux: &Arc<Mux>, key: &str) -> (String, String) {
    let created =
        send(mux, "workspace.create", json!({"initial_content":"terminal","name":key}), key);
    (
        created["workspace_id"].as_str().unwrap().to_string(),
        created["pane_id"].as_str().unwrap().to_string(),
    )
}

/// The spawn argv of the terminal tab a creation reported.
fn created_argv(mux: &Arc<Mux>, created: &Value) -> Vec<String> {
    let tab = TabPublicId::parse(created["tab_id"].as_str().unwrap().to_string()).unwrap();
    let surface = mux
        .with_state(|state| state.surface_by_tab_public_id(&tab).cloned())
        .expect("created tab exists");
    surface.spawn_argv().expect("terminal argv")
}

#[test]
fn tab_create_terminal_runs_argv() {
    let mux = mux();
    let (workspace, pane) = workspace(&mux, "tab-argv");
    let created = send(
        &mux,
        "tab.create_terminal",
        json!({"workspace":workspace,"pane":pane,"argv":["/bin/sh","-c","sleep 30"]}),
        "tab-argv-create",
    );
    assert_eq!(created_argv(&mux, &created), vec!["/bin/sh", "-c", "sleep 30"]);
}

#[test]
fn pane_create_runs_shell() {
    let mux = mux();
    let (workspace, _) = workspace(&mux, "pane-shell");
    let created = send(
        &mux,
        "pane.create",
        json!({"workspace":workspace,"shell":"sleep 30"}),
        "pane-shell-create",
    );
    let argv = created_argv(&mux, &created);
    assert_eq!(argv.last().map(String::as_str), Some("sleep 30"), "{argv:?}");
}

#[test]
fn screen_create_runs_argv() {
    let mux = mux();
    let (workspace, _) = workspace(&mux, "screen-argv");
    let created = send(
        &mux,
        "screen.create",
        json!({"workspace":workspace,"argv":["/bin/sh","-c","sleep 30"]}),
        "screen-argv-create",
    );
    assert_eq!(created_argv(&mux, &created), vec!["/bin/sh", "-c", "sleep 30"]);
}

#[test]
fn creations_refuse_argv_with_shell_and_an_empty_executable() {
    let mux = mux();
    let (workspace, pane) = workspace(&mux, "argv-refusals");
    for (index, fields) in [
        json!({"workspace":workspace,"pane":pane,"argv":["sh"],"shell":"true"}),
        json!({"workspace":workspace,"pane":pane,"argv":[""]}),
    ]
    .into_iter()
    .enumerate()
    {
        let response = reply(&mux, "tab.create_terminal", fields, &format!("argv-refusal-{index}"));
        assert!(
            response.as_ref().is_ok_and(|response| response["ok"] == false) || response.is_err(),
            "{response:?} was accepted"
        );
    }
}
