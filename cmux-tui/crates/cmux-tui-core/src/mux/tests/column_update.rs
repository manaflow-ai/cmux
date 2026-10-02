//! `column.update` (resource API v2): pins, unpins, and resizes a viewport
//! column through the same reducer as `set-column-sticky`, with idempotent
//! replay and the layout invariants of `sticky-columns-v1`.

use super::*;
use crate::model::{ColumnSticky, StickyEdge, StickyMode};

/// A screen with `count` viewport columns, one pane each.
fn column_mux(count: usize) -> (Arc<Mux>, Vec<PaneId>) {
    let mux = test_mux();
    let first = mux.new_workspace(None, Some((80, 22))).unwrap();
    let mut panes = vec![mux.with_state(|state| state.pane_of(first.id).unwrap())];
    for _ in 1..count {
        let last = *panes.last().unwrap();
        let surface = mux.new_pane_right(last, 0.5, Some((38, 22))).unwrap();
        panes.push(mux.with_state(|state| state.pane_of(surface.id).unwrap()));
    }
    (mux, panes)
}

fn screen_id(mux: &Arc<Mux>) -> String {
    mux.with_state(|state| state.workspaces[0].screens[0].public_id.to_string())
}

fn column_ids(mux: &Arc<Mux>) -> Vec<String> {
    mux.with_state(|state| {
        state.workspaces[0].screens[0]
            .layout_columns
            .iter()
            .map(|column| state.resource_indexes.split_ids[&column.id].to_string())
            .collect()
    })
}

fn flags(mux: &Arc<Mux>) -> Vec<Option<ColumnSticky>> {
    mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns.iter().map(|column| column.sticky).collect()
    })
}

fn widths(mux: &Arc<Mux>) -> Vec<f32> {
    mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns.iter().map(|column| column.width).collect()
    })
}

fn revision(mux: &Arc<Mux>) -> u64 {
    mux.with_state(|state| state.resource_revision)
}

/// One `column.update` request on the test screen.
fn update(
    mux: &Arc<Mux>,
    fields: serde_json::Value,
    key: &str,
) -> Result<serde_json::Value, crate::resource::ResourceError> {
    let mut params = serde_json::json!({
        "machine": "current",
        "session": "current",
        "screen": screen_id(mux),
    });
    for (name, value) in fields.as_object().unwrap() {
        params[name] = value.clone();
    }
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": key,
        "operation": "column.update",
        "params": params,
        "idempotency_key": key,
    });
    crate::resource_router::handle_resource_message(mux, &request.to_string())
}

fn flag(edge: StickyEdge, mode: StickyMode) -> Option<ColumnSticky> {
    Some(ColumnSticky { edge, mode })
}

#[test]
fn column_update_pins_unpins_and_replays_by_idempotency_key() {
    let (mux, _) = column_mux(3);
    let columns = column_ids(&mux);
    let pin = || {
        update(
            &mux,
            serde_json::json!({
                "column": columns[1],
                "sticky": true,
                "edge": "left",
                "mode": "overlay",
            }),
            "column-pin",
        )
    };
    let pinned = pin().unwrap();
    assert_eq!(pinned["result"]["value"]["id"], screen_id(&mux), "{pinned}");
    assert_eq!(pinned["result"]["replayed"], false);
    assert_eq!(flags(&mux), vec![None, flag(StickyEdge::Left, StickyMode::Overlay), None]);

    let committed = revision(&mux);
    let replay = pin().unwrap();
    assert_eq!(replay["result"]["replayed"], true, "{replay}");
    assert_eq!(replay["result"]["value"], pinned["result"]["value"]);
    assert_eq!(replay["result"]["revision"], pinned["result"]["revision"]);
    assert_eq!(revision(&mux), committed, "a replay commits nothing");

    // Defaults: right and docked.
    update(&mux, serde_json::json!({"column": columns[2], "sticky": true}), "column-right")
        .unwrap();
    assert_eq!(
        flags(&mux),
        vec![
            None,
            flag(StickyEdge::Left, StickyMode::Overlay),
            flag(StickyEdge::Right, StickyMode::Docked)
        ]
    );

    update(&mux, serde_json::json!({"column": columns[1], "sticky": false}), "column-unpin")
        .unwrap();
    assert_eq!(flags(&mux), vec![None, None, flag(StickyEdge::Right, StickyMode::Docked)]);
}

#[test]
fn column_update_sets_width_and_flag_in_one_commit() {
    let (mux, _) = column_mux(3);
    let columns = column_ids(&mux);
    let before = revision(&mux);
    update(
        &mux,
        serde_json::json!({"column": columns[0], "sticky": true, "edge": "left", "width": 0.4}),
        "column-both",
    )
    .unwrap();
    assert_eq!(revision(&mux), before + 1, "one commit");
    assert_eq!(flags(&mux)[0], flag(StickyEdge::Left, StickyMode::Docked));
    assert!((widths(&mux)[0] - 0.4).abs() < 1e-6);
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(screen.layout_column_projection_is_consistent());
        assert_eq!(screen.viewport_base_width, Some(screen.layout_columns[0].width));
    });

    update(&mux, serde_json::json!({"column": columns[2], "width": 0.7}), "column-width").unwrap();
    assert!((widths(&mux)[2] - 0.7).abs() < 1e-6);
    assert_eq!(flags(&mux)[2], None, "a width change leaves the flag");
}

