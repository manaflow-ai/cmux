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
fn cmux_next_set_workspace_metadata_distinguishes_absent_from_null() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&WORKSPACE_METADATA_CAPABILITY));
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let set = run_json_command(
        &mux,
        json!({
            "cmd":"set-workspace-metadata",
            "key": workspace.key,
            "color":"#336699",
            "icon":"hammer",
            "title":"Build",
        }),
    )
    .unwrap();
    assert_eq!(set["color"], "#336699");
    assert_eq!(set["changed"], true);
    let cleared = run_json_command(
        &mux,
        json!({"cmd":"set-workspace-metadata","key":workspace.key,"icon":null}),
    )
    .unwrap();
    assert!(cleared["icon"].is_null());
    assert_eq!(cleared["color"], "#336699");
    assert_eq!(cleared["title"], "Build");
    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    let entry = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["key"] == json!(workspace.key))
        .cloned()
        .unwrap();
    assert_eq!(entry["color"], "#336699");
    assert!(entry["icon"].is_null());
    assert_eq!(entry["title"], "Build");
    assert!(
        run_json_command(
            &mux,
            json!({"cmd":"set-workspace-metadata","key":workspace.key,"icon":"NOT/AN ICON"}),
        )
        .is_err()
    );
}

#[test]
fn cmux_next_set_workspace_metadata_pins_and_unpins_a_workspace() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&WORKSPACE_PIN_CAPABILITY));
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let entry = |mux: &Arc<Mux>| {
        let tree = run_json_command(mux, json!({"cmd":"list-workspaces"})).unwrap();
        tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["key"] == json!(workspace.key))
            .cloned()
            .unwrap()
    };
    assert_eq!(entry(&mux)["pinned"], false);
    let events = mux.subscribe();
    let pin = json!({
        "cmd":"set-workspace-metadata",
        "key": workspace.key,
        "pinned": true,
        "origin":"cmux-next",
        "mutation_id":"pin-1",
    });
    let pinned = run_json_command(&mux, pin.clone()).unwrap();
    assert_eq!(pinned["pinned"], true);
    assert_eq!(pinned["changed"], true);
    assert_eq!(pinned["replayed"], false);
    let delta = std::iter::from_fn(|| events.try_recv().ok())
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::WorkspaceChanged => {
                Some(delta)
            }
            _ => None,
        })
        .expect("workspace-changed delta");
    assert_eq!(delta.entity["pinned"], true);
    assert_eq!(entry(&mux)["pinned"], true);
    let replayed = run_json_command(&mux, pin).unwrap();
    assert_eq!(replayed["replayed"], true);
    assert_eq!(replayed["workspace_revision"], pinned["workspace_revision"]);
    // An absent `pinned` keeps the pin while other fields change.
    let titled = run_json_command(
        &mux,
        json!({"cmd":"set-workspace-metadata","key":workspace.key,"title":"Build"}),
    )
    .unwrap();
    assert_eq!(titled["pinned"], true);
    let unpinned = run_json_command(
        &mux,
        json!({"cmd":"set-workspace-metadata","key":workspace.key,"pinned":false}),
    )
    .unwrap();
    assert_eq!(unpinned["pinned"], false);
    assert_eq!(unpinned["title"], "Build");
    assert_eq!(entry(&mux)["pinned"], false);
}

