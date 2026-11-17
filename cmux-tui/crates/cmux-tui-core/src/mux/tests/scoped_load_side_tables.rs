//! The scoped loads of the stored topology and the screen side tables
//! (`resource_column_docks`, `resource_screen_rows`, `resource_lone_docks`).
//! A load of some screens gives each of them the value the full load gives,
//! and it reads no side table row of a screen it does not load.

use super::*;
use crate::model::{ColumnDock, DockEdge, DockMode, DockRole};
use crate::workspace_registry::RegistryRow;
use std::path::PathBuf;

/// A registry of its own that holds the restore fixture, changed by `edit`,
/// with the first screen as the active screen of the first workspace. The
/// first screen has two columns, the second screen is one pane, and the
/// second workspace has no screen and is the active one.
fn seed(
    name: &str,
    edit: impl FnOnce(&mut ResourceTopologySnapshot),
) -> (WorkspaceRegistry, PathBuf, RegistrySnapshot) {
    let root = std::env::temp_dir()
        .join(format!("cmux-scoped-side-tables-{name}-{}", WorkspacePublicId::random().unwrap()));
    let session = format!("scoped-side-tables-{name}");
    let (fixture_snapshot, mut fixture_topology) = resource_restore_fixture();
    let first_workspace = restore_workspace_id(1);
    for (workspace, screen) in &mut fixture_topology.active_screens {
        if *workspace == first_workspace {
            *screen = Some(restore_screen_id(1));
        }
    }
    edit(&mut fixture_topology);
    let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon(format!("seed-scoped-side-tables-{name}"), "test").unwrap(),
            "session.restore_fixture",
            &serde_json::json!({"fixture":"scoped-side-tables"}),
            None,
            Some(0),
            &resource_restore_patch(&fixture_snapshot, &fixture_topology),
            &serde_json::json!({"restored":true}),
            &serde_json::json!([{"event":"session.restored"}]),
        )
        .unwrap();
    (registry, root, fixture_snapshot)
}

fn bottom_dock() -> ColumnDock {
    ColumnDock::new(DockEdge::Bottom, DockMode::Overlay)
}

/// One or more rows in each of the 3 side tables, over the 2 screens: 2 rows
/// on the first column of the first screen, a bottom dock on its second
/// column, and the second screen as one pinned column.
fn side_tables(topology: &mut ResourceTopologySnapshot) {
    for screen in &mut topology.screens {
        if screen.public_id == restore_screen_id(1) {
            screen.viewport.columns[0].rows = vec![
                RegistryRow { id: restore_split_id(9), height: 700 },
                RegistryRow { id: restore_split_id(1), height: 300 },
            ];
            screen.viewport.columns[1].dock = Some(bottom_dock());
        } else {
            let pinned = ColumnDock {
                role: Some(DockRole::AgentChat),
                pinned: true,
                ..ColumnDock::new(DockEdge::Left, DockMode::Docked)
            };
            let column = RegistryViewportColumn::new(
                restore_split_id(8),
                0.4,
                screen.layout.clone(),
                None,
                Some(pinned),
            );
            screen.zoomed_pane = None;
            screen.viewport = RegistryViewport { base_width: Some(0.4), columns: vec![column] };
        }
    }
}

/// [`side_tables`], with the second screen in the second workspace as its
/// active screen. Each workspace then has one screen with side table rows:
/// the first has the rows and the bottom dock, the second has the lone
/// pinned column.
fn side_tables_in_two_workspaces(topology: &mut ResourceTopologySnapshot) {
    side_tables(topology);
    let second_workspace = restore_workspace_id(2);
    for screen in &mut topology.screens {
        if screen.public_id == restore_screen_id(2) {
            screen.workspace_id = second_workspace.clone();
            screen.position = 0;
        }
    }
    for (workspace, active) in &mut topology.active_screens {
        if *workspace == second_workspace {
            *active = Some(restore_screen_id(2));
        }
    }
}

/// The screen `id` of the fixture as `topology` holds it.
fn screen(topology: &ResourceTopologySnapshot, id: u128) -> &RegistryScreen {
    topology
        .screens
        .iter()
        .find(|screen| screen.public_id == restore_screen_id(id))
        .unwrap_or_else(|| panic!("the load holds no screen {id}"))
}

