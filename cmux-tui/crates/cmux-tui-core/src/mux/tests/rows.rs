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
    stored_screen_in(&WorkspaceRegistry::open(root, session).unwrap())
}

fn stored_screen_in(registry: &WorkspaceRegistry) -> RegistryScreen {
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

/// The public id and width of the first column of the restored screen.
fn first_column(mux: &Mux) -> (SplitPublicId, f32) {
    mux.with_state(|state| {
        let column = &state.workspaces[0].screens[0].layout_columns[0];
        (state.resource_indexes.split_ids[&column.id].clone(), column.width)
    })
}

/// `(kind, live)` of a public id in the identity ledger.
fn identity(root: &Path, session: &str, id: &SplitPublicId) -> Option<(String, bool)> {
    WorkspaceRegistry::open(root, session).unwrap().split_identity(id.as_str()).unwrap()
}

/// One column with two rows is stored as a plain split tree (what a build
/// without `rows-v1` reads) and restored as columns mode with one column that
/// fills the screen width. Its id survives the restart and stays when a
/// second column joins it.
#[test]
fn a_lone_column_of_rows_keeps_its_id_when_a_second_column_joins() {
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
            RegistryViewportColumn::new(restore_split_id(3), 0.7, layout.clone(), None, None)
                .with_rows(vec![row(9, 1000), row(1, 500)]);
        screen.layout = layout;
        screen.auto_layout = None;
        screen.viewport = RegistryViewport { base_width: Some(0.7), columns: vec![lone] };
    });
    let screen = stored_screen(&root, &session);
    assert_eq!(screen.viewport.columns.len(), 1, "the lone column is overlaid from its rows");
    assert_eq!(screen.viewport.columns[0].id, restore_split_id(3));
    assert_eq!(screen.viewport.columns[0].width, 1.0);
    assert_eq!(screen.viewport.columns[0].rows, vec![row(9, 1000), row(1, 500)]);

    let mux = open_restart_mux(&root, &session);
    let (lone_id, pane) = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns.len(), 1, "one column with rows stays in columns mode");
        assert!(screen.layout_column_projection_is_consistent());
        (screen.layout_columns[0].id, screen.layout_columns[0].root.first_visible_pane())
    });
    assert_eq!(first_column(&mux), (restore_split_id(3), 1.0));
    assert_eq!(first_column_rows(&mux).len(), 2);
    let created = mux.new_pane_right(pane, 0.5, Some((38, 22))).unwrap();
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert_eq!(screen.layout_columns.len(), 2);
        assert_eq!(screen.layout_columns[0].id, lone_id, "a second column keeps the column id");
        assert_eq!(screen.layout_columns[0].rows.len(), 2);
    });
    assert_eq!(first_column(&mux), (restore_split_id(3), 1.0));
    drop(created);
    mux.shutdown();
    drop(mux);

    let screen = stored_screen(&root, &session);
    assert_eq!(screen.viewport.columns.len(), 2);
    assert_eq!(screen.viewport.columns[0].id, restore_split_id(3));
    assert_eq!(screen.viewport.columns[0].width, 1.0);
    assert_eq!(identity(&root, &session, &restore_split_id(3)), Some(("split".into(), true)));
    std::fs::remove_dir_all(root).unwrap();
}

/// Closing the second column leaves one column of rows, which fills the
/// screen width again. That column keeps its id across a restart and when a
/// new column joins it again: its parked split identity comes back to life,
/// it is never replaced.
#[test]
fn a_column_of_rows_left_alone_keeps_its_id_and_fills_the_width() {
    let (root, session) = seed("alone", |screen| {
        screen.viewport.columns[0].rows = vec![row(9, 700), row(1, 300)];
    });
    let mux = open_restart_mux(&root, &session);
    let second = mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns[1].root.first_visible_pane()
    });
    assert_eq!(first_column(&mux), (restore_split_id(3), 0.8));
    assert!(mux.close_pane(second).unwrap());
    mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        assert!(screen.has_lone_row_column(), "{:?}", screen.layout_columns);
    });
    assert_eq!(
        first_column(&mux),
        (restore_split_id(3), 1.0),
        "the lone column keeps its id and fills the width"
    );
    mux.shutdown();
    drop(mux);

    let screen = stored_screen(&root, &session);
    assert_eq!(screen.viewport.columns.len(), 1);
    assert_eq!(
        (screen.viewport.columns[0].id.clone(), screen.viewport.columns[0].width),
        (restore_split_id(3), 1.0)
    );
    let mux = open_restart_mux(&root, &session);
    assert_eq!(first_column(&mux), (restore_split_id(3), 1.0));
    let first = mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns[0].root.first_visible_pane()
    });
    let created = mux.new_pane_right(first, 0.5, Some((38, 22))).unwrap();
    mux.with_state(|state| assert_eq!(state.workspaces[0].screens[0].layout_columns.len(), 2));
    assert_eq!(first_column(&mux), (restore_split_id(3), 1.0));
    drop(created);
    mux.shutdown();
    drop(mux);

    let screen = stored_screen(&root, &session);
    assert_eq!(screen.viewport.columns[0].id, restore_split_id(3));
    assert_eq!(identity(&root, &session, &restore_split_id(3)), Some(("split".into(), true)));
    std::fs::remove_dir_all(root).unwrap();
}

