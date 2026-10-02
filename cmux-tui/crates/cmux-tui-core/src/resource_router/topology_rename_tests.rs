use super::*;

#[test]
fn cloud_rename_authority_preserves_existing_tab_wire_contract() {
    let mux = mux();
    let created = terminal_workspace(&mux, "rename-wire-contract");
    let tab = created["value"]["tab_id"].as_str().unwrap();
    let before = mux.resource_event_epoch();
    let renamed = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabRename,
            selectors(None, None, None, Some(tab)),
            json!({"name":"Logs / 東京"}),
            Some("rename-wire-contract-name"),
        ),
    )
    .unwrap();
    // Released SDKs reject unknown tab siblings but preserve the extension map.
    let legacy_schema = json!({
        "type":"object", "additionalProperties":false,
        "required":["id", "pane_id", "name", "index", "focused", "content_kind", "content_id"],
        "properties":{
            "id":{}, "pane_id":{}, "name":{}, "index":{}, "focused":{},
            "content_kind":{}, "content_id":{}, "extra":{"type":"object"}
        }
    });
    let validator = jsonschema::validator_for(&legacy_schema).unwrap();
    let snapshot = public_session_snapshot(&mux).unwrap();
    let observed =
        snapshot["tabs"].as_array().unwrap().iter().find(|value| value["id"] == tab).unwrap();
    let events = mux.resource_events_after(before).unwrap();
    let changes = events.batches.last().unwrap().changes.as_array().unwrap();
    let delta = changes.iter().find(|value| value["id"] == tab).unwrap();
    let journaled = &delta["value"];
    for value in [&renamed["value"], observed, journaled] {
        assert!(validator.is_valid(value), "tab response broke a released SDK: {value}");
        assert_eq!(value["name"], "Logs / 東京");
        assert_eq!(value["extra"]["name_source"], "user");
        assert_eq!(value["extra"]["name_revision"], renamed["revision"]);
    }
}

#[test]
fn cloud_rename_authority_rejects_unversioned_callback() {
    let mux = mux();
    let created = terminal_workspace(&mux, "unversioned-name");
    let tab = created["value"]["tab_id"].as_str().unwrap();
    let before = public_session_snapshot(&mux).unwrap();
    let error = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabRename,
            selectors(None, None, None, Some(tab)),
            json!({"name":"auto", "source":"auto"}),
            Some("unversioned-auto"),
        ),
    )
    .unwrap_err();
    assert_eq!(error.code, "validation.invalid");
    let after = public_session_snapshot(&mux).unwrap();
    assert_eq!(after["tabs"], before["tabs"]);
    assert_eq!(after["cursor"], before["cursor"]);
}

#[test]
fn cloud_rename_authority_user_name_rejects_automatic_callback() {
    let mux = mux();
    let created = terminal_workspace(&mux, "rename-authority-user");
    let tab = created["value"]["tab_id"].as_str().unwrap();
    let user_name = "API – 東京 🚀 / terminal: 1";
    let user = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabRename,
            selectors(None, None, None, Some(tab)),
            json!({"name":user_name}),
            Some("rename-authority-user-name"),
        ),
    )
    .unwrap();
    let snapshot = public_session_snapshot(&mux).unwrap();
    let automatic = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabRename,
            selectors(None, None, None, Some(tab)),
            json!({
                "name":"Calculate 2+2", "source":"auto",
                "expected_generation":snapshot["cursor"]["generation"],
                "expected_name_revision":user["revision"],
            }),
            Some("rename-authority-late-auto"),
        ),
    );
    assert!(automatic.is_err(), "an automatic callback cannot replace an explicit name");
    let latest = public_session_snapshot(&mux).unwrap();
    assert_eq!(
        latest["tabs"].as_array().unwrap().iter().find(|value| value["id"] == tab).unwrap()["name"],
        user_name
    );
}

#[test]
fn cloud_rename_authority_rejects_older_automatic_result() {
    let mux = mux();
    let created = terminal_workspace(&mux, "rename-authority-auto");
    let tab = created["value"]["tab_id"].as_str().unwrap();
    let cleared = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabRename,
            selectors(None, None, None, Some(tab)),
            json!({"name":null}),
            Some("rename-authority-clear"),
        ),
    )
    .unwrap();
    let snapshot = public_session_snapshot(&mux).unwrap();
    let fields = |name| {
        json!({
            "name":name, "source":"auto",
            "expected_generation":snapshot["cursor"]["generation"],
            "expected_name_revision":cleared["revision"],
        })
    };
    let first = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabRename,
            selectors(None, None, None, Some(tab)),
            fields("Calculate 2+2"),
            Some("rename-authority-new-auto"),
        ),
    )
    .unwrap();
    assert_eq!(first["value"]["name"], "Calculate 2+2");
    assert_eq!(first["value"]["extra"]["name_source"], "auto");
    let delayed = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabRename,
            selectors(None, None, None, Some(tab)),
            fields("Old conversation"),
            Some("rename-authority-old-auto"),
        ),
    );
    assert!(delayed.is_err(), "one captured name revision accepts at most one rename");
    let latest = public_session_snapshot(&mux).unwrap();
    assert_eq!(
        latest["tabs"].as_array().unwrap().iter().find(|value| value["id"] == tab).unwrap()["name"],
        "Calculate 2+2"
    );
}

