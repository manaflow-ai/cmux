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

/// A workspace whose first terminal never started (an import, a new workspace in a folder that
/// is gone) is closed again by the app that created it, with `reason: "session_end"`: nothing
/// is recorded, so Recently Closed never lists it (cx-avtwr). Without the reason, a workspace
/// is recorded even with no tab (one the CLI made).
#[test]
fn a_session_end_workspace_close_leaves_no_closed_history() {
    let mux = Mux::new_for_test("close-reason-workspace", crate::SurfaceOptions::default());
    browser_tabs(&mux, 1);
    let failed = "6f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7";
    run(&mux, json!({"cmd":"create-workspace","name":"nightly-focus-20","key":failed})).unwrap();
    let discard = json!({"cmd":"close-workspace","key":failed,"end_terminals":true,
                         "reason":"session_end"});
    run(&mux, discard).unwrap();
    assert_eq!(closed_groups(&mux), 0, "a session-end workspace close is not recorded");

    let empty = "0a1b2c3d-4e5f-4a60-9b71-c2d3e4f5a6b7";
    run(&mux, json!({"cmd":"create-workspace","name":"spare","key":empty})).unwrap();
    run(&mux, json!({"cmd":"close-workspace","key":empty,"end_terminals":true})).unwrap();
    assert_eq!(closed_groups(&mux), 1, "a plain workspace close is recorded");
    mux.shutdown();
}

/// The ids of the closed groups, newest first.
fn closed_ids(mux: &Arc<Mux>) -> Vec<Value> {
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":"closed",
                          "operation":"closed.list",
                          "params":{"machine":"current","session":"current"}});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["result"].as_array().unwrap().iter().map(|item| item["id"].clone()).collect()
}

/// The raw batch closes answer `closed_ids`: `close-workspace` with
/// `end_terminals` names its group (a replay names it again); `close-tabs` of
/// a workspace's last tab names the one group the emptied workspace joined;
/// a session-end close names none.
#[test]
fn batch_closes_name_the_closed_groups_they_stored() {
    let mux = Mux::new_for_test("closed-ids-batch", crate::SurfaceOptions::default());
    let (_, kept) = browser_tabs(&mux, 2);
    let key = "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d";
    run(&mux, json!({"cmd":"create-workspace","name":"same","key":key})).unwrap();
    let close = json!({"cmd":"close-workspace","key":key,"end_terminals":true,
                       "report_closed_ids":true,"origin":"closed-ids","mutation_id":"close-1"});
    let closed = run(&mux, close.clone()).unwrap();
    assert_eq!(closed["closed_ids"], json!([closed_ids(&mux)[0]]), "{closed}");
    let replay = run(&mux, close).unwrap();
    assert_eq!(replay["replayed"], true, "{replay}");
    assert_eq!(replay["closed_ids"], closed["closed_ids"]);

    let (pane, _) = browser_tabs(&mux, 0);
    let last = pane_tabs(&mux, pane);
    assert_eq!(last.len(), 1);
    let cascade =
        run(&mux, json!({"cmd":"close-tabs","surfaces":last,"end_terminals":true})).unwrap();
    let listed = closed_ids(&mux);
    assert_eq!(listed.len(), 2, "{listed:?}");
    assert_eq!(cascade["closed_ids"], json!([listed[0]]), "{cascade}");
    assert_ne!(cascade["closed_ids"], closed["closed_ids"]);

    let ended =
        run(&mux, json!({"cmd":"close-tabs","surfaces":[kept[0]],"reason":"session_end"})).unwrap();
    assert_eq!(ended["closed_ids"], json!([]), "{ended}");
    mux.shutdown();
}
