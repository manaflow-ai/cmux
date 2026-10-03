//! Durability of sticky viewport columns (`sticky-columns-v1`): the flag is
//! part of the screen's durable viewport record, survives a daemon restart,
//! and older records without it still load.

use super::*;
use crate::model::{ColumnSticky, StickyEdge, StickyMode};

fn open_restart_mux(root: &Path, session: &str) -> Arc<Mux> {
    Mux::from_workspace_registry(
        session.into(),
        SurfaceOptions::default(),
        WorkspaceRegistry::open(root, session).unwrap(),
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

#[test]
fn sticky_column_persists_across_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-sticky-column-restart-{}", WorkspacePublicId::random().unwrap()));
    let session = "sticky-restart";
    let (fixture_snapshot, fixture_topology) = resource_restore_fixture();
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("seed-sticky-restart", "test").unwrap(),
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
    let expected = ColumnSticky { edge: StickyEdge::Left, mode: StickyMode::Overlay };

    let mux = open_restart_mux(&root, session);
    let pane = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns.len(), 2);
        assert!(screen.layout_columns.iter().all(|column| column.sticky.is_none()));
        screen.layout_columns[1].root.first_visible_pane()
    });
    let outcome = mux.set_column_sticky(pane, Some(expected), None).unwrap();
    assert_eq!(outcome.sticky, Some(expected));
    mux.shutdown();
    drop(mux);

    {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let topology = registry.resource_topology_snapshot().unwrap();
        let screen = topology
            .screens
            .iter()
            .find(|screen| screen.public_id == restore_screen_id(1))
            .unwrap();
        assert_eq!(screen.viewport.columns[0].sticky, None);
        assert_eq!(screen.viewport.columns[1].sticky, Some(expected));
    }

    let mux = open_restart_mux(&root, session);
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(screen.layout_column_projection_is_consistent());
        assert_eq!(screen.layout_columns[0].sticky, None);
        assert_eq!(screen.layout_columns[1].sticky, Some(expected));
        assert!(screen.layout_columns[1].root.contains(pane));
    });
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn sticky_column_registry_record_is_additive() {
    let old = serde_json::json!({
        "id": "split_00000000000000000000000000000003",
        "width": 0.5,
        "layout": {"kind": "leaf", "pane": "pane_00000000000000000000000000000001"},
        "auto_layout": null,
    });
    let column: RegistryViewportColumn = serde_json::from_value(old.clone()).unwrap();
    assert_eq!(column.sticky, None);
    assert_eq!(serde_json::to_value(&column).unwrap(), old, "an unset flag is omitted");

    let mut with_sticky = old;
    with_sticky["sticky"] = serde_json::json!({"edge": "right", "mode": "docked"});
    let column: RegistryViewportColumn = serde_json::from_value(with_sticky.clone()).unwrap();
    assert_eq!(
        column.sticky,
        Some(ColumnSticky { edge: StickyEdge::Right, mode: StickyMode::Docked })
    );
    assert_eq!(serde_json::to_value(&column).unwrap(), with_sticky);
}