/// Row 1's id is in no tree, yet it is registered as a split identity like
/// the ids of rows 2..n (R4b: never reused). It stays out of the live split
/// set, which a build without `rows-v1` checks against the stored layout.
#[test]
fn the_first_row_id_is_a_registered_split_identity() {
    let (root, session) = seed("row-one", |screen| {
        screen.viewport.columns[0].rows = vec![row(9, 700), row(1, 300)];
    });
    assert_eq!(identity(&root, &session, &restore_split_id(9)), Some(("split".into(), false)));
    assert_eq!(identity(&root, &session, &restore_split_id(1)), Some(("split".into(), true)));

    // A row 1 allocated by `new-row` is registered too.
    let mux = open_restart_mux(&root, &session);
    let pane = mux.with_state(|state| {
        state.workspaces[0].screens[0].layout_columns[1].root.first_visible_pane()
    });
    mux.new_row_with_options(pane, 500, Default::default(), Some((38, 10)), None).unwrap();
    mux.shutdown();
    drop(mux);
    let screen = stored_screen(&root, &session);
    let rows = screen.viewport.columns[1].rows.clone();
    assert_eq!(rows.len(), 2);
    assert_eq!(identity(&root, &session, &rows[0].id), Some(("split".into(), false)));
    assert_eq!(identity(&root, &session, &rows[1].id), Some(("split".into(), true)));
    std::fs::remove_dir_all(root).unwrap();
}

/// R4b: a column id that was truly closed never comes back, even when side
/// table records that a build without `rows-v1` left behind still name it.
#[test]
fn a_truly_closed_column_id_is_never_revived() {
    let (root, session) = seed("closed", |_| {});
    let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
    let original = stored_screen_in(&registry);
    let mut tree = original.clone();
    tree.viewport = RegistryViewport::default();
    let commit = |registry: &mut WorkspaceRegistry, key: &str, screen: RegistryScreen| {
        registry.commit_resource_patch(
            &WorkspaceMutation::new(key.to_string(), "test").unwrap(),
            "test.screen",
            &serde_json::json!({"key": key}),
            None,
            None,
            &ResourcePatch { changes: vec![ResourceChange::UpsertScreen(screen)] },
            &serde_json::json!({}),
            &serde_json::json!([]),
        )
    };
    commit(&mut registry, "close-columns", tree).unwrap();
    assert_eq!(
        registry.split_identity(restore_split_id(3).as_str()).unwrap(),
        Some(("split".into(), false))
    );
    registry
        .execute_sql_for_test(&format!(
            "INSERT INTO resource_screen_rows(
               screen_id, column_id, position, row_id, height_permille
             ) VALUES('{screen}', '{column}', 0, '{one}', 700),
                     ('{screen}', '{column}', 1, '{two}', 300)",
            screen = restore_screen_id(1),
            column = restore_split_id(3),
            one = restore_split_id(9),
            two = restore_split_id(1),
        ))
        .unwrap();
    let error = commit(&mut registry, "reopen-column", original).unwrap_err();
    assert!(format!("{error:#}").contains("cannot be reused"), "{error:#}");
    assert_eq!(
        registry.split_identity(restore_split_id(3).as_str()).unwrap(),
        Some(("split".into(), false))
    );
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// A one-time repair at open registers the side-table ids that a build
/// before row identities wrote without a ledger row, as parked identities.
#[test]
fn open_registers_side_table_ids_without_an_identity() {
    let (root, session) = seed("repair", |screen| {
        screen.viewport.columns[0].rows = vec![row(9, 700), row(1, 300)];
    });
    let registry = WorkspaceRegistry::open(&root, &session).unwrap();
    registry
        .execute_sql_for_test(&format!(
            "DELETE FROM resource_identities WHERE public_id = '{}'",
            restore_split_id(9)
        ))
        .unwrap();
    assert_eq!(registry.split_identity(restore_split_id(9).as_str()).unwrap(), None);
    drop(registry);
    assert_eq!(identity(&root, &session, &restore_split_id(9)), Some(("split".into(), false)));
    let mux = open_restart_mux(&root, &session);
    assert_eq!(first_column_rows(&mux).len(), 2, "the repaired rows still load");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
