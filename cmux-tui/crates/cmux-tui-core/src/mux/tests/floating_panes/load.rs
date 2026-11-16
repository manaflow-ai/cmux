//! The load of `resource_floating_panes` (`floating-panes-v1`): what the table can hold that this build did not
//! write, and how many statements read it.

use std::sync::atomic::{AtomicU64, Ordering};

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};

use super::*;

/// Runs `sql` on the store, as a build or a tool that this build does not know.
fn stage(root: &Path, session: &str, sql: &str) {
    WorkspaceRegistry::open(root, session).unwrap().execute_sql_for_test(sql).unwrap();
}

/// The column types of the table are affinities only: SQLite keeps a REAL, a TEXT or a BLOB in an `INTEGER`
/// column. One record with such a value, or with a value that is not a `u32`, is dropped. The load goes on,
/// the other records stay, and the next write of the screen takes the record out of the table.
#[test]
fn floating_pane_record_with_a_wrong_value_is_dropped_and_the_load_goes_on() {
    let right = restore_pane_id(4);
    let low = restore_pane_id(3);
    let screen = restore_screen_id(1);
    let good =
        vec![Floating { pane: right.clone(), frame: FloatFrame::centered(500_000, 500_000) }];
    let faults = ["x = 0.5", "y = 'abc'", "w = -1", "h = 5000000000", "pane_id = x'01'"];
    for (index, fault) in faults.into_iter().enumerate() {
        let (root, session) = seed(&format!("wrong-{index}"), |seeded| {
            seeded.floating = good.clone();
            seeded.floating.push(Floating {
                pane: low.clone(),
                frame: FloatFrame::centered(300_000, 300_000),
            });
        });
        // The fault in the record of the low pane, and a record of a screen that the store does not have.
        stage(
            &root,
            &session,
            &format!(
                "UPDATE resource_floating_panes SET {fault} WHERE pane_id = '{low}';
                 INSERT INTO resource_floating_panes(screen_id, pane_id, position, x, y, w, h)
                 VALUES('{gone}', '{right}', 0, 0, 0, 500000, 500000);",
                gone = restore_screen_id(99),
            ),
        );

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

/// Records for each pane of the screen: the load keeps one pane tiled, as the rules of the list say.
#[test]
fn floating_pane_records_keep_one_tiled_pane_at_load() {
    let order = [4, 3, 1, 2].map(restore_pane_id);
    let (root, session) = seed("ground", |screen| {
        screen.floating = order
            .iter()
            .map(|pane| Floating {
                pane: pane.clone(),
                frame: FloatFrame::centered(500_000, 500_000),
            })
            .collect();
    });
    let panes = |list: Vec<Floating<PanePublicId>>| {
        list.into_iter().map(|entry| entry.pane).collect::<Vec<_>>()
    };

    let stored = panes(stored_list(&root, &session));
    assert!(stored.len() < order.len(), "one pane of the screen stays tiled: {stored:?}");
    assert_eq!(stored[..2], order[..2], "the list keeps its order from the back");

    let mux = open_restart_mux(&root, &session);
    let live = panes(live_list(&mux));
    assert!(live.len() < order.len(), "one pane of the screen stays tiled: {live:?}");
    assert_eq!(live[..2], order[..2]);
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

// Twenty more passes of `floating_panes_of_two_screens_load_each_on_its_own_screen` in one run.
// Each name is one test process. A proof branch only: it does not merge.
macro_rules! repeat20_two_screens {
    ($($name:ident)*) => {
        $(
            #[test]
            fn $name() {
                floating_panes_of_two_screens_load_each_on_its_own_screen();
            }
        )*
    };
}

repeat20_two_screens!(
    repeat20_two_screens_01 repeat20_two_screens_02 repeat20_two_screens_03 repeat20_two_screens_04 repeat20_two_screens_05
    repeat20_two_screens_06 repeat20_two_screens_07 repeat20_two_screens_08 repeat20_two_screens_09 repeat20_two_screens_10
    repeat20_two_screens_11 repeat20_two_screens_12 repeat20_two_screens_13 repeat20_two_screens_14 repeat20_two_screens_15
    repeat20_two_screens_16 repeat20_two_screens_17 repeat20_two_screens_18 repeat20_two_screens_19 repeat20_two_screens_20
);
