//! Layout undo: confirmation tokens, resize coalescing, focus restore, and column closes.

use super::*;

#[test]
fn zellij_new_pane_rebalances_only_the_focused_layout_column() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    let right_added = mux.new_pane(right_pane, Some((38, 10))).unwrap();
    let right_added_pane = mux.with_state(|state| state.pane_of(right_added.id).unwrap());
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns.len(), 2);
        assert_eq!(screen.layout_columns[0].root.pane_ids_vec(), vec![first_pane]);
        assert_eq!(
            screen.layout_columns[1].root.pane_ids_vec(),
            vec![right_pane, right_added_pane]
        );
        assert_eq!(
            screen.layout_columns[1].creation_order_auto_layout.as_deref(),
            Some([right_pane, right_added_pane].as_slice())
        );
        assert_eq!(screen.viewport_splits.len(), 1);
    });

    let left_added = mux.new_pane(first_pane, Some((38, 10))).unwrap();
    let left_added_pane = mux.with_state(|state| state.pane_of(left_added.id).unwrap());
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns[0].root.pane_ids_vec(), vec![first_pane, left_added_pane]);
        assert_eq!(
            screen.layout_columns[1].root.pane_ids_vec(),
            vec![right_pane, right_added_pane]
        );
        assert_eq!(screen.viewport_base_width, Some(1.0));
        assert_eq!(screen.viewport_splits.values().copied().collect::<Vec<_>>(), vec![0.5]);
        assert!(screen.layout_column_projection_is_consistent());
    });
}

#[test]
fn layout_undo_removes_only_the_pane_created_in_the_focused_column() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let added = mux.new_pane(right_pane, Some((38, 10))).unwrap();
    let added_pane = mux.with_state(|state| state.pane_of(added.id).unwrap());

    let LayoutUndoResult::ConfirmationRequired { revision, closes_panes, .. } =
        mux.undo_layout(added_pane, None, false).unwrap()
    else {
        panic!("new pane undo must require confirmation");
    };
    assert_eq!(closes_panes, vec![added_pane]);
    assert!(matches!(
        mux.undo_layout(added_pane, Some(revision), true).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));

    assert_terminal_view_detached(&mux, added.id);
    assert!(mux.surface(right.id).is_some());
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns.len(), 2);
        assert_eq!(screen.layout_columns[0].root.pane_ids_vec(), vec![first_pane]);
        assert_eq!(screen.layout_columns[1].root.pane_ids_vec(), vec![right_pane]);
        assert!(screen.layout_column_projection_is_consistent());
    });
}

#[test]
fn layout_undo_confirmation_preview_is_read_only() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let before = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (
            screen.layout_revision,
            format!("{:?}", screen.layout_snapshot()),
            format!("{:?}", screen.layout_undo),
            state.panes[&right_pane].tabs.clone(),
        )
    });

    let first_preview = mux.undo_layout(right_pane, None, false).unwrap();
    let second_preview = mux.undo_layout(right_pane, None, false).unwrap();

    assert_eq!(
        first_preview,
        LayoutUndoResult::ConfirmationRequired {
            screen: mux.with_state(|state| state.workspaces[0].screens[0].id),
            revision: before.0,
            closes_panes: vec![right_pane],
        }
    );
    assert_eq!(second_preview, first_preview);
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_revision, before.0);
        assert_eq!(format!("{:?}", screen.layout_snapshot()), before.1);
        assert_eq!(format!("{:?}", screen.layout_undo), before.2);
        assert_eq!(state.panes[&right_pane].tabs, before.3);
    });
}

