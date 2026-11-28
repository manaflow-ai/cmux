//! Screen and tab group icons on the raw wire (`screen-group-icon-v1`,
//! `tab-group-icon-v1`): `update-screen-group` and `update-tab-group` take
//! `icon` (null clears), the tree and the saved screen groups carry it, and
//! a saved screen group reopens with it.

use super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn group_icon_mux(name: &str) -> Arc<Mux> {
    Mux::new_for_test(name, crate::SurfaceOptions::default())
}

/// `identify` advertises both capabilities.
#[test]
fn identify_advertises_screen_and_tab_group_icons() {
    let mux = group_icon_mux("group-icon-identify");
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    for capability in ["screen-group-icon-v1", "tab-group-icon-v1"] {
        assert!(capabilities.iter().any(|value| value == capability), "{capability}");
    }
    mux.shutdown();
}

/// A raw screen group update sets and clears the icon; the tree shows it,
/// a saved screen group keeps it, and reopening the saved group restores it.
#[test]
fn a_screen_group_icon_sets_on_the_raw_wire_and_reopens_from_its_saved_group() {
    let mux = group_icon_mux("group-icon-raw-screens");
    mux.new_workspace(None, None).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    for _ in 0..2 {
        mux.new_screen(Some(workspace), None).unwrap();
    }
    let screens = mux.with_state(|state| {
        let index = state.workspace_index(workspace).unwrap();
        state.workspaces[index].screens.iter().map(|screen| screen.id).collect::<Vec<_>>()
    });
    let created = run(
        &mux,
        json!({"cmd":"create-screen-group","screens":[screens[1], screens[2]],"name":"Agents"}),
    )
    .unwrap();
    let group = created["group"]["id"].as_str().unwrap().to_string();
    assert!(created["group"]["icon"].is_null(), "{created}");

    let updated =
        run(&mux, json!({"cmd":"update-screen-group","group":group,"icon":"🚀"})).unwrap();
    assert_eq!(updated["group"]["icon"], "🚀");
    assert_eq!(updated["group"]["name"], "Agents");
    let cleared =
        run(&mux, json!({"cmd":"update-screen-group","group":group,"icon":null})).unwrap();
    assert!(cleared["group"]["icon"].is_null(), "{cleared}");
    let symbol =
        run(&mux, json!({"cmd":"update-screen-group","group":group,"icon":"folder.fill"})).unwrap();
    assert_eq!(symbol["group"]["icon"], "folder.fill");
    let refused =
        run(&mux, json!({"cmd":"update-screen-group","group":group,"icon":"Not An Icon"}));
    assert!(refused.is_err(), "a bad icon is refused");

    let decorations = mux.tree_decorations();
    let tree = mux.with_state(|state| workspaces_json(state, &decorations));
    let runs = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screen_groups"].as_array().cloned().unwrap_or_default())
        .collect::<Vec<_>>();
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0]["icon"], "folder.fill");

    let saved = run(&mux, json!({"cmd":"save-screen-group","group":group})).unwrap()["saved"]
        .as_str()
        .unwrap()
        .to_string();
    let listed = run(&mux, json!({"cmd":"list-saved-screen-groups"})).unwrap();
    assert_eq!(listed["groups"][0]["id"], saved.as_str());
    assert_eq!(listed["groups"][0]["icon"], "folder.fill");

    run(&mux, json!({"cmd":"ungroup-screen-group","group":group})).unwrap();
    let reopened =
        run(&mux, json!({"cmd":"reopen-saved-screen-group","saved":saved,"workspace":workspace}))
            .unwrap();
    assert_eq!(reopened["group"]["icon"], "folder.fill", "{reopened}");
    assert_eq!(reopened["group"]["saved_id"], saved.as_str());
    mux.shutdown();
}

/// A raw tab group update sets and clears the icon, and the pane's tab
/// group runs carry it.
#[test]
fn a_tab_group_icon_sets_and_clears_on_the_raw_wire() {
    let mux = group_icon_mux("group-icon-raw-tabs");
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let second = mux.new_tab(Some(pane), None, None).unwrap().id;
    let created =
        run(&mux, json!({"cmd":"create-tab-group","surfaces":[first, second],"name":"Build"}))
            .unwrap();
    let group = created["group"]["id"].as_str().unwrap().to_string();
    assert!(created["group"]["icon"].is_null(), "{created}");

    let updated =
        run(&mux, json!({"cmd":"update-tab-group","group":group,"icon":"hammer.fill"})).unwrap();
    assert_eq!(updated["group"]["icon"], "hammer.fill");
    assert_eq!(updated["group"]["name"], "Build");
    let presentation = mux.presentation_snapshot();
    let runs = mux.with_state(|state| crate::mux::pane_tab_groups(state, &presentation, pane));
    assert_eq!(pane_tab_group_json(&runs[0], Some(pane))["icon"], "hammer.fill");

    let cleared = run(&mux, json!({"cmd":"update-tab-group","group":group,"icon":null})).unwrap();
    assert!(cleared["group"]["icon"].is_null(), "{cleared}");
    let kept = run(&mux, json!({"cmd":"update-tab-group","group":group,"name":"CI"})).unwrap();
    assert!(kept["group"]["icon"].is_null(), "an update without icon keeps it cleared");
    mux.shutdown();
}
