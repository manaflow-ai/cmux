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

        // A commit that states the screen with the list of the load. It changes no row and no entry of the
        // list, so only the record with the fault makes the table differ from the list: the commit writes
        // the list, and the record goes.
        let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
        commit_fixture(&mut registry, &format!("again-floating-wrong-{index}"), None, |seeded| {
            seeded.floating = good.clone();
        });
        let records = registry
            .query_text_for_test(&format!(
                "SELECT group_concat(CAST(pane_id AS TEXT), ',') FROM resource_floating_panes
                 WHERE screen_id = '{screen}'"
            ))
            .unwrap();
        assert_eq!(records, right.to_string(), "{fault}: the screen has 1 record, the good one");
        drop(registry);

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