#[test]
fn cmux_next_set_workspace_metadata_marks_a_workspace_unread() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&NOTIFICATION_MARK_UNREAD_CAPABILITY));
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let entry = |mux: &Arc<Mux>| {
        let tree = run_json_command(mux, json!({"cmd":"list-workspaces"})).unwrap();
        tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["key"] == json!(workspace.key))
            .cloned()
            .unwrap()
    };
    assert_eq!(entry(&mux)["marked_unread"], false);
    let mark = json!({
        "cmd":"set-workspace-metadata",
        "key": workspace.key,
        "marked_unread": true,
        "origin":"cmux-next",
        "mutation_id":"mark-unread-1",
    });
    let marked = run_json_command(&mux, mark.clone()).unwrap();
    assert_eq!(marked["marked_unread"], true);
    assert_eq!(marked["changed"], true);
    assert_eq!(entry(&mux)["marked_unread"], true);
    assert_eq!(run_json_command(&mux, mark).unwrap()["replayed"], true);
    // The mark is independent of the pin and of notifications.
    let pinned = run_json_command(
        &mux,
        json!({"cmd":"set-workspace-metadata","key":workspace.key,"pinned":true}),
    )
    .unwrap();
    assert_eq!(pinned["marked_unread"], true);
    assert_eq!(entry(&mux)["unread_count"], 0);
    let cleared = run_json_command(
        &mux,
        json!({"cmd":"set-workspace-metadata","key":workspace.key,"marked_unread":false}),
    )
    .unwrap();
    assert_eq!(cleared["marked_unread"], false);
    assert_eq!(cleared["pinned"], true);
    assert_eq!(entry(&mux)["marked_unread"], false);
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
fn cmux_next_frontend_browser_tab_commands_and_attach_refusal() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&FRONTEND_BROWSER_TABS_CAPABILITY));
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let created = run_json_command(
        &mux,
        json!({
            "cmd":"new-frontend-browser-tab",
            "pane": pane,
            "url":"https://cmux.com",
            "engine":"cef",
            "title":"cmux",
        }),
    )
    .unwrap();
    let surface = created["surface"].as_u64().unwrap();
    assert!(created["content_resource_id"].as_str().unwrap().starts_with("browser_"));
    let updated = run_json_command(
        &mux,
        json!({
            "cmd":"update-frontend-browser-tab",
            "surface": surface,
            "title":"cmux docs",
            "favicon_url":"https://cmux.com/icon.png",
        }),
    )
    .unwrap();
    assert_eq!(updated["changed"], true);
    assert_eq!(updated["url"], "https://cmux.com");
    let cleared = run_json_command(
        &mux,
        json!({"cmd":"update-frontend-browser-tab","surface":surface,"favicon_url":null}),
    )
    .unwrap();
    assert!(cleared["favicon_url"].is_null());
    let tree = run_json_command(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    let tabs = tree["workspaces"][0]["screens"][0]["panes"][0]["tabs"].as_array().unwrap();
    let browser = tabs.iter().find(|tab| tab["surface"] == json!(surface)).unwrap();
    assert_eq!(browser["browser_renderer"], "frontend");
    assert_eq!(browser["browser_engine"], "cef");
    assert_eq!(browser["title"], "cmux docs");
    let terminal_tab = tabs.iter().find(|tab| tab["surface"] == json!(terminal)).unwrap();
    assert!(terminal_tab["browser_renderer"].is_null());
    let attach = run_json_command(
        &mux,
        json!({"cmd":"attach-surface","surface":surface,"cols":80,"rows":24}),
    );
    assert!(attach.unwrap_err().to_string().contains("frontend-rendered"));
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

#[test]
fn cmux_next_terminal_creation_accepts_a_per_terminal_env() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&TERMINAL_ENV_CAPABILITY));
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let created = run_json_command(
        &mux,
        json!({
            "cmd":"new-tab",
            "pane":pane,
            "cwd":"/tmp",
            "env":{"PATH":"/opt/homebrew/bin:/usr/bin","LANG":"en_US.UTF-8"},
        }),
    )
    .unwrap();
    assert!(created["surface"].as_u64().is_some());
    let split = run_json_command(
        &mux,
        json!({"cmd":"split","pane":pane,"dir":"right","env":{"EDITOR":"vim"}}),
    )
    .unwrap();
    assert!(split["surface"].as_u64().is_some());
    for bad in [json!({"":"x"}), json!({"A=B":"x"}), json!({"A":"x\u{0}y"})] {
        assert!(run_json_command(&mux, json!({"cmd":"new-tab","pane":pane,"env":bad})).is_err());
    }
    let pairs = crate::mux::validate_terminal_env(
        &[("B".to_string(), "2".to_string()), ("A".to_string(), "1".to_string())]
            .into_iter()
            .collect(),
    )
    .unwrap();
    assert_eq!(pairs, vec![("A".into(), "1".into()), ("B".into(), "2".into())]);
}