#[test]
fn resource_layout_undo_preview_does_not_enter_the_durable_journal() {
    let mux = test_mux();
    let first = mux.new_browser_tab("about:blank#first".into(), None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right_terminal = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right_terminal.id).unwrap());
    let right =
        mux.new_browser_tab("about:blank#right".into(), Some(right_pane), Some((38, 22))).unwrap();
    assert!(mux.close_surface(right_terminal.id).unwrap());
    let (selectors, before_screen) = {
        let registry = mux.workspace_registry.lock().unwrap();
        let state = mux.state.lock().unwrap();
        let (workspace, screen) = state.screen_of(right_pane).unwrap();
        (
            crate::ResourceSelectors {
                machine: Some(registry.machine_id().to_string()),
                session: Some(registry.session_id().to_string()),
                workspace: Some(state.workspaces[workspace].public_id.to_string()),
                screen: Some(state.workspaces[workspace].screens[screen].public_id.to_string()),
                ..crate::ResourceSelectors::default()
            },
            (
                state.workspaces[workspace].screens[screen].layout_revision,
                format!("{:?}", state.workspaces[workspace].screens[screen].layout_snapshot()),
                format!("{:?}", state.workspaces[workspace].screens[screen].layout_undo),
            ),
        )
    };
    let fields = serde_json::json!({"confirm_close":false}).as_object().unwrap().clone();
    let fingerprint = serde_json::json!({
        "operation":"screen.layout.undo",
        "selectors":selectors,
        "fields":fields,
    });
    let mutation = WorkspaceMutation::daemon("read-only-undo-preview", "test").unwrap();
    let before_registry =
        mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();

    let error = mux
        .resource_topology_operation(
            ResourceOperation::ScreenLayoutUndo,
            selectors.clone(),
            fields,
            Some(before_registry.revision),
            &mutation,
        )
        .unwrap_err();

    let preview = error.downcast_ref::<ResourceError>().unwrap();
    assert_eq!(preview.code, "confirmation.required");
    assert_eq!(preview.details["revision"], before_registry.revision.to_string());
    let confirmation_token = preview.details["confirmation_token"].as_str().unwrap().to_string();
    assert_eq!(confirmation_token.len(), 64);
    assert!(confirmation_token.bytes().all(|byte| byte.is_ascii_hexdigit()));
    mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(right_pane).unwrap();
        let screen = &state.workspaces[workspace].screens[screen];
        assert_eq!(screen.layout_revision, before_screen.0);
        assert_eq!(format!("{:?}", screen.layout_snapshot()), before_screen.1);
        assert_eq!(format!("{:?}", screen.layout_undo), before_screen.2);
    });
    let registry = mux.workspace_registry.lock().unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap(), before_registry);
    assert!(registry.resource_events_after(before_registry.revision).unwrap().batches.is_empty());
    assert!(
        registry
            .lookup_resource_effect(&mutation.id, "screen.layout.undo", &fingerprint,)
            .unwrap()
            .is_none()
    );
    drop(registry);

    let missing_token_fields =
        serde_json::json!({"confirm_close":true}).as_object().unwrap().clone();
    let missing_token_fingerprint = serde_json::json!({
        "operation":"screen.layout.undo",
        "selectors":selectors,
        "fields":missing_token_fields,
    });
    let missing_token_mutation =
        WorkspaceMutation::daemon("missing-token-undo-confirm", "test").unwrap();
    let missing_token = mux
        .resource_topology_operation(
            ResourceOperation::ScreenLayoutUndo,
            selectors.clone(),
            missing_token_fields,
            Some(before_registry.revision),
            &missing_token_mutation,
        )
        .unwrap_err();
    let missing_token = missing_token.downcast_ref::<ResourceError>().unwrap();
    assert_eq!(missing_token.code, "confirmation.required");
    assert_eq!(missing_token.details, preview.details);

    let missing_revision_fields = serde_json::json!({
        "confirm_close":true,
        "confirmation_token":confirmation_token,
    })
    .as_object()
    .unwrap()
    .clone();
    let missing_revision_fingerprint = serde_json::json!({
        "operation":"screen.layout.undo",
        "selectors":selectors,
        "fields":missing_revision_fields,
    });
    let missing_revision_mutation =
        WorkspaceMutation::daemon("missing-revision-undo-confirm", "test").unwrap();
    let missing_revision = mux
        .resource_topology_operation(
            ResourceOperation::ScreenLayoutUndo,
            selectors.clone(),
            missing_revision_fields,
            None,
            &missing_revision_mutation,
        )
        .unwrap_err();
    let missing_revision = missing_revision.downcast_ref::<ResourceError>().unwrap();
    assert_eq!(missing_revision.code, "confirmation.required");
    assert_eq!(missing_revision.details, preview.details);
    let registry = mux.workspace_registry.lock().unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap(), before_registry);
    assert!(registry.resource_events_after(before_registry.revision).unwrap().batches.is_empty());
    assert!(
        registry
            .lookup_resource_effect(
                &missing_token_mutation.id,
                "screen.layout.undo",
                &missing_token_fingerprint,
            )
            .unwrap()
            .is_none()
    );
    assert!(
        registry
            .lookup_resource_effect(
                &missing_revision_mutation.id,
                "screen.layout.undo",
                &missing_revision_fingerprint,
            )
            .unwrap()
            .is_none()
    );
    drop(registry);

    let late_tab = mux.new_tab(Some(right_pane), None, Some((38, 22))).unwrap();
    let stale_fields = serde_json::json!({
        "confirm_close":true,
        "confirmation_token":confirmation_token,
    })
    .as_object()
    .unwrap()
    .clone();
    let stale_fingerprint = serde_json::json!({
        "operation":"screen.layout.undo",
        "selectors":selectors,
        "fields":stale_fields,
    });
    let stale_mutation = WorkspaceMutation::daemon("stale-undo-confirm", "test").unwrap();
    let stale = mux
        .resource_topology_operation(
            ResourceOperation::ScreenLayoutUndo,
            selectors.clone(),
            stale_fields.clone(),
            Some(before_registry.revision),
            &stale_mutation,
        )
        .unwrap_err();
    let refreshed = stale
        .downcast_ref::<ResourceError>()
        .unwrap_or_else(|| panic!("stale confirmation returned an untyped error: {stale:#}"));
    assert_eq!(refreshed.code, "confirmation.required");
    assert_ne!(refreshed.details["confirmation_token"], stale_fields["confirmation_token"]);
    assert!(mux.surface(right.id).is_some());
    assert!(mux.surface(late_tab.id).is_some());
    assert!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .lookup_resource_effect(&stale_mutation.id, "screen.layout.undo", &stale_fingerprint,)
            .unwrap()
            .is_none()
    );

    let refreshed_revision =
        refreshed.details["revision"].as_str().unwrap().parse::<u64>().unwrap();
    let confirmed_fields = serde_json::json!({
        "confirm_close":true,
        "confirmation_token":refreshed.details["confirmation_token"],
    })
    .as_object()
    .unwrap()
    .clone();
    let committed = mux
        .resource_topology_operation(
            ResourceOperation::ScreenLayoutUndo,
            selectors,
            confirmed_fields,
            Some(refreshed_revision),
            &WorkspaceMutation::daemon("fresh-undo-confirm", "test").unwrap(),
        )
        .unwrap();
    assert!(!committed.replayed);
    assert!(mux.surface(right.id).is_none());
    assert_terminal_view_detached(&mux, late_tab.id);
}

