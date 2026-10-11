//! `close-reason-v1`: `close-tabs {reason: "session_end"}` closes like any
//! close-tabs (rows deleted, same events) but leaves no closed-history
//! record, so Reopen Closed never brings back the tabs a browser session
//! opened for itself.

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    // An undecodable request is a `bad request` on the wire (server/responses.rs).
    let command: Command =
        serde_json::from_value(request).map_err(|error| anyhow::anyhow!("bad request: {error}"))?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn closed_groups(mux: &Arc<Mux>) -> usize {
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":"closed",
                          "operation":"closed.list",
                          "params":{"machine":"current","session":"current"}});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["result"].as_array().unwrap().len()
}

/// A pane with a terminal and `count` frontend browser tabs.
fn browser_tabs(mux: &Arc<Mux>, count: usize) -> (PaneId, Vec<SurfaceId>) {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let tabs = (0..count)
        .map(|index| {
            let record = crate::workspace_registry::FrontendBrowserRecord {
                engine: "webkit".into(),
                url: format!("https://a.test/{index}"),
                title: None,
                favicon_url: None,
                profile_id: None,
                owner: None,
            };
            mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id
        })
        .collect();
    (pane, tabs)
}

fn pane_tabs(mux: &Arc<Mux>, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()).unwrap_or_default())
}

#[test]
fn session_end_close_leaves_no_closed_history() {
    let mux = Mux::new_for_test("close-reason", crate::SurfaceOptions::default());
    let (pane, tabs) = browser_tabs(&mux, 3);
    assert_eq!(closed_groups(&mux), 0);

    run(&mux, json!({"cmd":"close-tabs","surfaces":[tabs[0]]})).unwrap();
    assert_eq!(closed_groups(&mux), 1, "a plain close-tabs is recorded");

    let ended =
        run(&mux, json!({"cmd":"close-tabs","surfaces":[tabs[1]],"reason":"session_end"})).unwrap();
    assert_eq!(ended["closed"].as_array().map(Vec::len), Some(1), "{ended}");
    assert!(!pane_tabs(&mux, pane).contains(&tabs[1]), "the session-end close closes the tab");
    assert_eq!(closed_groups(&mux), 1, "a session-end close is not recorded");

    let refused =
        run(&mux, json!({"cmd":"close-tabs","surfaces":[tabs[2]],"reason":"other"})).unwrap_err();
    let refused = refused.to_string();
    assert!(refused.starts_with("bad request") && refused.contains("session_end"), "{refused}");
    assert!(pane_tabs(&mux, pane).contains(&tabs[2]), "a refused close closes nothing");
    mux.shutdown();
}

/// The reason is part of the request a key names.
#[test]
fn close_reason_is_in_the_idempotency_fingerprint() {
    let mux = Mux::new_for_test("close-reason-key", crate::SurfaceOptions::default());
    let (_, tabs) = browser_tabs(&mux, 1);
    let request = json!({"cmd":"close-tabs","surfaces":[tabs[0]],"reason":"session_end",
                         "origin":"reason-test","mutation_id":"close-1"});
    run(&mux, request.clone()).unwrap();
    assert_eq!(run(&mux, request.clone()).unwrap()["replayed"], true);
    let mut plain = request;
    plain.as_object_mut().unwrap().remove("reason");
    assert!(run(&mux, plain).is_err(), "the same key without the reason is another request");
    mux.shutdown();
}
