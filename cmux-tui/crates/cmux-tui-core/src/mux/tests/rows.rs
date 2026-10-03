//! Durability of column rows (`rows-v1`): rows survive a daemon restart
//! through `resource_screen_rows`, never through `viewport_json`, and load
//! drops row records whose stored chain no longer matches them.

use super::*;
use crate::workspace_registry::RegistryRow;
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

/// Seeds the restore fixture with its first screen changed by `edit`.
fn seed(name: &str, edit: impl FnOnce(&mut RegistryScreen)) -> (PathBuf, String) {
    let root = std::env::temp_dir()
        .join(format!("cmux-rows-{name}-{}", WorkspacePublicId::random().unwrap()));
    let session = format!("rows-{name}");
    let (fixture_snapshot, mut fixture_topology) = resource_restore_fixture();
    let screen = fixture_topology
        .screens
        .iter_mut()
        .find(|screen| screen.public_id == restore_screen_id(1))
        .unwrap();
    edit(screen);
    let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new(format!("seed-rows-{name}"), "test").unwrap(),
            "session.restore_fixture",
            &serde_json::json!({"fixture":"rows"}),
            None,
            Some(0),
            &resource_restore_patch(&fixture_snapshot, &fixture_topology),
            &serde_json::json!({"restored":true}),
            &serde_json::json!([{"event":"session.restored"}]),
        )
        .unwrap();
    (root, session)
}

fn row(id: u128, height: u16) -> RegistryRow {
    RegistryRow { id: restore_split_id(id), height }
}

fn first_column_rows(mux: &Mux) -> Vec<(SplitId, u16)> {
    mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns[0]
            .rows
            .iter()
            .map(|row| (row.id, row.height))
            .collect()
    })
}

fn stored_screen(root: &Path, session: &str) -> RegistryScreen {
    let registry = WorkspaceRegistry::open(root, session).unwrap();
    let topology = registry.resource_topology_snapshot().unwrap();
    topology.screens.into_iter().find(|screen| screen.public_id == restore_screen_id(1)).unwrap()
}

/// The fixture's first column is `Stack(one, two)` over `three`, split down
/// by split 1: the compat chain of two rows whose second row id is split 1.
#[test]
fn rows_persist_across_restart_outside_the_viewport_record() {
    let (root, session) = seed("restart", |screen| {
        screen.viewport.columns[0].rows = vec![row(9, 700), row(1, 300)];
    });
    let mux = open_restart_mux(&root, &session);
    let rows = first_column_rows(&mux);
    assert_eq!(rows.iter().map(|(_, height)| *height).collect::<Vec<_>>(), vec![700, 300]);
    let column = mux.with_state(|state| state.workspaces[0].screens[0].layout_columns[0].id);
    let outcome =
        mux.set_row_heights(column, &[(rows[0].0, 400), (rows[1].0, 600)], true, None).unwrap();
    assert!(outcome.changed);
    mux.shutdown();
    drop(mux);

    let screen = stored_screen(&root, &session);
    assert_eq!(screen.viewport.columns[0].rows, vec![row(9, 400), row(1, 600)]);
    let stored = serde_json::to_value(&screen.viewport).unwrap();
    assert!(stored["columns"][0].get("rows").is_none(), "rows never enter viewport_json");

    let mux = open_restart_mux(&root, &session);
    let heights = first_column_rows(&mux).iter().map(|(_, height)| *height).collect::<Vec<_>>();
    assert_eq!(heights, vec![400, 600]);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A build without `rows-v1` may rewrite the screen; records that no longer
/// match the stored chain are dropped and the column loads as one row.
#[test]
fn rows_whose_chain_no_longer_matches_are_dropped_at_load() {
    let (root, session) = seed("stale", |screen| {
        screen.viewport.columns[0].rows = vec![row(9, 600), row(7, 400)];
    });
    let mux = open_restart_mux(&root, &session);
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns.len(), 2);
        assert!(screen.layout_columns[0].rows.is_empty());
    });
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// One column with two rows is stored as a plain split tree (what a build
/// without `rows-v1` reads), restored as columns mode with one column, and
/// gets a fresh column id when a second column joins it.
#[test]
fn a_lone_column_of_rows_restores_and_takes_a_fresh_id_for_a_second_column() {
    let (root, session) = seed("lone", |screen| {
        let RegistryLayoutNode::Split { first, .. } = &screen.layout else { unreachable!() };
        let RegistryLayoutNode::Split { first: column, second: three, .. } = &**first else {
            unreachable!()
        };
        let four = RegistryLayoutNode::Leaf { pane: restore_pane_id(4) };
        let layout = RegistryLayoutNode::Split {
            split: restore_split_id(1),
            direction: "down".into(),
            ratio: 0.6,
            first: column.clone(),
            second: Box::new(RegistryLayoutNode::Split {
                split: restore_split_id(2),
                direction: "right".into(),
                ratio: 0.5,
                first: three.clone(),
                second: Box::new(four),
            }),
        };
        let lone =
            RegistryViewportColumn::new(restore_split_id(3), 1.0, layout.clone(), None, None)
                .with_rows(vec![row(9, 1000), row(1, 500)]);
        screen.layout = layout;
        screen.auto_layout = None;
        screen.viewport = RegistryViewport { base_width: Some(1.0), columns: vec![lone] };
    });
    let screen = stored_screen(&root, &session);
    assert_eq!(screen.viewport.columns.len(), 1, "the lone column is overlaid from its rows");
    assert_eq!(screen.viewport.columns[0].rows, vec![row(9, 1000), row(1, 500)]);

    let mux = open_restart_mux(&root, &session);
    let (lone_id, pane) = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns.len(), 1, "one column with rows stays in columns mode");
        assert!(screen.layout_column_projection_is_consistent());
        (screen.layout_columns[0].id, screen.layout_columns[0].root.first_visible_pane())
    });
    assert_eq!(first_column_rows(&mux).len(), 2);
    let created = mux.new_pane_right(pane, 0.5, Some((38, 22))).unwrap();
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns.len(), 2);
        assert_ne!(screen.layout_columns[0].id, lone_id, "a lone column has no durable id");
        assert_eq!(screen.layout_columns[0].rows.len(), 2);
    });
    drop(created);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// Closing the second column leaves one column of rows; a new column after
/// that must not reuse the lone column's tombstoned split identity.
#[test]
fn a_column_of_rows_left_alone_can_take_a_second_column_again() {
    let (root, session) = seed("alone", |screen| {
        screen.viewport.columns[0].rows = vec![row(9, 700), row(1, 300)];
    });
    let mux = open_restart_mux(&root, &session);
    let (second, first) = mux.with_state(|state| {
        let columns = &state.workspaces[0].screens[0].layout_columns;
        (columns[1].root.first_visible_pane(), columns[0].root.first_visible_pane())
    });
    assert!(mux.close_pane(second).unwrap());
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(screen.has_lone_row_column(), "{:?}", screen.layout_columns);
    });
    let created = mux.new_pane_right(first, 0.5, Some((38, 22))).unwrap();
    mux.with_state(|state| assert_eq!(state.workspaces[0].screens[0].layout_columns.len(), 2));
    drop(created);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
