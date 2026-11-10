//! A programmatic tab creation in a pane (`pane.run`, `tab.create_terminal`,
//! `tab.create_browser` from the CLI, MCP, an SDK or the socket) keeps the
//! pane's selected tab unless it passes `focus: true`, as `pane.split`,
//! `screen.create` and `workspace.create` keep their focus. The person's own
//! new tab (the app's or the TUI's `new-tab` and `run-command`, which do not
//! come through the router) still selects the new tab.
//!
//! Bench round 5 orchestration (W6-A): `cmux agent start NAME --pane P
//! --no-focus` made the agent tab P's selected tab in the daemon (`tab list`
//! said `focused: true`), so the person's view jumped to it at the next TUI
//! reconnect (`daemon restart`). herdr `--no-focus` and Rex `--focus=false`
//! keep both the view and the selected tab.

use serde_json::{Map, Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::resource_api::public_session_snapshot;
use crate::workspace_registry::WorkspaceMutation;

fn send(mux: &Arc<Mux>, operation: &str, fields: Value, key: &str) -> Value {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("w6a-{key}"),
        "operation":operation,
        "params":params,
        "idempotency_key":key,
    });
    let response = handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

/// A focused workspace with one terminal pane: its pane id and its one tab id.
fn workspace(mux: &Arc<Mux>, key: &str) -> (String, String) {
    let created =
        send(mux, "workspace.create", json!({"initial_content":"terminal","name":key}), key);
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    send(mux, "workspace.focus", json!({"workspace":workspace}), &format!("{key}-focus"));
    let pane = created["value"]["pane_id"].as_str().unwrap().to_string();
    let tabs = tabs_of(mux, &pane);
    assert_eq!(tabs.len(), 1, "a new terminal workspace has one tab: {tabs:?}");
    (pane, tabs[0].0.clone())
}

/// The tabs `session.snapshot` (what `cmux tab list` reads) lists in `pane`,
/// with each one's `focused` (the pane's selected tab).
fn tabs_of(mux: &Arc<Mux>, pane: &str) -> Vec<(String, bool)> {
    let snapshot = public_session_snapshot(mux).unwrap();
    snapshot["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|tab| tab["pane_id"] == pane)
        .map(|tab| (tab["id"].as_str().unwrap().to_string(), tab["focused"] == true))
        .collect()
}

fn selected_tab(mux: &Arc<Mux>, pane: &str) -> String {
    let selected: Vec<String> =
        tabs_of(mux, pane).into_iter().filter(|(_, focused)| *focused).map(|(id, _)| id).collect();
    assert_eq!(selected.len(), 1, "a pane selects exactly one tab: {selected:?}");
    selected[0].clone()
}

fn created_tab(result: &Value) -> String {
    result["value"]["tab_id"]
        .as_str()
        .or_else(|| result["value"]["tab"].as_str())
        .unwrap_or_else(|| panic!("creation names its tab: {result}"))
        .to_string()
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("w6a-tab-create-focus", SurfaceOptions::default())
}

const AGENT: [&str; 3] = ["/bin/sh", "-c", "sleep 30"];

#[test]
fn w6a_pane_run_keeps_the_panes_selected_tab() {
    let mux = mux();
    let (pane, shell) = workspace(&mux, "run-keeps");
    let run = send(
        &mux,
        "pane.run",
        json!({"pane":pane,"argv":AGENT,"name":"ct5-beta","on_exit":"keep"}),
        "run-keeps-run",
    );
    let agent = created_tab(&run);
    assert_ne!(agent, shell);
    assert_eq!(tabs_of(&mux, &pane).len(), 2);
    assert_eq!(
        selected_tab(&mux, &pane),
        shell,
        "pane.run without focus made the new tab the pane's selected tab"
    );
}

#[test]
fn w6a_pane_run_with_focus_true_selects_the_new_tab() {
    let mux = mux();
    let (pane, _) = workspace(&mux, "run-focus");
    let run =
        send(&mux, "pane.run", json!({"pane":pane,"argv":AGENT,"focus":true}), "run-focus-run");
    assert_eq!(selected_tab(&mux, &pane), created_tab(&run));
}

#[test]
fn w6a_tab_create_terminal_in_a_pane_keeps_the_selected_tab() {
    let mux = mux();
    let (pane, shell) = workspace(&mux, "tab-keeps");
    let created =
        send(&mux, "tab.create_terminal", json!({"pane":pane,"argv":AGENT}), "tab-keeps-create");
    assert_ne!(created_tab(&created), shell);
    assert_eq!(selected_tab(&mux, &pane), shell);
    let shown = send(
        &mux,
        "tab.create_terminal",
        json!({"pane":pane,"argv":AGENT,"focus":true}),
        "tab-keeps-create-shown",
    );
    assert_eq!(selected_tab(&mux, &pane), created_tab(&shown));
}

#[test]
fn w6a_tab_create_browser_in_a_pane_keeps_the_selected_tab() {
    let mux = mux();
    mux.attach_test_browser_provider(1);
    let (pane, shell) = workspace(&mux, "browser-keeps");
    send(
        &mux,
        "tab.create_browser",
        json!({"pane":pane,"url":"about:blank"}),
        "browser-keeps-create",
    );
    assert_eq!(tabs_of(&mux, &pane).len(), 2);
    assert_eq!(selected_tab(&mux, &pane), shell);
}

#[test]
fn w6a_the_persons_own_new_tab_still_selects_it() {
    let mux = mux();
    let (pane, shell) = workspace(&mux, "own-tab");
    let selectors = {
        let id = crate::resource::PanePublicId::parse(pane.clone()).unwrap();
        let local = mux.with_state(|state| state.pane_by_public_id(&id).map(|pane| pane.id));
        mux.resource_selectors_for_pane(local).unwrap()
    };
    let mutation = WorkspaceMutation::daemon(
        "w6a-own-tab-receipt-000000000001".to_string(),
        "w6a-own-tab".to_string(),
    )
    .unwrap();
    let fields = Map::from_iter([("argv".to_string(), json!(AGENT))]);
    mux.receipted_surface_creation(ResourceOperation::PaneRun, vec![selectors], fields, &mutation)
        .unwrap();
    let selected = selected_tab(&mux, &pane);
    assert_ne!(selected, shell, "the person's own run-command must show its new tab");
}
