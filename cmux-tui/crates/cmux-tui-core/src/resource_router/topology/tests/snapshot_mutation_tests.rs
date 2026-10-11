use super::*;

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

#[test]
fn tab_create_terminal_in_workspace_adds_a_selected_tab_to_its_focused_pane() {
    let mux = mux();
    let created = terminal_workspace(&mux, "workspace-tab");
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let first_pane = created["value"]["pane_id"].as_str().unwrap().to_string();
    let split = dispatch(
        &mux,
        parsed(
            ResourceOperation::PaneSplit,
            selectors(None, None, Some(&first_pane), None),
            json!({"direction":"right","ratio":0.5}),
            Some("workspace-tab-split"),
        ),
    )
    .unwrap();
    let second_pane = split["value"]["pane_id"].as_str().unwrap().to_string();

    // Focus each pane in turn so the target cannot be the newest pane by
    // coincidence.
    for (round, pane) in [&first_pane, &second_pane, &first_pane].into_iter().enumerate() {
        let focus_key = format!("workspace-tab-focus-{round}");
        let create_key = format!("workspace-tab-create-{round}");
        dispatch(
            &mux,
            parsed(
                ResourceOperation::PaneFocus,
                selectors(None, None, Some(pane), None),
                json!({}),
                Some(&focus_key),
            ),
        )
        .unwrap();
        let tab = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabCreateTerminal,
                selectors(Some(&workspace), None, None, None),
                json!({"name":"phone tab"}),
                Some(&create_key),
            ),
        )
        .unwrap();
        assert_eq!(tab["value"]["kind"], "terminal");
        assert_eq!(tab["value"]["workspace_id"], workspace);
        assert_eq!(tab["value"]["pane_id"], *pane, "round {round}");
        let tab_id = tab["value"]["tab_id"].as_str().unwrap();
        let snapshot = dispatch(
            &mux,
            parsed(
                ResourceOperation::TabGet,
                selectors(None, None, None, Some(tab_id)),
                json!({}),
                None,
            ),
        )
        .unwrap();
        assert_eq!(snapshot["focused"], true, "round {round}: the new tab is selected");
    }
    mux.shutdown();
}