#[test]
fn placement_commands_accept_a_caller_terminal_id_env_and_cwd() {
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&TERMINAL_PLACEMENT_ENV_CAPABILITY));
    let first = mux.new_workspace(None, Some((80, 24))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let commands = [
        ("new-tab", json!({})),
        ("split", json!({"dir":"right"})),
        ("new-pane", json!({})),
        ("new-pane-right", json!({"width":0.5})),
    ];
    for (index, (command, extra)) in commands.into_iter().enumerate() {
        let terminal_id = format!("{:012x}4000{:04x}{:012x}", 0, 0x8000, 0x100 + index);
        let mut request = json!({
            "cmd":command,
            "pane":pane,
            "cols":80,
            "rows":24,
            "cwd":"/tmp",
            "env":{"CMUX_SURFACE_ID":terminal_id},
            "terminal_id":terminal_id,
        });
        for (key, value) in extra.as_object().unwrap() {
            request[key] = value.clone();
        }
        let created = run_json_command(&mux, request.clone()).unwrap();
        assert_eq!(created["terminal_id"], terminal_id.as_str(), "{command}: {created}");
        assert!(created["surface"].as_u64().is_some(), "{command}: {created}");
        let resolved = mux.resolve_terminal(&terminal_id).unwrap().unwrap();
        assert_eq!(resolved.surface, created["surface"].as_u64(), "{command}");
        if command == "new-tab" {
            assert!(
                run_json_command(&mux, request).is_err(),
                "{command} reused an existing terminal id"
            );
            continue;
        }
        // `split-client-keys-v1`: a pane creation is keyed by its terminal id,
        // so the same request replays the first result and another request
        // with that id is refused.
        let retry = run_json_command(&mux, request.clone()).unwrap();
        assert_eq!(retry["surface"], created["surface"], "{command}: {retry}");
        assert_eq!(retry["replayed"], json!(true), "{command}: {retry}");
        request["cwd"] = json!("/");
        assert!(
            run_json_command(&mux, request).is_err(),
            "{command} reused an existing terminal id for another request"
        );
    }
    for bad in ["not-hex", "00000000000000008000000000000001"] {
        let error = run_json_command(&mux, json!({"cmd":"new-tab","pane":pane,"terminal_id":bad}))
            .unwrap_err();
        assert!(error.to_string().contains("terminal_id"), "{error}");
    }
}

#[cfg(unix)]
#[test]
fn idle_close_policy_reaps_only_unattached_terminals_past_their_deadline() {
    const IDLE: &str = "00000000000040008000000000000031";
    const IDLE_INCARNATION: &str = "10000000000040008000000000000031";
    const NEVER: &str = "00000000000040008000000000000032";
    const NEVER_INCARNATION: &str = "10000000000040008000000000000032";
    const HOUR: Duration = Duration::from_secs(60 * 60);
    let mux = test_mux();
    assert!(advertised_capabilities(false).contains(&TERMINAL_IDLE_CLOSE_CAPABILITY));
    let workspace = mux
        .create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000003101".into()), None)
        .unwrap();
    // Seeded terminals project as exited placeholders (dead surfaces), so
    // address them by stable terminal id; the surface form is covered by
    // the live-surface handler path.
    let idle = mux.seed_running_terminal_for_test(IDLE, IDLE_INCARNATION, &workspace.key).unwrap();
    mux.seed_running_terminal_for_test(NEVER, NEVER_INCARNATION, &workspace.key).unwrap();

    let set = Command::SetTerminalIdlePolicy {
        surface: None,
        terminal_id: Some(IDLE.into()),
        idle_close_seconds: Some(3_600),
    };
    let result = handle_command(&mux, mux.local_test_client(0), set, &test_writer()).unwrap();
    assert_eq!(result["terminal_id"], IDLE);
    assert_eq!(result["idle_close_seconds"], 3_600);
    // A stable terminal id works as well, and null means never close.
    for idle_close_seconds in [Some(60), None] {
        let set = Command::SetTerminalIdlePolicy {
            surface: None,
            terminal_id: Some(NEVER.into()),
            idle_close_seconds,
        };
        handle_command(&mux, mux.local_test_client(0), set, &test_writer()).unwrap();
    }
    assert_eq!(mux.terminal_idle_policy(IDLE).unwrap(), Some(3_600));
    assert_eq!(mux.terminal_idle_policy(NEVER).unwrap(), None);
    let ambiguous = Command::SetTerminalIdlePolicy {
        surface: Some(idle),
        terminal_id: Some(IDLE.into()),
        idle_close_seconds: Some(60),
    };
    assert!(handle_command(&mux, mux.local_test_client(0), ambiguous, &test_writer()).is_err());

    // An attached view keeps the terminal alive regardless of elapsed time.
    let start = Instant::now();
    let writer = test_writer();
    let viewer = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&attach_overflow_json(idle)).unwrap();
    mux.control_clients.attach_surface(viewer, idle, stream).unwrap();
    assert!(mux.reap_idle_terminals(start).is_empty());
    assert!(mux.reap_idle_terminals(start + 10 * HOUR).is_empty());

    // The clock starts when the last view detaches.
    mux.control_clients.remove(viewer);
    let detached = start + 11 * HOUR;
    assert!(mux.reap_idle_terminals(detached).is_empty());
    assert!(mux.reap_idle_terminals(detached + HOUR - Duration::from_secs(1)).is_empty());

    // A reattach between two ticks resets the clock.
    let writer = test_writer();
    let viewer = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&attach_overflow_json(idle)).unwrap();
    mux.control_clients.attach_surface(viewer, idle, stream).unwrap();
    mux.control_clients.remove(viewer);
    let reattached = detached + HOUR;
    assert!(mux.reap_idle_terminals(reattached).is_empty());
    assert!(mux.reap_idle_terminals(reattached + HOUR / 2).is_empty());

    assert_eq!(mux.reap_idle_terminals(reattached + HOUR), vec![IDLE.to_string()]);
    let closed = mux.resolve_terminal(IDLE).unwrap().unwrap().terminal.lifecycle;
    assert_eq!(closed, TerminalLifecycle::Tombstoned);
    assert!(mux.surface(idle).is_none());

    // The terminal whose policy was cleared is never reaped, and the
    // closed terminal's policy is pruned.
    assert!(mux.reap_idle_terminals(reattached + 1_000 * HOUR).is_empty());
    assert_eq!(mux.terminal_idle_policy(IDLE).unwrap(), None);
    let never = mux.resolve_terminal(NEVER).unwrap().unwrap().terminal.lifecycle;
    assert_eq!(never, TerminalLifecycle::Running);
    mux.close_terminal(NEVER, NEVER_INCARNATION).unwrap();
}