#[test]
fn layout_undo_confirmation_fences_exact_created_pane_tab_membership() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    let LayoutUndoResult::ConfirmationRequired { revision, .. } =
        mux.undo_layout(right_pane, None, false).unwrap()
    else {
        panic!("pane creation undo must require confirmation");
    };
    let late_tab = mux.new_tab(Some(right_pane), None, Some((38, 22))).unwrap();

    let error = mux.undo_layout(right_pane, Some(revision), true).unwrap_err();
    assert!(matches!(
        error.downcast_ref::<LayoutUndoError>(),
        Some(LayoutUndoError::Stale(message))
            if message.contains("layout revision conflict")
    ));
    assert!(mux.surface(right.id).is_some());
    assert!(mux.surface(late_tab.id).is_some());

    let LayoutUndoResult::ConfirmationRequired { revision: refreshed, .. } =
        mux.undo_layout(right_pane, None, false).unwrap()
    else {
        panic!("a fresh preview must capture the new tab membership");
    };
    assert!(refreshed > revision);
    assert!(matches!(
        mux.undo_layout(right_pane, Some(refreshed), true).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    assert_terminal_view_detached(&mux, right.id);
    assert_terminal_view_detached(&mux, late_tab.id);
}

#[test]
fn layout_undo_confirmation_and_tab_creation_commit_atomically() {
    for _ in 0..16 {
        let mux = test_mux();
        let first = mux.new_workspace(None, Some((80, 22))).unwrap();
        let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
        let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
        let LayoutUndoResult::ConfirmationRequired { revision, .. } =
            mux.undo_layout(right_pane, None, false).unwrap()
        else {
            panic!("pane creation undo must require confirmation");
        };
        let start = Arc::new(std::sync::Barrier::new(3));
        let tab = {
            let mux = mux.clone();
            let start = start.clone();
            std::thread::spawn(move || {
                start.wait();
                mux.new_tab(Some(right_pane), None, Some((38, 22)))
            })
        };
        let undo = {
            let mux = mux.clone();
            let start = start.clone();
            std::thread::spawn(move || {
                start.wait();
                mux.undo_layout(right_pane, Some(revision), true)
            })
        };
        start.wait();
        let tab = tab.join().unwrap();
        let undo = undo.join().unwrap();

        match (tab, undo) {
            (Ok(tab), Err(error)) => {
                assert!(matches!(
                    error.downcast_ref::<LayoutUndoError>(),
                    Some(LayoutUndoError::Stale(message))
                        if message.contains("layout revision conflict")
                ));
                assert!(mux.surface(right.id).is_some());
                assert!(mux.surface(tab.id).is_some());
            }
            (Err(_), Ok(LayoutUndoResult::Undone { .. })) => {
                assert_terminal_view_detached(&mux, right.id);
            }
            (tab, undo) => {
                panic!("tab creation and confirmed undo partially committed: {tab:?}, {undo:?}")
            }
        }
    }
}

#[test]
fn layout_undo_public_edge_failures_are_typed() {
    let mux = test_mux();
    let unknown_pane = mux.undo_layout(u64::MAX, None, false).unwrap_err();

    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let LayoutUndoResult::ConfirmationRequired { .. } =
        mux.undo_layout(right_pane, None, false).unwrap()
    else {
        panic!("pane creation undo must require confirmation");
    };
    let missing_revision = mux.undo_layout(right_pane, None, true).unwrap_err();

    assert_eq!(
        [
            matches!(
                unknown_pane.downcast_ref::<LayoutUndoError>(),
                Some(LayoutUndoError::Stale(_))
            ),
            matches!(
                missing_revision.downcast_ref::<LayoutUndoError>(),
                Some(LayoutUndoError::Stale(_))
            ),
        ],
        [true, true],
        "public layout-undo edge failures must preserve their typed error"
    );
}

#[test]
fn layout_undo_coalesces_resize_and_fences_pane_closure() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.6, 7, 11));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(
            screen
                .layout_snapshot_for_coalescing_change(Some(LayoutMutationKey::Resize {
                    owner: LayoutResizeOwner::ControlClient(7),
                    transaction: 11,
                }))
                .is_none(),
            "continuation samples must reuse the transaction's first snapshot"
        );
    });
    assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.7, 7, 11));
    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns[1].width, 0.5);
    });

    let LayoutUndoResult::ConfirmationRequired { revision, closes_panes, .. } =
        mux.undo_layout(right_pane, None, false).unwrap()
    else {
        panic!("pane creation undo must require confirmation");
    };
    assert_eq!(closes_panes, vec![right_pane]);
    assert!(
        mux.undo_layout(right_pane, None, true)
            .unwrap_err()
            .to_string()
            .contains("requires the preview revision")
    );
    assert!(
        mux.undo_layout(right_pane, Some(revision.saturating_sub(1)), true)
            .unwrap_err()
            .to_string()
            .contains("revision conflict")
    );
    assert!(mux.surface(right.id).is_some());

    assert!(matches!(
        mux.undo_layout(right_pane, Some(revision), true).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    assert_terminal_view_detached(&mux, right.id);
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(!screen.layout_columns_active());
        assert!(screen.viewport_splits.is_empty());
        assert_eq!(screen.root.pane_ids_vec(), vec![first_pane]);
        assert_eq!(screen.active_pane, first_pane);
        assert!(screen.layout_column_projection_is_consistent());
    });
}