/// Closing the last scrolling column clears the remaining flags, and the
/// cleared flags are what the registry holds after a restart.
#[test]
fn sticky_column_flags_cleared_by_a_close_stay_cleared_after_restart() {
    let root = std::env::temp_dir()
        .join(format!("cmux-sticky-close-restart-{}", WorkspacePublicId::random().unwrap()));
    let session = "sticky-close-restart";
    let (fixture_snapshot, fixture_topology) = resource_restore_fixture();
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("seed-sticky-close", "test").unwrap(),
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
    let left = ColumnSticky { edge: StickyEdge::Left, mode: StickyMode::Docked };
    let right = ColumnSticky { edge: StickyEdge::Right, mode: StickyMode::Docked };

    let mux = open_restart_mux(&root, session);
    // Three columns: the fixture's two plus a new one holding a second tab
    // of pane one (a pane's only tab cannot be dragged out).
    let (from, middle) = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        let from = state.resource_indexes.panes[&restore_pane_id(1)];
        (from, screen.layout_columns[1].root.first_visible_pane())
    });
    let moved =
        mux.new_browser_tab("about:blank#third".into(), Some(from), Some((80, 24))).unwrap();
    mux.move_tab_to_column(moved.id, from, None, None, None, None).unwrap();
    let (first, last) = mux.with_state(|state| {
        let columns = &state.workspaces[0].screens[0].layout_columns;
        assert_eq!(columns.len(), 3);
        (columns[0].root.first_visible_pane(), columns[2].root.first_visible_pane())
    });
    mux.set_column_sticky(first, Some(left), None).unwrap();
    mux.set_column_sticky(last, Some(right), None).unwrap();
    assert!(mux.close_pane(middle).unwrap());
    mux.with_state(|state| {
        let columns = &state.workspaces[0].screens[0].layout_columns;
        assert_eq!(columns.len(), 2);
        assert!(columns.iter().all(|column| column.sticky.is_none()));
    });
    mux.shutdown();
    drop(mux);

    {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let topology = registry.resource_topology_snapshot().unwrap();
        let screen = topology
            .screens
            .iter()
            .find(|screen| screen.public_id == restore_screen_id(1))
            .unwrap();
        assert_eq!(screen.viewport.columns.len(), 2);
        assert!(screen.viewport.columns.iter().all(|column| column.sticky.is_none()));
    }
    let mux = open_restart_mux(&root, session);
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(screen.layout_column_projection_is_consistent());
        assert!(screen.layout_columns.iter().all(|column| column.sticky.is_none()));
    });
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// `edge-docks-v1`: a top or bottom dock survives a restart through
/// `resource_column_docks`, never through `viewport_json`.
#[test]
fn edge_dock_persists_across_restart_outside_the_viewport_record() {
    let root = std::env::temp_dir()
        .join(format!("cmux-edge-dock-restart-{}", WorkspacePublicId::random().unwrap()));
    let session = "edge-dock-restart";
    let (fixture_snapshot, fixture_topology) = resource_restore_fixture();
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("seed-edge-dock-restart", "test").unwrap(),
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
    let bottom = ColumnSticky { edge: StickyEdge::Bottom, mode: StickyMode::Overlay };
    let mux = open_restart_mux(&root, session);
    let pane = mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns[1].root.first_visible_pane()
    });
    assert_eq!(mux.set_column_sticky(pane, Some(bottom), None).unwrap().sticky, Some(bottom));
    mux.shutdown();
    drop(mux);

    {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let topology = registry.resource_topology_snapshot().unwrap();
        let screen = topology
            .screens
            .iter()
            .find(|screen| screen.public_id == restore_screen_id(1))
            .unwrap();
        assert_eq!(screen.viewport.columns[1].sticky, Some(bottom));
        let stored = serde_json::to_value(&screen.viewport).unwrap();
        assert!(stored["columns"][1].get("sticky").is_none(), "a band never enters viewport_json");
    }

    let mux = open_restart_mux(&root, session);
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns[1].sticky, Some(bottom));
        assert!(screen.layout_columns[1].root.contains(pane));
    });
    // Unpinning removes the row: the next restart reads an ordinary column.
    mux.set_column_sticky(pane, None, None).unwrap();
    mux.shutdown();
    drop(mux);
    let mux = open_restart_mux(&root, session);
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[0].layout_columns[1].sticky, None)
    });
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn edge_dock_is_never_serialized_into_the_viewport_record() {
    let mut column: RegistryViewportColumn = serde_json::from_value(serde_json::json!({
        "id": "split_00000000000000000000000000000003",
        "width": 0.5,
        "layout": {"kind": "leaf", "pane": "pane_00000000000000000000000000000001"},
        "auto_layout": null,
    }))
    .unwrap();
    for edge in [StickyEdge::Top, StickyEdge::Bottom] {
        column.sticky = Some(ColumnSticky { edge, mode: StickyMode::Docked });
        assert!(serde_json::to_value(&column).unwrap().get("sticky").is_none());
    }
}
