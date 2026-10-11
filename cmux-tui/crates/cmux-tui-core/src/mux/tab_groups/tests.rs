use super::*;

fn tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone())).unwrap_or_default()
}

fn runs(mux: &Mux, pane: PaneId) -> Vec<(String, Vec<SurfaceId>)> {
    let presentation = mux.presentation_snapshot();
    mux.with_state(|state| {
        pane_tab_groups(state, &presentation, pane)
            .into_iter()
            .map(|run| (run.group.id, run.members))
            .collect()
    })
}

#[test]
fn cmux_next_tab_groups_keep_members_contiguous_through_edits() {
    let mux = Mux::new_for_test("tab-groups", SurfaceOptions::default());
    let t1 = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(t1)).unwrap();
    let t2 = mux.new_tab(Some(pane), None, None).unwrap().id;
    let t3 = mux.new_tab(Some(pane), None, None).unwrap().id;
    let t4 = mux.new_tab(Some(pane), None, None).unwrap().id;
    mux.set_tab_pinned(t1, true).unwrap();
    assert!(mux.create_tab_group(&[t1], None, None, None, None).is_err());
    assert!(mux.create_tab_group(&[t2], None, Some("blurple".into()), None, None).is_err());

    let created = mux
        .create_tab_group(
            &[t4, t2],
            Some("Agents".into()),
            Some("green".into()),
            Some("g1".into()),
            Some("tx-1"),
        )
        .unwrap();
    assert_eq!(created.members, vec![t2, t4]);
    assert_eq!(tabs(&mux, pane), vec![t1, t2, t4, t3]);
    assert_eq!(runs(&mux, pane), vec![("g1".to_string(), vec![t2, t4])]);
    let durable = mux.workspace_registry.lock().unwrap().presentation_snapshot().unwrap();
    assert_eq!(durable.tab_groups.groups["g1"].color, "green");
    assert_eq!(durable.tab_groups.members.len(), 2);

    mux.update_tab_group("g1", Some("".into()), Some("cyan".into()), Some(true)).unwrap();
    let group = mux.presentation_snapshot().tab_groups.groups["g1"].clone();
    assert_eq!((group.name.as_str(), group.color.as_str(), group.collapsed), ("", "cyan", true));

    // A repeated surface joins once and appears once in the tab order.
    mux.add_tabs_to_tab_group("g1", &[t3, t3], None).unwrap();
    assert_eq!(runs(&mux, pane), vec![("g1".to_string(), vec![t2, t4, t3])]);
    assert_eq!(tabs(&mux, pane), vec![t1, t2, t4, t3]);
    mux.remove_tabs_from_tab_group(&[t2], None).unwrap();
    assert_eq!(tabs(&mux, pane), vec![t1, t4, t3, t2]);
    assert_eq!(runs(&mux, pane), vec![("g1".to_string(), vec![t4, t3])]);

    // Moving the group within its strip cannot pass the pinned tab.
    mux.move_tab_group("g1", TabGroupDestination::Strip { pane, index: Some(0) }, None).unwrap();
    assert_eq!(tabs(&mux, pane), vec![t1, t4, t3, t2]);
    mux.move_tab_group("g1", TabGroupDestination::Strip { pane, index: None }, None).unwrap();
    assert_eq!(tabs(&mux, pane), vec![t1, t2, t4, t3]);

    let decorations = mux.tree_decorations();
    let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
    let pane_json = &tree["workspaces"][0]["screens"][0]["panes"][0];
    assert_eq!(pane_json["tab_groups"][0]["id"], "g1");
    assert_eq!(pane_json["tab_groups"][0]["start"], 2);
    assert_eq!(pane_json["tab_groups"][0]["count"], 2);
    assert_eq!(pane_json["tabs"][2]["group"], "g1");
    assert!(pane_json["tabs"][1]["group"].is_null());

    // The whole group moves into a new split and stays grouped.
    let moved = mux
        .move_tab_group(
            "g1",
            TabGroupDestination::Split { pane, edge: TabDropEdge::Right, ratio: None },
            None,
        )
        .unwrap();
    let new_pane = moved.pane.unwrap();
    assert_ne!(new_pane, pane);
    assert_eq!(tabs(&mux, new_pane), vec![t4, t3]);
    assert_eq!(tabs(&mux, pane), vec![t1, t2]);
    assert_eq!(runs(&mux, new_pane), vec![("g1".to_string(), vec![t4, t3])]);

    // Ungroup leaves the tabs in place.
    assert_eq!(mux.ungroup_tab_group("g1").unwrap(), vec![t4, t3]);
    assert!(runs(&mux, new_pane).is_empty());
    assert_eq!(tabs(&mux, new_pane), vec![t4, t3]);
}

#[test]
fn cmux_next_saved_tab_groups_outlive_close_and_reopen() {
    let mux = Mux::new_for_test("saved-tab-groups", SurfaceOptions::default());
    let t1 = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(t1)).unwrap();
    let t2 = mux.new_tab(Some(pane), None, None).unwrap().id;
    let t3 = mux.new_tab(Some(pane), None, None).unwrap().id;
    mux.create_tab_group(
        &[t2, t3],
        Some("Build".into()),
        Some("orange".into()),
        Some("g".into()),
        None,
    )
    .unwrap();
    let saved = mux.save_tab_group("g").unwrap();
    let record = mux.saved_tab_groups().into_iter().find(|record| record.id == saved).unwrap();
    assert_eq!((record.name.as_str(), record.members.len()), ("Build", 2));
    // Rename syncs to the saved record.
    mux.update_tab_group("g", Some("Release".into()), None, None).unwrap();
    assert_eq!(mux.saved_tab_groups()[0].name, "Release");

    let closed = mux.close_tab_group("g").unwrap();
    assert_eq!(closed, vec![t2, t3]);
    assert_eq!(tabs(&mux, pane), vec![t1]);
    assert!(mux.presentation_snapshot().tab_groups.groups.is_empty());
    assert_eq!(mux.saved_tab_groups().len(), 1);

    let reopened = mux.reopen_saved_tab_group(&saved, pane, Some("tx-reopen")).unwrap();
    let group = reopened.group.clone().unwrap();
    assert_eq!(group.name, "Release");
    assert_eq!(group.color, "orange");
    assert_eq!(group.saved_id.as_deref(), Some(saved.as_str()));
    assert_eq!(reopened.members.len(), 2);
    // Reopening again returns the live group.
    let again = mux.reopen_saved_tab_group(&saved, pane, None).unwrap();
    assert_eq!(again.group.unwrap().id, group.id);

    // Moving the group into a new workspace carries it along.
    let moved = mux
        .move_tab_group(
            &group.id,
            TabGroupDestination::NewWorkspace { group: None, index: None },
            None,
        )
        .unwrap();
    let workspace = moved.workspace.unwrap();
    assert!(mux.with_state(|state| state.workspace_index(workspace).is_some()));
    assert_eq!(runs(&mux, moved.pane.unwrap()).len(), 1);

    assert!(mux.unsave_tab_group(&group.id).unwrap());
    assert!(mux.saved_tab_groups().is_empty());
    assert!(!mux.delete_saved_tab_group(&saved).unwrap());
}
