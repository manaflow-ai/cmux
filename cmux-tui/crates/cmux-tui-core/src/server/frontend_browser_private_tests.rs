//! `private-tabs-v1` on the wire the app sends: `new-frontend-browser-tab
//! {private: true}` opens a private tab in a normal workspace, between normal
//! tabs (Leo, 2026-11-18: "what if in [a browser] you could simply have an
//! incognito tab?"). The raw tree and the v2 tab read mark only that tab, and
//! the workspace stays normal.

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// The tabs of the only pane of the raw tree's workspace `index`, in strip order.
fn raw_tabs(mux: &Arc<Mux>) -> Vec<Value> {
    let tree = run(mux, json!({"cmd":"list-workspaces"})).unwrap();
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().unwrap().iter())
        .flat_map(|screen| screen["panes"].as_array().unwrap().iter())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .cloned()
        .collect()
}

#[test]
fn a_private_tab_opens_between_normal_tabs_of_a_normal_workspace() {
    let mux = Mux::new_for_test("private-tab-between", crate::SurfaceOptions::default());
    let identify = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == crate::state::private_tabs::PRIVATE_TABS_CAPABILITY),
        "{identify}"
    );
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let last = run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"https://example.com/","engine":"cef"}),
    )
    .unwrap();
    let private = run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"about:blank","engine":"cef",
               "after":first,"private":true}),
    )
    .unwrap();
    assert_eq!(private["private"], true);

    let tabs = raw_tabs(&mux);
    let surfaces = tabs.iter().map(|tab| tab["surface"].clone()).collect::<Vec<_>>();
    assert_eq!(surfaces, vec![json!(first), private["surface"].clone(), last["surface"].clone()]);
    let flags = tabs.iter().map(|tab| tab["private"] == true).collect::<Vec<_>>();
    assert_eq!(flags, vec![false, true, false], "{tabs:?}");

    let listed = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let extras = listed["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tab| (tab["id"].clone(), tab["extra"]["private"] == true))
        .collect::<Vec<_>>();
    for (id, flagged) in extras {
        assert_eq!(flagged, id == private["tab_resource_id"], "{id}");
    }
    let workspaces = listed["workspaces"].as_array().unwrap();
    assert!(workspaces.iter().all(|workspace| workspace["extra"]["ephemeral"] != true));
    mux.shutdown();
}
