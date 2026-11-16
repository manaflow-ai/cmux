//! The load of `resource_floating_panes` (`floating-panes-v1`): what the table can hold that this build did not
//! write, and how many statements read it.

use std::sync::atomic::{AtomicU64, Ordering};

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};

use super::*;

/// Runs `sql` on the store, as a build or a tool that this build does not know.
fn stage(root: &Path, session: &str, sql: &str) {
    WorkspaceRegistry::open(root, session).unwrap().execute_sql_for_test(sql).unwrap();
}

/// A record of `pane` with a frame in the middle of the screen.
fn centered(pane: PanePublicId) -> Floating<PanePublicId> {
    Floating { pane, frame: FloatFrame::centered(500_000, 500_000) }
}

/// The faults of one record: a REAL, a TEXT, two values that are not a `u32`, and a pane id that is a BLOB.
const FAULTS: [&str; 5] = ["x = 0.5", "y = 'abc'", "w = -1", "h = 5000000000", "pane_id = x'01'"];

/// A store whose first screen has the records of `good` and a record of the low pane with `fault` in it. The
/// table also has a record of a screen that the store does not have.
fn store_with_a_wrong_value(
    name: &str,
    fault: &str,
    good: &[Floating<PanePublicId>],
) -> (PathBuf, String) {
    let low = restore_pane_id(3);
    let (root, session) = seed(name, |seeded| {
        seeded.floating = good.to_vec();
        seeded
            .floating
            .push(Floating { pane: low.clone(), frame: FloatFrame::centered(300_000, 300_000) });
    });
    stage(
        &root,
        &session,
        &format!(
            "UPDATE resource_floating_panes SET {fault} WHERE pane_id = '{low}';
             INSERT INTO resource_floating_panes(screen_id, pane_id, position, x, y, w, h)
             VALUES('{gone}', '{right}', 0, 0, 0, 500000, 500000);",
            gone = restore_screen_id(99),
            right = restore_pane_id(4),
        ),
    );
    (root, session)
}

/// The column types of the table are affinities only: SQLite keeps a REAL, a TEXT or a BLOB in an `INTEGER`
/// column. One record with such a value, or with a value that is not a `u32`, is dropped. The load goes on,
/// the other records stay, and the next write of the screen takes the record out of the table.
#[test]
fn floating_pane_record_with_a_wrong_value_is_dropped_and_the_load_goes_on() {
    let right = restore_pane_id(4);
    let screen = restore_screen_id(1);
    let good = vec![centered(right.clone())];
    for (index, fault) in FAULTS.into_iter().enumerate() {
        let (root, session) = store_with_a_wrong_value(&format!("wrong-{index}"), fault, &good);

        let opened = WorkspaceRegistry::open(&root, &session);
        assert!(opened.is_ok(), "{fault}: the store did not open: {:?}", opened.as_ref().err());
        let topology = opened.unwrap().resource_topology_snapshot();
        assert!(topology.is_ok(), "{fault}: the load failed: {:?}", topology.as_ref().err());
        let stored = topology
            .unwrap()
            .screens
            .into_iter()
            .find(|stored| stored.public_id == screen)
            .unwrap()
            .floating;
        assert_eq!(stored, good, "{fault}: only the record with the fault is dropped");

        let mux = open_restart_mux(&root, &session);
        assert_eq!(live_list(&mux), good, "{fault}");
        mux.float_pane_as(&Actor::Daemon, live_pane(&mux, &right), FloatMode::Off, None, None)
            .unwrap();
        mux.shutdown();
        drop(mux);
        let records = WorkspaceRegistry::open(&root, &session)
            .unwrap()
            .query_text_for_test(&format!(
                "SELECT CAST(COUNT(*) AS TEXT) FROM resource_floating_panes
                 WHERE screen_id = '{screen}'"
            ))
            .unwrap();
        assert_eq!(records, "0", "{fault}: the next write of the screen removes the record");
        std::fs::remove_dir_all(root).unwrap();
    }
}