/// What `load` gives, and how many side table rows it read for a screen it
/// does not load.
fn rows_of_other_screens<T>(load: impl FnOnce() -> T) -> (T, u64) {
    let before = WorkspaceRegistry::other_screen_side_rows_read_for_test();
    let loaded = load();
    (loaded, WorkspaceRegistry::other_screen_side_rows_read_for_test() - before)
}

/// The counter's own check. The full load loads each screen, so it counts no
/// row of the fixture; it counts a row that names no stored screen.
#[test]
fn the_full_load_counts_only_a_side_table_row_of_no_stored_screen() {
    let (registry, root, _) = seed("full-load", side_tables);
    let (_, rows) = rows_of_other_screens(|| registry.resource_topology_snapshot().unwrap());
    assert_eq!(rows, 0, "the full load loads each screen that a side table row names");
    registry
        .execute_sql_for_test(&format!(
            "INSERT INTO resource_column_docks(screen_id, column_id, edge, mode)
             VALUES('{}', '{}', '{}', '{}')",
            restore_screen_id(9),
            restore_split_id(7),
            DockEdge::Top.as_str(),
            DockMode::Docked.as_str()
        ))
        .unwrap();
    let (_, rows) = rows_of_other_screens(|| registry.resource_topology_snapshot().unwrap());
    assert_eq!(rows, 1, "the counter counts the one row of a screen that the load does not hold");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// The subtree of a workspace with no screen needs no side table row.
#[test]
fn a_workspace_subtree_load_reads_no_side_table_row_of_another_screen() {
    let (registry, root, _) = seed("subtree-rows", side_tables);
    let empty_workspace = restore_workspace_id(2);
    let (topology, rows) = rows_of_other_screens(|| {
        registry.resource_topology_scoped(std::slice::from_ref(&empty_workspace)).unwrap()
    });
    assert!(topology.screens.is_empty(), "the fixture is wrong: the workspace has a screen");
    assert_eq!(rows, 0, "the load of a workspace with no screen read side table rows");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// The subtree of a workspace that has a screen holds that screen with the
/// value of the full load, and the load reads no side table row of the other
/// workspace's screen. The test loads each of the 2 workspaces alone, so each
/// of the 3 tables holds a row that one of the 2 loads must not read: the
/// lone pinned column for the first workspace, the 2 rows and the bottom dock
/// for the second.
#[test]
fn a_workspace_subtree_load_reads_the_side_rows_of_its_own_screen_only() {
    let (registry, root, _) = seed("subtree-own-rows", side_tables_in_two_workspaces);
    let full = registry.resource_topology_snapshot().unwrap();
    let mut rows_of_the_other_workspace = Vec::new();
    for id in [1, 2] {
        let workspace = restore_workspace_id(id);
        let (subtree, rows) = rows_of_other_screens(|| {
            registry.resource_topology_scoped(std::slice::from_ref(&workspace)).unwrap()
        });
        assert_eq!(
            subtree.screens.iter().map(|screen| screen.public_id.clone()).collect::<Vec<_>>(),
            vec![restore_screen_id(id)],
            "the fixture is wrong: the subtree of workspace {id} holds its one screen"
        );
        assert_eq!(
            screen(&subtree, id),
            screen(&full, id),
            "the subtree of workspace {id}: the screen with the value of the full load"
        );
        rows_of_the_other_workspace.push(rows);
    }
    assert_eq!(
        rows_of_the_other_workspace,
        vec![0, 0],
        "a workspace's subtree load read rows of the other workspace's screen (first, second)"
    );
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// A workspace commit that closes no workspace and keeps the focus loads no
/// screen, so it needs no side table row.
#[test]
fn a_workspace_commit_that_closes_nothing_reads_no_side_table_row() {
    let (registry, root, snapshot) = seed("commit-rows", side_tables);
    let active = restore_workspace_id(2);
    let (topology, rows) = rows_of_other_screens(|| {
        registry
            .resource_topology_for_workspace_commit(&snapshot.workspaces, Some(&active))
            .unwrap()
    });
    assert!(topology.screens.is_empty(), "the fixture is wrong: the commit loaded a screen");
    assert_eq!(rows, 0, "a workspace commit that closes no workspace read side table rows");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// A workspace commit that moves the focus to the first workspace loads that
/// workspace's active screen, and no side table row of the other screen.
#[test]
fn a_workspace_commit_that_moves_the_focus_reads_the_side_rows_of_its_screen_only() {
    let (registry, root, snapshot) = seed("focus-rows", side_tables);
    let focused = restore_workspace_id(1);
    let (topology, rows) = rows_of_other_screens(|| {
        registry
            .resource_topology_for_workspace_commit(&snapshot.workspaces, Some(&focused))
            .unwrap()
    });
    assert_eq!(
        topology.screens.iter().map(|screen| screen.public_id.clone()).collect::<Vec<_>>(),
        vec![restore_screen_id(1)],
        "the fixture is wrong: the commit loads the first screen only"
    );
    assert_eq!(rows, 0, "a workspace commit that moves the focus read rows of another screen");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// Each scoped load gives a screen the value the full load gives it: the
/// rows, the bottom dock and the lone pinned column.
#[test]
fn a_scoped_load_gives_each_screen_the_value_of_the_full_load() {
    let (registry, root, snapshot) = seed("equal-values", side_tables);
    let full = registry.resource_topology_snapshot().unwrap();
    let (first, second) = (screen(&full, 1), screen(&full, 2));
    assert_eq!(first.viewport.columns[0].rows.len(), 2, "the full load overlays the stored rows");
    assert_eq!(
        first.viewport.columns[1].dock,
        Some(bottom_dock()),
        "the full load overlays the stored bottom dock"
    );
    assert!(
        second.viewport.has_lone_pinned_column(),
        "the full load overlays the stored lone pinned column"
    );

    let first_workspace = restore_workspace_id(1);
    let subtree =
        registry.resource_topology_scoped(std::slice::from_ref(&first_workspace)).unwrap();
    assert_eq!(screen(&subtree, 1), first, "the workspace's subtree: the screen with rows");
    assert_eq!(screen(&subtree, 2), second, "the workspace's subtree: the lone pinned column");
    let commit = registry
        .resource_topology_for_workspace_commit(&snapshot.workspaces, Some(&first_workspace))
        .unwrap();
    assert_eq!(screen(&commit, 1), first, "the commit's focus screen: the screen with rows");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// A file with 2 dock rows of one edge for one screen: the store writes one
/// row for an edge, another build or a damaged file can leave two. The first
/// row a load reads takes the edge. The rows are written so that the order
/// of the writes and the order of the column ids name different columns, and
/// each scoped load must give the edge to the column the full load gives it
/// to.
#[test]
fn two_stored_docks_of_one_edge_go_to_the_same_column_in_each_load() {
    let (registry, root, snapshot) = seed("one-edge-twice", |_| {});
    let (first_column, second_column) = (restore_split_id(3), restore_split_id(2));
    assert!(
        second_column.as_str() < first_column.as_str(),
        "the fixture is wrong: the column written first must have the greater id"
    );
    for column in [&first_column, &second_column] {
        registry
            .execute_sql_for_test(&format!(
                "INSERT INTO resource_column_docks(screen_id, column_id, edge, mode)
                 VALUES('{}', '{}', '{}', '{}')",
                restore_screen_id(1),
                column,
                DockEdge::Top.as_str(),
                DockMode::Docked.as_str()
            ))
            .unwrap();
    }
    let docks = |topology: &ResourceTopologySnapshot| {
        screen(topology, 1).viewport.columns.iter().map(|column| column.dock).collect::<Vec<_>>()
    };
    let full = docks(&registry.resource_topology_snapshot().unwrap());
    assert_eq!(
        full,
        vec![Some(ColumnDock::new(DockEdge::Top, DockMode::Docked)), None],
        "the fixture is wrong: the full load gives the edge to the column written first"
    );

    let first_workspace = restore_workspace_id(1);
    let subtree =
        registry.resource_topology_scoped(std::slice::from_ref(&first_workspace)).unwrap();
    assert_eq!(docks(&subtree), full, "the workspace's subtree gives the edge to another column");
    let commit = registry
        .resource_topology_for_workspace_commit(&snapshot.workspaces, Some(&first_workspace))
        .unwrap();
    assert_eq!(docks(&commit), full, "the commit's focus screen gives the edge to another column");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}