#[test]
fn layout_undo_preserves_focus_when_the_current_pane_survives() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    assert!(mux.focus_pane(first_pane));
    assert!(mux.set_viewport_pane_width(right_pane, 0.7));
    assert!(mux.focus_pane(right_pane));
    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.active_pane, right_pane);
        assert_eq!(screen.layout_columns[1].width, 0.5);
    });
}

#[test]
fn layout_undo_restores_focus_to_the_restored_zoomed_pane() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.split(first_pane, SplitDir::Right, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    assert!(mux.focus_pane(first_pane));
    mux.zoom_pane(Some(first_pane), ZoomMode::On).unwrap();
    mux.zoom_pane(Some(first_pane), ZoomMode::Off).unwrap();
    assert!(mux.focus_pane(right_pane));
    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.zoomed_pane, Some(first_pane));
        assert_eq!(screen.active_pane, first_pane);
        assert_eq!(state.active_pane(), Some(first_pane));
    });
}

#[test]
fn layout_undo_preserves_inactive_stack_selection() {
    let mux = test_mux();
    let applied = mux
        .apply_layout(
            None,
            None,
            &split_spec(
                SplitDir::Right,
                0.5,
                LayoutSpec::Stack { pane_count: 2, expanded_index: 0 },
                LayoutSpec::Stack { pane_count: 2, expanded_index: 0 },
            ),
            Some((80, 22)),
        )
        .unwrap();
    let [left_first, left_second, right_first, _right_second] =
        applied.panes.iter().map(|pane| pane.pane).collect::<Vec<_>>()[..]
    else {
        panic!("two two-pane stacks should create four panes");
    };
    {
        let mut state = mux.state.lock().unwrap();
        let screen = &mut state.workspaces[0].screens[0];
        let root = std::mem::replace(&mut screen.root, Node::Leaf(0));
        let Node::Split { id, a, b, .. } = root else {
            panic!("test layout should have two stack branches");
        };
        screen.layout_columns = vec![
            LayoutColumn::new(mux.next_id(), 1.0, *a, None),
            LayoutColumn::new(id, 0.5, *b, None),
        ];
        screen.sync_layout_column_projection();
        Mux::rebuild_split_screen_index(&mut state);
    }
    mux.commit_ordinary_full_resource_projection(
        &Actor::Daemon,
        "test.viewport_stack.prepare",
        serde_json::json!({}),
    )
    .unwrap();

    assert!(mux.focus_pane(right_first));
    assert!(mux.set_viewport_pane_width(right_first, 0.7));
    assert!(mux.focus_pane(left_second));
    assert!(mux.focus_pane(right_first));
    assert!(matches!(
        mux.undo_layout(right_first, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.active_pane, right_first);
        assert!(matches!(
            &screen.layout_columns[0].root,
            Node::Stack { expanded, .. } if *expanded == left_second
        ));
        assert!(!matches!(
            &screen.layout_columns[0].root,
            Node::Stack { expanded, .. } if *expanded == left_first
        ));
        assert!(matches!(
            &screen.root,
            Node::Split { a, .. }
                if matches!(
                    a.as_ref(),
                    Node::Stack { expanded, .. } if *expanded == left_second
                )
        ));
        assert!(screen.layout_column_projection_is_consistent());
    });
}

