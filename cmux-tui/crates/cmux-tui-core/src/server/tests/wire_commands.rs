//! cmux-next workspace, metadata, tab drag and close-tabs commands over the wire, and terminal idle close.

use super::*;

#[test]
fn cmux_next_workspace_group_commands_round_trip_over_the_wire() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&WORKSPACE_GROUPS_CAPABILITY));
    let first = mux.create_empty_workspace(None, None, None).unwrap();
    let second = mux.create_empty_workspace(None, None, None).unwrap();
    let created = run_json_command(
        &mux,
        json!({"cmd":"create-workspace-group","name":"Agents","color":"slate-2"}),
    )
    .unwrap();
    let group = created["group"]["id"].as_str().unwrap().to_string();
    assert!(group.starts_with("grp_"));
    assert_eq!(created["group"]["index"], 0);
    assert_eq!(created["changed"], true);
    let moved = run_json_command(
        &mux,
        json!({
            "cmd":"move-workspace-to-group",
            "key": second.key,
            "group": group,
            "index": 0,
            "origin":"wire-test",
            "mutation_id":"group-1",
        }),
    )
    .unwrap();
    assert_eq!(moved["group"], json!(group));
    assert_eq!(moved["replayed"], false);
    // Absent color leaves it unchanged; collapsed flips.
    let updated = run_json_command(
        &mux,
        json!({"cmd":"update-workspace-group","group":group,"collapsed":true}),
    )
    .unwrap();
    assert_eq!(updated["group"]["color"], "slate-2");
    assert_eq!(updated["group"]["collapsed"], true);
    // `color: null` clears it.
    let cleared =
        run_json_command(&mux, json!({"cmd":"update-workspace-group","group":group,"color":null}))
            .unwrap();
    assert!(cleared["group"]["color"].is_null());
    assert!(
        run_json_command(
            &mux,
            json!({"cmd":"create-workspace-group","name":"Bad","color":"not a color"}),
        )
        .is_err()
    );
    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    assert_eq!(tree["groups"][0]["id"], json!(group));
    assert_eq!(tree["groups"][0]["collapsed"], true);
    let by_key = |key: &str| {
        tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|workspace| workspace["key"] == json!(key))
            .cloned()
            .unwrap()
    };
    assert_eq!(by_key(&second.key)["group"], json!(group));
    assert!(by_key(&first.key)["group"].is_null());
    let listed = run_json_command(&mux, json!({"cmd":"list-workspace-groups"})).unwrap();
    assert_eq!(listed["groups"].as_array().unwrap().len(), 1);
    let deleted =
        run_json_command(&mux, json!({"cmd":"delete-workspace-group","group":group})).unwrap();
    assert_eq!(deleted["ungrouped_keys"], json!([second.key]));
}

#[test]
fn cmux_next_set_tab_pinned_reports_pinned_first_order_over_the_wire() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&TAB_METADATA_CAPABILITY));
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let second = mux.new_tab(Some(pane), None, None).unwrap().id;
    let pinned =
        run_json_command(&mux, json!({"cmd":"set-tab-pinned","surface":second,"pinned":true}))
            .unwrap();
    assert_eq!(pinned["index"], 0);
    assert_eq!(pinned["changed"], true);
    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    let tabs = tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"].as_array().unwrap();
    assert_eq!(tabs[0]["surface"], second);
    assert_eq!(tabs[0]["pinned"], true);
    assert_eq!(tabs[1]["pinned"], false);
    assert!(tabs[1].get("cwd").is_some());
    assert!(tabs[1].get("git_branch").is_some());
    // move-tab clamps an unpinned tab behind the pinned run.
    run_json_command(&mux, json!({"cmd":"move-tab","surface":first,"pane":pane,"index":0}))
        .unwrap();
    assert_eq!(mux.with_state(|state| state.panes[&pane].tabs.clone()), vec![second, first]);
    assert!(
        run_json_command(&mux, json!({"cmd":"set-tab-pinned","surface":999999,"pinned":true}))
            .is_err()
    );
}

