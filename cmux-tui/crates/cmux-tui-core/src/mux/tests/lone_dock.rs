//! Durability of a lone pinned column (`pinned-dock-alone-v1`, Home's dock
//! with nothing beside it): it survives a restart through
//! `resource_lone_docks`, never through `viewport_json`, so a build without
//! the capability (which refuses a one-column viewport at open) still opens
//! the registry and reads the screen as a plain tree.

use super::*;
use crate::model::{ColumnDock, DockEdge, DockMode, DockRole};
use std::path::PathBuf;

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

fn home_dock() -> ColumnDock {
    ColumnDock {
        role: Some(DockRole::AgentChat),
        pinned: true,
        ..ColumnDock::new(DockEdge::Left, DockMode::Docked)
    }
}

/// Seeds the restore fixture with its first screen as one pinned column at
/// width 0.4 holding the whole screen.
fn seed(name: &str) -> (PathBuf, String) {
    let root = std::env::temp_dir()
        .join(format!("cmux-lone-dock-{name}-{}", WorkspacePublicId::random().unwrap()));
    let session = format!("lone-dock-{name}");
    let (fixture_snapshot, mut fixture_topology) = resource_restore_fixture();
    let screen = fixture_topology
        .screens
        .iter_mut()
        .find(|screen| screen.public_id == restore_screen_id(1))
        .unwrap();
    let column = RegistryViewportColumn::new(
        restore_split_id(3),
        0.4,
        screen.layout.clone(),
        None,
        Some(home_dock()),
    );
    screen.zoomed_pane = None;
    screen.viewport = RegistryViewport { base_width: Some(0.4), columns: vec![column] };
    let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon(format!("seed-lone-dock-{name}"), "test").unwrap(),
            "session.restore_fixture",
            &serde_json::json!({"fixture":"lone-dock"}),
            None,
            Some(0),
            &resource_restore_patch(&fixture_snapshot, &fixture_topology),
            &serde_json::json!({"restored":true}),
            &serde_json::json!([{"event":"session.restored"}]),
        )
        .unwrap();
    (root, session)
}

fn stored_viewport_json(root: &Path, session: &str) -> RegistryViewport {
    let registry = WorkspaceRegistry::open(root, session).unwrap();
    let text = registry
        .query_text_for_test(&format!(
            "SELECT viewport_json FROM resource_screens WHERE public_id = '{}'",
            restore_screen_id(1)
        ))
        .unwrap();
    serde_json::from_str(&text).unwrap()
}

fn stored_screen(root: &Path, session: &str) -> RegistryScreen {
    let topology =
        WorkspaceRegistry::open(root, session).unwrap().resource_topology_snapshot().unwrap();
    topology.screens.into_iter().find(|screen| screen.public_id == restore_screen_id(1)).unwrap()
}

/// `(public id, width, dock)` of each column of the restored first screen.
fn columns(mux: &Mux) -> Vec<(SplitPublicId, f32, Option<ColumnDock>)> {
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(screen.layout_column_projection_is_consistent());
        screen
            .layout_columns
            .iter()
            .map(|column| {
                (state.resource_indexes.split_ids[&column.id].clone(), column.width, column.dock)
            })
            .collect()
    })
}

/// The lone dock is stored as no viewport (what a build without the
/// capability validates and reads as a tree), restored with its id, width
/// and pin, and its id comes back to life when a column opens beside it.
#[test]
fn a_lone_pinned_column_survives_a_restart_outside_the_viewport_record() {
    let (root, session) = seed("restart");
    assert_eq!(
        stored_viewport_json(&root, &session),
        RegistryViewport::default(),
        "an older build reads a plain tree and opens"
    );
    let screen = stored_screen(&root, &session);
    assert_eq!(screen.viewport.columns.len(), 1, "the lone dock is overlaid at load");
    assert_eq!(screen.viewport.columns[0].dock, Some(home_dock()));

    let mux = open_restart_mux(&root, &session);
    assert_eq!(columns(&mux), vec![(restore_split_id(3), 0.4, Some(home_dock()))]);
    let pane = mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns[0].root.first_visible_pane()
    });
    let created = mux.new_pane_right(pane, 0.5, Some((38, 22))).unwrap();
    let after = columns(&mux);
    assert_eq!(after.len(), 2);
    assert_eq!(after[0], (restore_split_id(3), 0.4, Some(home_dock())), "the dock keeps its id");
    drop(created);
    mux.shutdown();
    drop(mux);

    assert_eq!(stored_viewport_json(&root, &session).columns.len(), 2);
    let registry = WorkspaceRegistry::open(&root, &session).unwrap();
    assert_eq!(
        registry.split_identity(restore_split_id(3).as_str()).unwrap(),
        Some(("split".into(), true)),
        "the parked column id is live again"
    );
    let left = registry.query_text_for_test("SELECT COUNT(*) || '' FROM resource_lone_docks");
    assert_eq!(left.unwrap(), "0", "the record goes once the dock has a neighbour");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// A build without the capability may rewrite the screen; a record whose
/// column no longer matches the screen is dropped and the screen loads as a
/// tree.
#[test]
fn a_lone_dock_record_that_no_longer_matches_the_screen_is_dropped() {
    let (root, session) = seed("stale");
    let registry = WorkspaceRegistry::open(&root, &session).unwrap();
    registry
        .execute_sql_for_test(&format!(
            "UPDATE resource_lone_docks SET column_json = replace(column_json, '{}', '{}')",
            restore_pane_id(1),
            restore_pane_id(9)
        ))
        .unwrap();
    drop(registry);
    assert!(stored_screen(&root, &session).viewport.columns.is_empty());
    let mux = open_restart_mux(&root, &session);
    assert!(columns(&mux).is_empty(), "the screen loads as a plain tree");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
