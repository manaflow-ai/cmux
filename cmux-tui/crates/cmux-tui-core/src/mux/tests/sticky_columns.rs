//! Durability of sticky viewport columns (`sticky-columns-v1`): the flag is
//! part of the screen's durable viewport record, survives a daemon restart,
//! and older records without it still load.

use super::*;
use crate::model::{ColumnSticky, StickyEdge, StickyMode};

fn open_restart_mux(root: &std::path::Path, session: &str) -> Arc<Mux> {
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