#[test]
fn pure_topology_mutations_preserve_exact_public_snapshots() {
    let mux = mux();
    let created = terminal_workspace(&mux, "pure-topology");
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let screen = created["value"]["screen_id"].as_str().unwrap().to_string();
    let first_pane = created["value"]["pane_id"].as_str().unwrap().to_string();
    let first_tab = created["value"]["tab_id"].as_str().unwrap().to_string();

    let second_tab = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabCreateTerminal,
            selectors(None, None, Some(&first_pane), None),
            json!({"name":"second tab"}),
            Some("pure-second-tab"),
        ),
    )
    .unwrap();
    let second_tab_id = second_tab["value"]["tab_id"].as_str().unwrap().to_string();
    let renamed_tab = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabRename,
            selectors(None, None, None, Some(&first_tab)),
            json!({"name":"renamed tab"}),
            Some("pure-rename-tab"),
        ),
    )
    .unwrap();
    assert_eq!(renamed_tab["value"]["name"], "renamed tab");
    let focused_tab = dispatch(
        &mux,
        parsed(
            ResourceOperation::TabFocus,
            selectors(None, None, None, Some(&first_tab)),
            json!({}),
            Some("pure-focus-tab"),
        ),
    )
    .unwrap();
    assert_eq!(focused_tab["value"]["focused"], true);
    assert_eq!(
        dispatch(
            &mux,
            parsed(
                ResourceOperation::TabGet,
                selectors(None, None, None, Some(&second_tab_id)),
                json!({}),
                None,
            ),
        )
        .unwrap()["focused"],
        false
    );

    let split = dispatch(
        &mux,
        parsed(
            ResourceOperation::PaneSplit,
            selectors(None, None, Some(&first_pane), None),
            json!({"direction":"right","ratio":0.4}),
            Some("pure-split"),
        ),
    )
    .unwrap();
    let second_pane = split["value"]["pane_id"].as_str().unwrap().to_string();
    let renamed_pane = dispatch(
        &mux,
        parsed(
            ResourceOperation::PaneRename,
            selectors(None, None, Some(&second_pane), None),
            json!({"name":"renamed pane"}),
            Some("pure-rename-pane"),
        ),
    )
    .unwrap();
    assert_eq!(renamed_pane["value"]["name"], "renamed pane");
    let neighbor = dispatch(
        &mux,
        parsed(
            ResourceOperation::PaneNeighborGet,
            selectors(None, None, Some(&first_pane), None),
            json!({"direction":"right"}),
            None,
        ),
    )
    .unwrap();
    assert_eq!(neighbor["pane"]["id"], second_pane);
    let focused_pane = dispatch(
        &mux,
        parsed(
            ResourceOperation::PaneFocusDirection,
            selectors(None, None, Some(&first_pane), None),
            json!({"direction":"right"}),
            Some("pure-focus-direction"),
        ),
    )
    .unwrap();
    assert_eq!(focused_pane["value"]["id"], second_pane);
    assert_eq!(focused_pane["value"]["focused"], true);

    let zoomed = dispatch(
        &mux,
        parsed(
            ResourceOperation::PaneZoom,
            selectors(None, None, Some(&second_pane), None),
            json!({"enabled":true}),
            Some("pure-zoom"),
        ),
    )
    .unwrap();
    assert_eq!(zoomed["value"]["zoomed"], true);

    let layout = dispatch(
        &mux,
        parsed(
            ResourceOperation::ScreenLayoutExport,
            selectors(None, Some(&screen), None, None),
            json!({}),
            None,
        ),
    )
    .unwrap();
    let split_id = layout["root"]["split_id"].as_str().unwrap();
    let resized = dispatch(
        &mux,
        parsed(
            ResourceOperation::PaneSplitRatioSet,
            selectors(None, None, Some(&second_pane), None),
            json!({"split_id":split_id,"ratio":0.25}),
            Some("pure-ratio"),
        ),
    )
    .unwrap();
    assert_eq!(resized["value"]["id"], second_pane);
    let resized_layout = dispatch(
        &mux,
        parsed(
            ResourceOperation::ScreenLayoutExport,
            selectors(None, Some(&screen), None, None),
            json!({}),
            None,
        ),
    )
    .unwrap();
    assert_eq!(resized_layout["root"]["ratio"], 0.25);

    let renamed_screen = dispatch(
        &mux,
        parsed(
            ResourceOperation::ScreenRename,
            selectors(None, Some(&screen), None, None),
            json!({"name":"renamed screen"}),
            Some("pure-rename-screen"),
        ),
    )
    .unwrap();
    assert_eq!(renamed_screen["value"]["name"], "renamed screen");
    let focused_screen = dispatch(
        &mux,
        parsed(
            ResourceOperation::ScreenFocus,
            selectors(None, Some(&screen), None, None),
            json!({}),
            Some("pure-focus-screen"),
        ),
    )
    .unwrap();
    assert_eq!(focused_screen["value"]["focused"], true);
    let focused_workspace = dispatch(
        &mux,
        parsed(
            ResourceOperation::WorkspaceFocus,
            selectors(Some(&workspace), None, None, None),
            json!({}),
            Some("pure-focus-workspace"),
        ),
    )
    .unwrap();
    assert_eq!(focused_workspace["value"]["focused"], true);
}