#[test]
fn column_update_replaces_and_moves_edges_like_set_column_sticky() {
    let (mux, _) = column_mux(3);
    let columns = column_ids(&mux);
    update(&mux, serde_json::json!({"column": columns[2], "sticky": true}), "column-a").unwrap();
    update(&mux, serde_json::json!({"column": columns[1], "sticky": true}), "column-b").unwrap();
    assert_eq!(flags(&mux), vec![None, flag(StickyEdge::Right, StickyMode::Docked), None]);
    update(
        &mux,
        serde_json::json!({"column": columns[1], "sticky": true, "edge": "left"}),
        "column-c",
    )
    .unwrap();
    assert_eq!(flags(&mux), vec![None, flag(StickyEdge::Left, StickyMode::Docked), None]);
}

#[test]
fn column_update_refuses_to_leave_no_scrolling_column() {
    let (mux, _) = column_mux(2);
    let columns = column_ids(&mux);
    update(&mux, serde_json::json!({"column": columns[1], "sticky": true}), "column-ok").unwrap();
    let before = (flags(&mux), revision(&mux));
    let rejected = update(
        &mux,
        serde_json::json!({"column": columns[0], "sticky": true, "edge": "left"}),
        "column-last",
    );
    assert_eq!(rejected.unwrap_err().code, "validation.invalid");
    assert_eq!((flags(&mux), revision(&mux)), before, "a reject changes nothing");
}

#[test]
fn column_update_rejects_malformed_requests_without_changes() {
    let (mux, _) = column_mux(2);
    let columns = column_ids(&mux);
    let before = (flags(&mux), widths(&mux), revision(&mux));
    for (key, fields) in [
        ("no-change", serde_json::json!({"column": columns[1]})),
        ("edge-alone", serde_json::json!({"column": columns[1], "edge": "left"})),
        ("bad-edge", serde_json::json!({"column": columns[1], "sticky": true, "edge": "top"})),
        ("bad-width", serde_json::json!({"column": columns[1], "width": 1.5})),
        (
            "unknown-column",
            serde_json::json!({"column": "split_0000000000000000000000000000beef", "sticky": true}),
        ),
    ] {
        let error = update(&mux, fields, key).expect_err(key);
        assert_eq!(error.code, "validation.invalid", "{key}: {error:?}");
    }
    assert_eq!((flags(&mux), widths(&mux), revision(&mux)), before);
}

#[test]
fn column_update_is_undone_by_undo_layout() {
    let (mux, panes) = column_mux(3);
    let columns = column_ids(&mux);
    update(&mux, serde_json::json!({"column": columns[2], "sticky": true}), "column-undo").unwrap();
    assert!(flags(&mux)[2].is_some());
    assert!(matches!(
        mux.undo_layout(panes[2], None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    assert_eq!(flags(&mux), vec![None, None, None]);
}

/// A deterministic pseudo-random sequence of `column.update` requests on a
/// four-column screen with a split column and a second tab. After every
/// request: the tab set and pane membership are unchanged, at most one
/// column holds each edge, at least one column scrolls, and a replay of the
/// same key returns the same result and commits nothing.
#[test]
fn column_update_sequences_keep_layout_invariants() {
    let (mux, panes) = column_mux(4);
    mux.split(panes[1], SplitDir::Down, Some((38, 10))).unwrap();
    mux.new_tab(Some(panes[2]), None, Some((38, 22))).unwrap();
    let columns = column_ids(&mux);
    let membership = |mux: &Arc<Mux>| {
        mux.with_state(|state| {
            state.workspaces[0].screens[0]
                .layout_columns
                .iter()
                .map(|column| {
                    let mut tabs = column
                        .root
                        .pane_ids_vec()
                        .into_iter()
                        .flat_map(|pane| state.panes[&pane].tabs.clone())
                        .collect::<Vec<_>>();
                    tabs.sort_unstable();
                    tabs
                })
                .collect::<Vec<_>>()
        })
    };
    let tabs = membership(&mux);
    let mut seed = 0x0c01_u64;
    let mut next = |bound: usize| {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (seed >> 33) as usize % bound
    };
    for step in 0..60 {
        let mut fields = serde_json::json!({"column": columns[next(columns.len())]});
        match next(3) {
            0 => fields["sticky"] = serde_json::json!(false),
            1 => {
                fields["sticky"] = serde_json::json!(true);
                fields["edge"] = serde_json::json!(["left", "right"][next(2)]);
                fields["mode"] = serde_json::json!(["docked", "overlay"][next(2)]);
            }
            _ => fields["width"] = serde_json::json!(0.3 + 0.1 * next(5) as f64),
        }
        let key = format!("column-step-{step}");
        let response = update(&mux, fields.clone(), &key);
        assert!(response.is_ok(), "step {step}: {fields} -> {response:?}");
        assert_eq!(membership(&mux), tabs, "a column change never moves a tab");
        let flags = flags(&mux);
        assert!(flags.iter().any(Option::is_none), "at least one column scrolls");
        for edge in [StickyEdge::Left, StickyEdge::Right] {
            assert!(flags.iter().flatten().filter(|flag| flag.edge == edge).count() <= 1);
        }
        let committed = revision(&mux);
        let replay = update(&mux, fields, &key).unwrap();
        assert_eq!(replay["result"]["replayed"], true);
        assert_eq!(revision(&mux), committed, "a replay commits nothing");
    }
}

#[test]
fn column_update_enforces_revision_and_idempotency_conflicts() {
    let (mux, _) = column_mux(2);
    let columns = column_ids(&mux);
    let stale = update(
        &mux,
        serde_json::json!({"column": columns[1], "sticky": true, "expected_revision": "1"}),
        "column-stale",
    )
    .unwrap_err();
    assert_eq!(stale.code, "revision.conflict", "{stale:?}");
    assert_eq!(flags(&mux), vec![None, None]);

    update(&mux, serde_json::json!({"column": columns[1], "sticky": true}), "column-key").unwrap();
    let reused =
        update(&mux, serde_json::json!({"column": columns[1], "width": 0.4}), "column-key")
            .unwrap_err();
    assert_eq!(reused.code, "idempotency.conflict", "{reused:?}");
    assert!((widths(&mux)[1] - 0.4).abs() > 1e-3, "a conflicting reuse changes nothing");
}

#[test]
fn column_update_that_changes_nothing_records_no_undo_entry() {
    let (mux, _) = column_mux(2);
    let columns = column_ids(&mux);
    update(&mux, serde_json::json!({"column": columns[1], "sticky": true}), "column-first")
        .unwrap();
    let (undo, layout_revision) = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (screen.layout_undo.len(), screen.layout_revision)
    });
    update(&mux, serde_json::json!({"column": columns[1], "sticky": true}), "column-again")
        .unwrap();
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!((screen.layout_undo.len(), screen.layout_revision), (undo, layout_revision));
    });
}