#[test]
fn client_info_is_sanitized_recallable_and_clamped_to_64_characters() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let events = mux.subscribe();

    handle_command(
        &mux,
        client,
        Command::SetClientInfo {
            name: Some("\u{1b}]0;evil\u{07}name".to_string()),
            kind: Some("web".to_string()),
            capabilities: None,
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &writer,
    )
    .unwrap();
    let data = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
    assert_eq!(data[0]["name"], " ]0;evil name");

    handle_command(
        &mux,
        client,
        Command::SetClientInfo {
            name: Some("n".repeat(80)),
            kind: None,
            capabilities: None,
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &writer,
    )
    .unwrap();
    handle_command(
        &mux,
        client,
        Command::SetClientInfo {
            name: None,
            kind: Some("tui".to_string()),
            capabilities: None,
            user_id: None,
            display_name: None,
            device_kind: None,
            device_name: None,
            device_id: None,
        },
        &writer,
    )
    .unwrap();

    let data = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
    let listed = &data[0];
    assert_eq!(listed["name"].as_str().unwrap().chars().count(), 64);
    assert_eq!(listed["kind"], "tui");
    assert_eq!(listed["self"], true);
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
            if id == client && kind == "web"
    ));
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
            if id == client && kind == "web"
    ));
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)),
        Ok(MuxEvent::ClientChanged { client: id, kind: Some(kind), .. })
            if id == client && kind == "tui"
    ));
}

#[test]
fn client_sizing_command_updates_list_clients() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream = writer.start_stream(&json!({"event": "test"})).unwrap();
    let stream_id = stream.id;
    mux.control_clients.attach_surface(client, surface.id, stream).unwrap();
    mux.control_clients.commit_surface(client, surface.id, stream_id, None).unwrap();
    handle_command(
        &mux,
        client,
        Command::ResizeSurface { surface: surface.id, cols: 80, rows: 24 },
        &writer,
    )
    .unwrap();

    // Attaching with a viewport joins shared sizing and takes the grid.
    let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
    assert_eq!(listed[0]["sizes"][0]["size_participating"], true);

    handle_command(
        &mux,
        client,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(client),
            enabled: true,
            exclusive: false,
        },
        &writer,
    )
    .unwrap();
    let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
    assert_eq!(listed[0]["sizes"][0]["size_participating"], true);

    handle_command(
        &mux,
        client,
        Command::SetClientSizing {
            surface: surface.id,
            client: Some(client),
            enabled: false,
            exclusive: false,
        },
        &writer,
    )
    .unwrap();
    let listed = handle_command(&mux, client, Command::ListClients, &writer).unwrap();
    assert_eq!(listed[0]["sizes"][0]["size_participating"], false);
}