/// A commit that states the screen with the list that the load gave takes the record that is not valid out of
/// the table: while such a record is there, the stored list does not agree with the list of a commit. The same
/// commit one more time writes no record of the screen, so the first write came from that record and from no
/// other part of the screen.
#[test]
fn floating_pane_record_with_a_wrong_value_goes_at_a_commit_of_the_loaded_list() {
    let screen = restore_screen_id(1);
    let good = vec![centered(restore_pane_id(4))];
    // The fixture with the list that the load gives: the good record only.
    let (snapshot, mut topology) = resource_restore_fixture();
    topology.screens.iter_mut().find(|stated| stated.public_id == screen).unwrap().floating =
        good.clone();
    let patch = resource_restore_patch(&snapshot, &topology);
    let commit = |registry: &mut WorkspaceRegistry, mutation: String| {
        registry
            .commit_resource_patch(
                &WorkspaceMutation::daemon(mutation, "test").unwrap(),
                "session.restore_fixture",
                &serde_json::json!({"fixture":"floating"}),
                None,
                None,
                &patch,
                &serde_json::json!({"restored":true}),
                &serde_json::json!([{"event":"session.restored"}]),
            )
            .unwrap();
    };
    let of_records = |registry: &WorkspaceRegistry, value: &str| {
        registry
            .query_text_for_test(&format!(
                "SELECT CAST({value} AS TEXT) FROM resource_floating_panes
                 WHERE screen_id = '{screen}'"
            ))
            .unwrap()
    };
    for (index, fault) in FAULTS.into_iter().enumerate() {
        let (root, session) = store_with_a_wrong_value(&format!("stated-{index}"), fault, &good);
        let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
        assert_eq!(stored_list_in(&registry), good, "{fault}: the load drops the record");
        assert_eq!(of_records(&registry, "COUNT(*)"), "2", "{fault}: the load writes nothing");

        commit(&mut registry, format!("stated-{index}"));
        assert_eq!(
            of_records(&registry, "COUNT(*)"),
            "1",
            "{fault}: the commit removes the record"
        );
        assert_eq!(stored_list_in(&registry), good, "{fault}: the good record stays");

        // The compare of the stored list with the list of a commit does not read the position: a position
        // that stays shows that a commit wrote no record.
        registry
            .execute_sql_for_test(&format!(
                "UPDATE resource_floating_panes SET position = 7 WHERE screen_id = '{screen}'"
            ))
            .unwrap();
        commit(&mut registry, format!("stated-again-{index}"));
        assert_eq!(
            of_records(&registry, "position"),
            "7",
            "{fault}: a commit that changes nothing of the screen writes no record"
        );
        drop(registry);
        std::fs::remove_dir_all(root).unwrap();
    }
}

fn panes_of(list: Vec<Floating<PanePublicId>>) -> Vec<PanePublicId> {
    list.into_iter().map(|entry| entry.pane).collect()
}