#[test]
fn cmux_next_tab_drag_commands_over_the_wire() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&TAB_DRAG_CAPABILITY));
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let second = mux.new_tab(Some(pane), None, None).unwrap().id;
    let third = mux.new_tab(Some(pane), None, None).unwrap().id;
    let split = run_json_command(
        &mux,
        json!({
            "cmd":"move-tab-to-split",
            "surface":second,
            "pane":pane,
            "edge":"right",
            "transaction":"tx-split",
        }),
    )
    .unwrap();
    assert_eq!(split["undoable"], true);
    let split_pane = split["pane"].as_u64().unwrap();
    assert_ne!(split_pane, pane);
    assert!(
        run_json_command(
            &mux,
            json!({"cmd":"move-tab-to-split","surface":third,"pane":pane,"edge":"middle"}),
        )
        .is_err()
    );
    let screen = mux
        .with_state(|state| state.screen_of(pane).map(|(w, s)| state.workspaces[w].screens[s].id))
        .unwrap();
    let column =
        run_json_command(&mux, json!({"cmd":"move-tab-to-column","surface":third,"screen":screen}))
            .unwrap();
    assert_eq!(column["screen"], screen);
    let moved = run_json_command(
        &mux,
        json!({
            "cmd":"move-tab",
            "surface":third,
            "pane":split_pane,
            "index":0,
            "transaction":"tx-move",
        }),
    )
    .unwrap();
    assert_eq!(moved["moved"], true);
    let created = run_json_command(
        &mux,
        json!({"cmd":"move-tab-to-new-workspace","surface":third,"name":"vim","transaction":"tx-new"}),
    )
    .unwrap();
    assert!(advertised_capabilities(false).contains(&TAB_WORKSPACE_NAME_CAPABILITY));
    let named = created["workspace"].as_u64();
    let name = mux.with_state(|state| state.workspace_by_id(named?).map(|w| w.name.clone()));
    assert_eq!(name.as_deref(), Some("vim"));
    assert!(created["workspace"].as_u64().is_some());
    assert!(created["key"].as_str().is_some());
    assert!(
        run_json_command(
            &mux,
            json!({"cmd":"move-tab","surface":first,"pane":split_pane,"index":0,"transaction":""}),
        )
        .is_err()
    );
}

#[test]
fn cmux_next_tab_group_commands_over_the_wire() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&TAB_GROUPS_CAPABILITY));
    assert!(advertised_capabilities(false).contains(&SAVED_TAB_GROUPS_CAPABILITY));
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let second = mux.new_tab(Some(pane), None, None).unwrap().id;
    let created = run_json_command(
        &mux,
        json!({
            "cmd":"create-tab-group",
            "surfaces":[first, second],
            "name":"Pair",
            "color":"purple",
            "transaction":"tx-group",
        }),
    )
    .unwrap();
    let group = created["group"]["id"].as_str().unwrap().to_string();
    assert_eq!(created["surfaces"], json!([first, second]));
    let listed = run_json_command(&mux, json!({"cmd":"list-tab-groups"})).unwrap();
    assert_eq!(listed["groups"][0]["id"], json!(group));
    assert_eq!(listed["groups"][0]["pane"], pane);
    run_json_command(&mux, json!({"cmd":"update-tab-group","group":group,"collapsed":true}))
        .unwrap();
    let saved = run_json_command(&mux, json!({"cmd":"save-tab-group","group":group})).unwrap();
    assert!(saved["saved"].as_str().unwrap().starts_with("saved_"));
    let saved_list = run_json_command(&mux, json!({"cmd":"list-saved-tab-groups"})).unwrap();
    assert_eq!(saved_list["saved_groups"][0]["name"], "Pair");
    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    let pane_json = &tree["workspaces"][0]["screens"][0]["panes"][0];
    assert_eq!(pane_json["tab_groups"][0]["collapsed"], true);
    assert_eq!(pane_json["tabs"][0]["group"], json!(group));
    let ungrouped =
        run_json_command(&mux, json!({"cmd":"ungroup-tab-group","group":group})).unwrap();
    assert_eq!(ungrouped["surfaces"], json!([first, second]));
    assert!(run_json_command(&mux, json!({"cmd":"close-tab-group","group":group})).is_err());
}