#[test]
fn layout_undo_coalesces_every_target_in_one_resize_transaction() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    let bottom = mux.split(right_pane, SplitDir::Down, Some((38, 10))).unwrap();
    let bottom_pane = mux.with_state(|state| state.pane_of(bottom.id).unwrap());
    let (split, initial_ratio, initial_undo_len) = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let Node::Split { id, ratio, .. } = &screen.layout_columns[1].root else {
            panic!("right viewport column must contain the vertical split");
        };
        (*id, *ratio, screen.layout_undo.len())
    });

    assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.7, 9, 41));
    assert!(mux.set_split_ratio_in_transaction_checked(split, 0.7, 9, 41).is_ok());
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_undo.len(), initial_undo_len + 1);
    });

    assert!(matches!(
        mux.undo_layout(bottom_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns[1].width, 0.5);
        let Node::Split { ratio, .. } = &screen.layout_columns[1].root else {
            panic!("right viewport column must retain the vertical split");
        };
        assert!((*ratio - initial_ratio).abs() < f32::EPSILON);
        assert_eq!(screen.layout_undo.len(), initial_undo_len);
    });
}

#[test]
fn layout_undo_separates_resize_transactions_and_clients() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.6, 1, 1));
    assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.7, 1, 1));
    assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.8, 1, 2));
    assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.65, 2, 2));
    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.8);
    });

    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.7);
    });

    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.5);
    });
}