/// Records for each pane of the screen: the load keeps one pane tiled, as the rules of the list say. The
/// screen has 2 panes that can float, and a build that this build does not know wrote a record for each.
#[test]
fn floating_pane_records_keep_one_tiled_pane_at_load() {
    let [one, two, low, right] = [1, 2, 3, 4].map(restore_pane_id);
    let screen = restore_screen_id(1);
    let (root, session) = seed("ground", |_| {});
    // The 2 members of the stack close: the low pane and the right pane are the panes of the screen.
    let mux = open_restart_mux(&root, &session);
    for pane in [&one, &two] {
        assert!(mux.close_pane(live_pane(&mux, pane)).unwrap());
    }
    mux.shutdown();
    drop(mux);
    stage(
        &root,
        &session,
        &format!(
            "INSERT INTO resource_floating_panes(screen_id, pane_id, position, x, y, w, h)
             VALUES('{screen}', '{right}', 0, 250000, 250000, 500000, 500000),
                   ('{screen}', '{low}', 1, 250000, 250000, 500000, 500000);"
        ),
    );

    let stored = panes_of(stored_list(&root, &session));
    assert_eq!(stored, [right.clone()], "the front pane stays tiled, the pane behind floats");

    let mux = open_restart_mux(&root, &session);
    assert_eq!(panes_of(live_list(&mux)), [right]);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A record of a pane that never floats is dropped at the load: a build that this build does not know put the
/// pane into a stack, or gave its column rows, after the pane floated. The records of the other panes stay.
#[test]
fn floating_pane_record_of_a_pane_that_never_floats_is_dropped_at_load() {
    let [one, low, right] = [1, 3, 4].map(restore_pane_id);
    let records = |panes: &[&PanePublicId]| {
        panes
            .iter()
            .map(|pane| Floating {
                pane: (*pane).clone(),
                frame: FloatFrame::centered(500_000, 500_000),
            })
            .collect::<Vec<_>>()
    };

    // Pane 1 is a member of the stack of the first column.
    let (root, session) = seed("never-stack", |screen| {
        screen.floating = records(&[&one, &right]);
    });
    assert_eq!(panes_of(stored_list(&root, &session)), [right.clone()], "a member of a stack");
    let mux = open_restart_mux(&root, &session);
    assert_eq!(panes_of(live_list(&mux)), [right.clone()], "a member of a stack, live");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();

    // The first column has 2 rows; the low pane is the pane of its second row.
    let (root, session) = seed("never-rows", |screen| {
        screen.viewport.columns[0].rows = vec![
            RegistryRow { id: restore_split_id(9), height: 700 },
            RegistryRow { id: restore_split_id(1), height: 300 },
        ];
        screen.floating = records(&[&low, &right]);
    });
    assert_eq!(panes_of(stored_list(&root, &session)), [right.clone()], "a column with rows");
    let mux = open_restart_mux(&root, &session);
    assert_eq!(panes_of(live_list(&mux)), [right], "a column with rows, live");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A floating pane is never zoomed. A build that this build does not know zoomed a pane that floats: the load
/// ends the zoom and keeps the record.
#[test]
fn floating_pane_record_of_the_zoomed_pane_ends_the_zoom_at_load() {
    let low = restore_pane_id(3);
    let (root, session) = seed("zoom", |screen| {
        assert_eq!(screen.zoomed_pane, Some(low.clone()), "the fixture zooms the low pane");
        screen.floating =
            vec![Floating { pane: low.clone(), frame: FloatFrame::centered(500_000, 500_000) }];
    });

    let stored = WorkspaceRegistry::open(&root, &session)
        .unwrap()
        .resource_topology_snapshot()
        .unwrap()
        .screens
        .into_iter()
        .find(|stored| stored.public_id == restore_screen_id(1))
        .unwrap();
    assert_eq!(panes_of(stored.floating), [low.clone()], "the pane floats");
    assert_eq!(stored.zoomed_pane, None, "the load ends the zoom");

    let mux = open_restart_mux(&root, &session);
    assert_eq!(panes_of(live_list(&mux)), [low]);
    mux.with_state(|state| {
        assert_eq!(state.workspaces[0].screens[0].zoomed_pane, None, "no zoom in the live screen");
    });
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A floating pane on each of the two screens of one workspace. The load reads the screens in the order of their
/// positions, and the records in the order of the screen ids. Here the screen with the first id has the second
/// position, so the first record that the load reads is a record of the second screen. A restart gives each
/// screen its own list and its own rows.
#[test]
fn floating_panes_of_two_screens_load_each_on_its_own_screen() {
    let [columns, selected] = [1, 2].map(restore_screen_id);
    let (root, session) = seed_screens("two-screens", |screens| {
        // The patch of the fixture also gives the screens their positions from the order of this list.
        screens.sort_by_key(|screen| screen.public_id == columns);
        for (position, screen) in screens.iter_mut().enumerate() {
            screen.position = position;
        }
    });
    let moved = FloatFrame { x: 100_000, y: 200_000, w: 400_000, h: 500_000 };
    let wide = FloatFrame { x: 300_000, y: 100_000, w: 500_000, h: 600_000 };
    let on_columns = vec![Floating { pane: restore_pane_id(3), frame: moved }];
    let on_selected = vec![Floating { pane: restore_pane_id(5), frame: wide }];

    let mux = open_restart_mux(&root, &session);
    // The screen `selected` has one pane in the fixture: the product gives it a second column with a new pane.
    let five = live_pane(&mux, &restore_pane_id(5));
    mux.new_pane_right(five, 0.5, Some((38, 10))).unwrap();
    // The screen `columns` gets two rows in its second column from `new-row`.
    let right = live_pane(&mux, &restore_pane_id(4));
    mux.new_row_with_options(right, 500, Default::default(), Some((38, 10)), None).unwrap();
    let low = live_pane(&mux, &restore_pane_id(3));
    mux.float_pane_as(&Actor::Daemon, low, FloatMode::On, Some(moved), None).unwrap();
    mux.float_pane_as(&Actor::Daemon, five, FloatMode::On, Some(wide), None).unwrap();

    let (list, columns_rows) = live_screen(&mux, &columns);
    assert_eq!(list, on_columns);
    assert_eq!(columns_rows, [0, 2], "the rows of the two columns of the screen with rows");
    let (list, selected_rows) = live_screen(&mux, &selected);
    assert_eq!(list, on_selected);
    assert!(selected_rows.iter().all(|rows| *rows == 0), "no rows: {selected_rows:?}");
    mux.shutdown();
    drop(mux);

    let (first_record, stored) = {
        let registry = WorkspaceRegistry::open(&root, &session).unwrap();
        let first_record = registry
            .query_text_for_test(
                "SELECT screen_id FROM resource_floating_panes ORDER BY screen_id, position LIMIT 1",
            )
            .unwrap();
        let stored = registry.resource_topology_snapshot().unwrap().screens;
        (first_record, stored)
    };
    let order = stored.iter().map(|screen| screen.public_id.clone()).collect::<Vec<_>>();
    assert_eq!(
        order,
        [selected.clone(), columns.clone()],
        "the screens in the order of their positions"
    );
    assert_eq!(
        first_record,
        columns.to_string(),
        "the first record is a record of the second screen"
    );
    for screen in stored {
        let expected = if screen.public_id == columns { &on_columns } else { &on_selected };
        assert_eq!(&screen.floating, expected, "the stored list of {}", screen.public_id);
    }

    let mux = open_restart_mux(&root, &session);
    assert_eq!(
        live_screen(&mux, &columns),
        (on_columns, columns_rows),
        "a restart keeps the list and the rows of the second screen"
    );
    assert_eq!(
        live_screen(&mux, &selected),
        (on_selected, selected_rows),
        "a restart keeps the list and the rows of the first screen"
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A record for each pane of each of the two screens, with the screens in the order of the test above: the
/// first record that the load reads is a record of the second screen. The table keeps each record. The load
/// keeps one pane tiled on each screen: the rules of the list apply to each screen with the panes of that
/// screen.
#[test]
fn floating_pane_records_of_two_screens_keep_one_tiled_pane_on_each_screen() {
    let [columns, selected] = [1, 2].map(restore_screen_id);
    let order = [4, 3, 1, 2].map(restore_pane_id);
    let back = [4, 3].map(restore_pane_id);
    // The screen `selected` has one pane in the fixture.
    let alone = [restore_pane_id(5)];
    let (root, session) = seed_screens("two-grounds", |screens| {
        screens.sort_by_key(|screen| screen.public_id == columns);
        for (position, screen) in screens.iter_mut().enumerate() {
            screen.position = position;
            let panes: &[PanePublicId] = if screen.public_id == columns { &order } else { &alone };
            screen.floating = panes.iter().cloned().map(centered).collect();
        }
    });
    let panes = |list: &[Floating<PanePublicId>]| {
        list.iter().map(|entry| entry.pane.clone()).collect::<Vec<_>>()
    };

    let (records, first_record, stored) = {
        let registry = WorkspaceRegistry::open(&root, &session).unwrap();
        let records = registry
            .query_text_for_test("SELECT CAST(COUNT(*) AS TEXT) FROM resource_floating_panes")
            .unwrap();
        let first_record = registry
            .query_text_for_test(
                "SELECT screen_id FROM resource_floating_panes ORDER BY screen_id, position LIMIT 1",
            )
            .unwrap();
        (records, first_record, registry.resource_topology_snapshot().unwrap().screens)
    };
    assert_eq!(records, "5", "the table has a record for each pane of each screen");
    assert_eq!(
        first_record,
        columns.to_string(),
        "the first record is a record of the second screen"
    );
    let positions = stored.iter().map(|screen| screen.public_id.clone()).collect::<Vec<_>>();
    assert_eq!(
        positions,
        [selected.clone(), columns.clone()],
        "the screens in the order of their positions"
    );
    for screen in &stored {
        let list = panes(&screen.floating);
        if screen.public_id == columns {
            assert!(
                list.len() < order.len(),
                "one pane of the second screen stays tiled: {list:?}"
            );
            assert!(list.starts_with(&back), "the list keeps its order from the back: {list:?}");
        } else {
            assert!(list.is_empty(), "the one pane of the first screen stays tiled: {list:?}");
        }
    }

    let mux = open_restart_mux(&root, &session);
    let list = panes(&live_screen(&mux, &columns).0);
    assert!(list.len() < order.len(), "after a restart, the second screen: {list:?}");
    assert!(list.starts_with(&back), "after a restart, the order from the back: {list:?}");
    let list = panes(&live_screen(&mux, &selected).0);
    assert!(list.is_empty(), "after a restart, the first screen: {list:?}");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

/// A change of the active workspace loads the active screen of the workspace that loses the focus and of the
/// one that gets it. One statement reads the floating panes of the two screens: not one for each screen, and
/// none for the empty list of the workspaces that close.
#[test]
fn floating_pane_records_are_read_one_time_for_a_focus_change() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 22))).unwrap();
    mux.new_workspace(None, Some((80, 22))).unwrap();
    let registry = mux.workspace_registry.lock().unwrap();
    let live = registry.snapshot().unwrap().workspaces;
    let active = registry.resource_topology_scoped(&[]).unwrap().active_workspace;
    let other = live
        .iter()
        .map(|workspace| workspace.public_id.clone())
        .find(|workspace| Some(workspace) != active.as_ref())
        .unwrap();

    let statements = Arc::new(AtomicU64::new(0));
    let (count, caller) = (statements.clone(), std::thread::current().id());
    mux.registry_connection
        .get()
        .authorizer(Some(move |context: AuthContext<'_>| {
            // SQLite asks when it compiles a statement, one time for each column that the statement names.
            // Each statement that reads the frames names `x` one time.
            let reads_frames = matches!(
                context.action,
                AuthAction::Read { table_name: "resource_floating_panes", column_name: "x" }
            );
            if reads_frames && std::thread::current().id() == caller {
                count.fetch_add(1, Ordering::Relaxed);
            }
            Authorization::Allow
        }))
        .unwrap();
    let topology = registry.resource_topology_for_workspace_commit(&live, Some(&other));
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();

    assert_eq!(
        topology.unwrap().screens.len(),
        2,
        "the active screen of each of the two workspaces"
    );
    assert_eq!(
        statements.load(Ordering::Relaxed),
        1,
        "one statement reads the floating panes of the two screens"
    );
}

/// The side tables of screens are read for the screens that a load holds. A load that holds no screen (the
/// scoped load of an empty list of workspaces) reads none of them.
#[test]
fn floating_pane_load_of_no_screen_reads_no_side_table() {
    let mux = test_mux();
    mux.new_workspace(None, Some((80, 22))).unwrap();
    let registry = mux.workspace_registry.lock().unwrap();

    let read = Arc::new(std::sync::Mutex::new(std::collections::BTreeSet::<String>::new()));
    let (sink, caller) = (read.clone(), std::thread::current().id());
    mux.registry_connection
        .get()
        .authorizer(Some(move |context: AuthContext<'_>| {
            // SQLite asks when it compiles a statement, one time for each column that the statement names.
            if let AuthAction::Read { table_name, .. } = context.action
                && std::thread::current().id() == caller
            {
                sink.lock().unwrap().insert(table_name.to_owned());
            }
            Authorization::Allow
        }))
        .unwrap();
    let topology = registry.resource_topology_scoped(&[]);
    mux.registry_connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();

    assert!(topology.unwrap().screens.is_empty(), "the load holds no screen");
    let read = read.lock().unwrap().clone();
    for table in [
        "resource_column_docks",
        "resource_screen_rows",
        "resource_lone_docks",
        "resource_parked_splits",
        "resource_floating_panes",
    ] {
        assert!(!read.contains(table), "a load of no screen read the table {table}: {read:?}");
    }
}
