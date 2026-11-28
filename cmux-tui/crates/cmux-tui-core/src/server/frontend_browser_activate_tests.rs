//! `new-frontend-browser-tab {activate:false}` (`frontend-browser-activate-v1`):
//! a tab an automation opens (a browser session's `tabs.open` through the
//! app) joins the pane without becoming its active tab, so every client that
//! reads `active_tab` (the TUI, iOS, the app's default tab) keeps showing the
//! person's tab. Without the field a new tab is active, as before.

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// The pane's `active_tab` and tab count in the daemon's tree.
fn pane_state(mux: &Arc<Mux>, pane: PaneId) -> (u64, usize) {
    let tree = run(mux, json!({"cmd":"list-workspaces"})).unwrap();
    let pane_json = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().unwrap().iter())
        .flat_map(|screen| screen["panes"].as_array().unwrap().iter())
        .find(|candidate| candidate["id"] == json!(pane))
        .cloned()
        .expect("the pane is in the tree");
    (pane_json["active_tab"].as_u64().unwrap(), pane_json["tabs"].as_array().unwrap().len())
}

fn pane_with_one_terminal(label: &str) -> (Arc<Mux>, PaneId) {
    let mux =
        Mux::new_for_test(format!("frontend-activate-{label}"), crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    (mux, pane)
}

#[test]
fn a_background_frontend_tab_leaves_the_active_tab() {
    let (mux, pane) = pane_with_one_terminal("background");
    assert_eq!(pane_state(&mux, pane), (0, 1));
    run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"about:blank","engine":"webkit",
               "activate":false}),
    )
    .unwrap();
    assert_eq!(pane_state(&mux, pane), (0, 2), "the person's tab stays active");
    run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"about:blank","engine":"webkit",
               "activate":false,"idempotency_key":"agent-open-1"}),
    )
    .unwrap();
    assert_eq!(pane_state(&mux, pane), (0, 3), "a keyed background tab stays in the background");
}

#[test]
fn a_frontend_tab_without_activate_becomes_active_as_before() {
    let (mux, pane) = pane_with_one_terminal("default");
    run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"about:blank","engine":"webkit"}),
    )
    .unwrap();
    assert_eq!(pane_state(&mux, pane), (1, 2));
}

#[test]
fn identify_advertises_frontend_browser_activate() {
    let mux = Mux::new_for_test("frontend-activate-identify", crate::SurfaceOptions::default());
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "frontend-browser-activate-v1"), "{identity}");
}