#[test]
fn layout_undo_separates_in_process_and_control_resize_owners_with_same_ids() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    // These model independent in-process and control-client entrypoints
    // that happen to allocate the same numeric owner and transaction ids.
    assert!(
        mux.set_viewport_pane_width_in_process_transaction_checked(right_pane, 0.6, 1, 1).is_ok()
    );
    assert!(mux.set_viewport_pane_width_in_transaction(right_pane, 0.7, 1, 1));

    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.6);
    });

    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[0].layout_columns[1].width, 0.5);
    });
}

#[test]
fn in_process_resize_owner_allocation_is_mux_scoped() {
    let first = test_mux();
    assert_eq!(first.allocate_in_process_resize_owner(), 1);
    assert_eq!(first.allocate_in_process_resize_owner(), 2);

    let second = test_mux();
    assert_eq!(second.allocate_in_process_resize_owner(), 1);
}

#[test]
fn layout_undo_separates_a_new_resize_from_pre_undo_history() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    assert!(mux.set_viewport_pane_width(right_pane, 0.6));
    assert!(mux.set_viewport_pane_width(first_pane, 0.9));
    assert!(matches!(
        mux.undo_layout(first_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));

    assert!(mux.set_viewport_pane_width(right_pane, 0.7));
    assert!(matches!(
        mux.undo_layout(right_pane, None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns[0].width, 1.0);
        assert_eq!(screen.layout_columns[1].width, 0.6);
    });
}

#[test]
fn closing_a_pane_invalidates_layout_undo_history() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let right = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());

    assert!(mux.close_pane(right_pane).unwrap());
    let error = mux.undo_layout(first_pane, None, false).unwrap_err();

    assert_eq!(error.to_string(), "no layout change to undo");
    assert_terminal_view_detached(&mux, right.id);
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(!screen.layout_columns_active());
        assert!(screen.layout_column_projection_is_consistent());
    });
}

#[test]
fn closing_the_base_viewport_column_preserves_the_promoted_width() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let middle = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let middle_pane = mux.with_state(|state| state.pane_of(middle.id).unwrap());
    let right = mux.new_pane_right(middle_pane, 0.4, Some((30, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    assert!(mux.set_viewport_pane_width(first_pane, 0.75));

    assert!(mux.close_pane(first_pane).unwrap());

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.viewport_base_width, Some(0.5));
        assert_eq!(
            screen.root.viewport_column_owner(middle_pane, &screen.viewport_splits),
            Some(ViewportColumn::Base)
        );
        let ViewportColumn::Split(right_split) =
            screen.root.viewport_column_owner(right_pane, &screen.viewport_splits).unwrap()
        else {
            panic!("right pane must remain an appended column");
        };
        assert_eq!(screen.viewport_splits[&right_split], 0.4);
        let Node::Split { ratio, .. } = &screen.root else {
            panic!("two viewport columns must retain one split");
        };
        assert!((*ratio - (0.5 / 0.9)).abs() < 0.0001);
    });
}

#[test]
fn closing_a_middle_viewport_column_recomputes_fallback_ratios() {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let middle = mux.new_pane_right(first_pane, 0.5, Some((38, 22))).unwrap();
    let middle_pane = mux.with_state(|state| state.pane_of(middle.id).unwrap());
    let right = mux.new_pane_right(middle_pane, 0.4, Some((30, 22))).unwrap();
    let right_pane = mux.with_state(|state| state.pane_of(right.id).unwrap());
    assert!(mux.set_viewport_pane_width(first_pane, 0.75));

    assert!(mux.close_pane(middle_pane).unwrap());

    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.viewport_base_width, Some(0.75));
        let ViewportColumn::Split(right_split) =
            screen.root.viewport_column_owner(right_pane, &screen.viewport_splits).unwrap()
        else {
            panic!("right pane must remain appended");
        };
        assert_eq!(screen.viewport_splits.len(), 1);
        assert_eq!(screen.viewport_splits[&right_split], 0.4);
        let Node::Split { ratio, .. } = &screen.root else {
            panic!("two viewport columns must retain one split");
        };
        assert!((*ratio - (0.75 / 1.15)).abs() < 0.0001);
    });
}