#[test]
fn cmux_next_screen_commands_over_the_wire() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&SCREEN_METADATA_CAPABILITY));
    assert!(advertised_capabilities(false).contains(&SCREEN_GROUPS_CAPABILITY));
    mux.new_workspace(None, None).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    let first = mux.with_state(|state| state.workspaces[0].screens[0].id);
    let created = run_json_command(
        &mux,
        json!({"cmd":"new-screen","workspace":workspace,"screen_name":"logs","color":"green",
               "icon":"🚀","index":0,"name":"tail"}),
    )
    .unwrap();
    let screen = created["screen"].as_u64().unwrap();
    assert!(created["surface"].is_u64());
    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    let screens = &tree["workspaces"][0]["screens"];
    assert_eq!(screens[0]["id"], screen);
    assert_eq!(screens[0]["name"], "logs");
    assert_eq!(screens[0]["color"], "green");
    assert_eq!(screens[0]["icon"], "🚀");
    assert_eq!(screens[0]["pinned"], false);
    assert_eq!(screens[1]["group"], Value::Null);
    assert_eq!(tree["workspaces"][0]["screen_groups"], json!([]));

    let meta = run_json_command(
        &mux,
        json!({"cmd":"set-screen-metadata","screen":screen,"color":null,"icon":"server.rack"}),
    )
    .unwrap();
    assert_eq!(meta, json!({"screen":screen,"color":null,"icon":"server.rack","changed":true}));
    let pinned =
        run_json_command(&mux, json!({"cmd":"set-screen-pinned","screen":first,"pinned":true}))
            .unwrap();
    assert_eq!(pinned["index"], 0);
    let moved =
        run_json_command(&mux, json!({"cmd":"move-screen","screen":screen,"index":0})).unwrap();
    // Pinned screens stay first.
    assert_eq!(moved["index"], 1);

    let grouped = run_json_command(
        &mux,
        json!({"cmd":"create-screen-group","screens":[screen],"name":"Build","color":"orange"}),
    )
    .unwrap();
    let group = grouped["group"]["id"].as_str().unwrap().to_string();
    assert!(group.starts_with("sgrp_"));
    assert_eq!(grouped["screens"], json!([screen]));
    run_json_command(&mux, json!({"cmd":"update-screen-group","group":group,"collapsed":true}))
        .unwrap();
    let saved = run_json_command(&mux, json!({"cmd":"save-screen-group","group":group})).unwrap();
    assert!(saved["saved"].as_str().unwrap().starts_with("ssaved_"));
    let listed = run_json_command(&mux, json!({"cmd":"list-saved-screen-groups"})).unwrap();
    assert_eq!(listed["groups"][0]["name"], "Build");
    assert_eq!(listed["groups"][0]["open_group"], json!(group));
    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    assert_eq!(tree["workspaces"][0]["screen_groups"][0]["collapsed"], true);
    assert_eq!(tree["workspaces"][0]["screen_groups"][0]["screens"], json!([screen]));
    assert_eq!(tree["workspaces"][0]["screens"][1]["group"], json!(group));
    let ungrouped =
        run_json_command(&mux, json!({"cmd":"ungroup-screen-group","group":group})).unwrap();
    assert_eq!(ungrouped["screens"], json!([screen]));
    assert!(run_json_command(&mux, json!({"cmd":"close-screen-group","group":group})).is_err());
    let moved =
        run_json_command(&mux, json!({"cmd":"move-screen","screen":screen,"new_workspace":true}))
            .unwrap();
    assert_ne!(moved["workspace"], workspace);
    assert!(moved["key"].is_string());
}

#[test]
fn cmux_next_close_tabs_and_end_terminals_over_the_wire() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&BATCH_CLOSE_CAPABILITY));
    assert!(advertised_capabilities(false).contains(&TERMINAL_RESOURCES_CAPABILITY));
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let second = mux.new_tab(Some(pane), None, None).unwrap().id;
    let third = mux.new_tab(Some(pane), None, None).unwrap().id;
    assert!(run_json_command(&mux, json!({"cmd":"close-tabs","surfaces":[]})).is_err());
    assert!(
        run_json_command(&mux, json!({"cmd":"close-tabs","surfaces":[first, 999_999]})).is_err()
    );
    assert!(
        run_json_command(
            &mux,
            json!({"cmd":"close-tabs","surfaces":[first],"expected_revision":1}),
        )
        .is_err()
    );
    assert_eq!(mux.with_state(|state| state.panes[&pane].tabs.len()), 3);
    let closed = run_json_command(
        &mux,
        json!({
            "cmd":"close-tabs",
            "surfaces":[first, second],
            "end_terminals":true,
            "transaction":"tx-close",
            "origin":"cmux-next",
            "mutation_id":"close-two",
        }),
    )
    .unwrap();
    assert_eq!(closed["closed"], json!([first, second]));
    assert_eq!(closed["transaction"], "tx-close");
    assert_eq!(closed["replayed"], false);
    assert_eq!(mux.with_state(|state| state.panes[&pane].tabs.clone()), vec![third]);
    let replayed = run_json_command(
        &mux,
        json!({
            "cmd":"close-tabs",
            "surfaces":[first, second],
            "end_terminals":true,
            "origin":"cmux-next",
            "mutation_id":"close-two",
        }),
    )
    .unwrap();
    assert_eq!(replayed["replayed"], true);
    assert_eq!(replayed["closed"], json!([first, second]));
    let group =
        run_json_command(&mux, json!({"cmd":"create-tab-group","surfaces":[third],"name":"Last"}))
            .unwrap()["group"]["id"]
            .as_str()
            .unwrap()
            .to_string();
    let group_closed =
        run_json_command(&mux, json!({"cmd":"close-tab-group","group":group,"end_terminals":true}))
            .unwrap();
    assert_eq!(group_closed["closed"], json!([third]));
    assert!(group_closed["terminals"].is_array());
    let listed = run_json_command(&mux, json!({"cmd":"list-tab-groups"})).unwrap();
    assert_eq!(listed["groups"], json!([]));
}