#[test]
fn column_update_refuses_a_column_of_another_screen() {
    let (mux, _) = column_mux(2);
    let first_columns = column_ids(&mux);
    let second = mux.new_screen(None, Some((80, 22))).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    mux.new_pane_right(second_pane, 0.5, Some((38, 22))).unwrap();
    // The request names the first screen's column on the second screen.
    let other_screen = mux.with_state(|state| state.workspaces[0].screens[1].public_id.to_string());
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "column-other",
        "operation": "column.update",
        "params": {
            "machine": "current",
            "session": "current",
            "screen": other_screen,
            "column": first_columns[1],
            "sticky": true,
        },
        "idempotency_key": "column-other",
    });
    let error =
        crate::resource_router::handle_resource_message(&mux, &request.to_string()).unwrap_err();
    assert_eq!(error.code, "validation.invalid", "{error:?}");
    assert_eq!(flags(&mux), vec![None, None]);
}

#[test]
fn column_update_width_is_undone_by_undo_layout() {
    let (mux, panes) = column_mux(2);
    let columns = column_ids(&mux);
    let before = widths(&mux);
    update(&mux, serde_json::json!({"column": columns[1], "width": 0.3}), "column-narrow").unwrap();
    assert!((widths(&mux)[1] - 0.3).abs() < 1e-6);
    assert!(matches!(
        mux.undo_layout(panes[1], None, false).unwrap(),
        LayoutUndoResult::Undone { .. }
    ));
    assert_eq!(widths(&mux), before);
}

/// The flag and the width a column.update commits are in the screen's
/// durable viewport record and come back after a daemon restart.
#[test]
fn column_update_survives_a_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-column-update-restart-{}", WorkspacePublicId::random().unwrap()));
    let session = "column-update-restart";
    let (fixture_snapshot, fixture_topology) = resource_restore_fixture();
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("seed-column-update", "test").unwrap(),
                "session.restore_fixture",
                &serde_json::json!({"fixture":"nested-columns"}),
                None,
                Some(0),
                &resource_restore_patch(&fixture_snapshot, &fixture_topology),
                &serde_json::json!({"restored":true}),
                &serde_json::json!([{"event":"session.restored"}]),
            )
            .unwrap();
    }
    let open = || {
        Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            WorkspaceRegistry::open(&root, session).unwrap(),
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    };
    let mux = open();
    let columns = column_ids(&mux);
    update(
        &mux,
        serde_json::json!({"column": columns[1], "sticky": true, "edge": "left", "width": 0.5}),
        "column-restart",
    )
    .unwrap();
    mux.shutdown();
    drop(mux);

    let mux = open();
    assert_eq!(flags(&mux), vec![None, flag(StickyEdge::Left, StickyMode::Docked)]);
    assert!((widths(&mux)[1] - 0.5).abs() < 1e-6);
    mux.with_state(|state| {
        assert!(state.workspaces[0].screens[0].layout_column_projection_is_consistent());
    });
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
