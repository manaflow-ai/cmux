//! A programmatic `pane.split` (CLI, MCP, socket, SDK) keeps the caller's
//! focus unless it passes `focus: true`, like `tab.create_terminal`. The
//! user's own split (the app's or the TUI's raw `split`) still focuses the new
//! pane. Agent evals (tests/agent-evals/RESULTS.md, failure mode 1): split
//! moved focus in 26 of 59 runs while every agent told the user "your
//! terminal is unchanged".
//!
//! `pane.split` also takes `argv` or `shell`, so an agent that splits to run
//! one command gets that command's tab and no stray empty shell (failure
//! mode 3).

use serde_json::{Value, json};

use super::*;
use crate::resource::PanePublicId;
use crate::resource_api::public_session_snapshot;
use crate::{SplitDir, SurfaceOptions, TerminalSpawnOptions};

fn send(mux: &Arc<Mux>, operation: &str, fields: Value, key: Option<&str>) -> Value {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let mut envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("split-focus-{operation}"),
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

/// The pane `session.snapshot` reports as focused.
fn focused_pane(mux: &Arc<Mux>) -> String {
    let snapshot = public_session_snapshot(mux).unwrap();
    let focused = snapshot["panes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|pane| pane["focused"] == true)
        .map(|pane| pane["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(focused.len(), 1, "exactly one pane is focused: {snapshot}");
    focused[0].clone()
}

fn pane_tabs(mux: &Arc<Mux>, pane: &str) -> Vec<crate::SurfaceId> {
    let id = PanePublicId::parse(pane.to_string()).unwrap();
    mux.with_state(|state| state.pane_by_public_id(&id).map(|pane| pane.tabs.clone()))
        .expect("pane exists")
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("split-focus", SurfaceOptions::default())
}

#[test]
fn programmatic_split_keeps_the_callers_focus() {
    let mux = mux();
    let first = focused_workspace(&mux, "keep-focus");
    assert_eq!(focused_pane(&mux), first);
    let split = send(
        &mux,
        "pane.split",
        json!({"pane":first,"direction":"right"}),
        Some("keep-focus-split"),
    );
    let created = split["value"]["pane_id"].as_str().unwrap();
    assert_ne!(created, first);
    assert_eq!(focused_pane(&mux), first, "pane.split without focus moved the user's focus");
}

#[test]
fn programmatic_split_with_focus_true_focuses_the_new_pane() {
    let mux = mux();
    let first = focused_workspace(&mux, "focus-true");
    let split = send(
        &mux,
        "pane.split",
        json!({"pane":first,"direction":"down","focus":true}),
        Some("focus-true-split"),
    );
    let created = split["value"]["pane_id"].as_str().unwrap().to_string();
    assert_eq!(focused_pane(&mux), created);
}

#[test]
fn programmatic_split_with_focus_false_keeps_focus() {
    let mux = mux();
    let first = focused_workspace(&mux, "focus-false");
    send(
        &mux,
        "pane.split",
        json!({"pane":first,"direction":"right","viewport_width":0.5,"focus":false}),
        Some("focus-false-split"),
    );
    assert_eq!(focused_pane(&mux), first);
}

#[test]
fn the_users_raw_split_still_focuses_the_new_pane() {
    let mux = mux();
    let first = focused_workspace(&mux, "raw-split");
    let target = mux
        .with_state(|state| {
            state.pane_by_public_id(&PanePublicId::parse(first.clone()).unwrap()).map(|p| p.id)
        })
        .unwrap();
    let surface = mux
        .split_with_options(target, SplitDir::Right, TerminalSpawnOptions::default(), None)
        .unwrap();
    let new_pane = mux.with_state(|state| state.pane_of(surface.id)).unwrap();
    assert_eq!(mux.with_state(|state| state.active_pane()), Some(new_pane));
    assert_ne!(focused_pane(&mux), first);
}

#[test]
fn split_with_argv_runs_the_command_in_the_new_panes_only_tab() {
    let mux = mux();
    let first = focused_workspace(&mux, "split-argv");
    let split = send(
        &mux,
        "pane.split",
        json!({"pane":first,"direction":"right","argv":["/bin/sh","-c","sleep 30"]}),
        Some("split-argv-split"),
    );
    let created = split["value"]["pane_id"].as_str().unwrap();
    let tabs = pane_tabs(&mux, created);
    assert_eq!(tabs.len(), 1, "the split made one tab, no extra shell");
    let argv = mux.surface(tabs[0]).and_then(|surface| surface.spawn_argv()).unwrap();
    assert_eq!(argv, vec!["/bin/sh", "-c", "sleep 30"]);
    assert_eq!(focused_pane(&mux), first);
}

#[test]
fn split_with_shell_runs_the_script() {
    let mux = mux();
    let first = focused_workspace(&mux, "split-shell");
    let split = send(
        &mux,
        "pane.split",
        json!({"pane":first,"direction":"down","shell":"sleep 30"}),
        Some("split-shell-split"),
    );
    let created = split["value"]["pane_id"].as_str().unwrap();
    let tabs = pane_tabs(&mux, created);
    assert_eq!(tabs.len(), 1);
    let argv = mux.surface(tabs[0]).and_then(|surface| surface.spawn_argv()).unwrap();
    assert_eq!(argv.last().map(String::as_str), Some("sleep 30"), "{argv:?}");
}

/// The workspace `session.snapshot` reports as focused.
fn focused_workspace_id(mux: &Arc<Mux>) -> String {
    let snapshot = public_session_snapshot(mux).unwrap();
    let focused = snapshot["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|workspace| workspace["focused"] == true)
        .map(|workspace| workspace["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(focused.len(), 1, "exactly one workspace is focused: {snapshot}");
    focused[0].clone()
}

/// `workspace.create` keeps the caller's focus like `pane.split` (agent
/// evals: the last two `focus_stolen` runs, new-workspace-background).
#[test]
fn workspace_create_keeps_the_callers_focus() {
    for initial_content in ["terminal", "empty"] {
        let mux = mux();
        let home = focused_workspace(&mux, &format!("ws-keep-{initial_content}"));
        let before = focused_workspace_id(&mux);
        let created = send(
            &mux,
            "workspace.create",
            json!({"initial_content":initial_content,"name":"background"}),
            Some(&format!("ws-keep-{initial_content}-create")),
        );
        let new_id = created["value"]["workspace_id"].as_str().unwrap();
        assert_ne!(new_id, before);
        assert_eq!(
            focused_workspace_id(&mux),
            before,
            "workspace.create ({initial_content}) without focus moved the user's focus"
        );
        if initial_content == "terminal" {
            assert_eq!(focused_pane(&mux), home);
        }
    }
}

#[test]
fn workspace_create_with_focus_true_focuses_it() {
    for initial_content in ["terminal", "empty"] {
        let mux = mux();
        focused_workspace(&mux, &format!("ws-focus-{initial_content}"));
        let created = send(
            &mux,
            "workspace.create",
            json!({"initial_content":initial_content,"name":"shown","focus":true}),
            Some(&format!("ws-focus-{initial_content}-create")),
        );
        let new_id = created["value"]["workspace_id"].as_str().unwrap();
        assert_eq!(focused_workspace_id(&mux), new_id);
    }
}
