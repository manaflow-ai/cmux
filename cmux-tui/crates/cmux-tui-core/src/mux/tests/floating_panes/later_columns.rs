//! A store whose table of floating panes has 2 columns more than this build makes, in the hands of this build.
//!
//! A later build adds the 2 columns to the table at each open, with the 2 statements of [`MARK_COLUMNS`]: column
//! `quick` (0 = a floating pane, 1 and 2 = a mark on the record) and column `quick_from` (a pane id, or NULL).
//! It does not change the schema version of the store. This build names its 7 columns in each statement of the
//! table, so the 2 columns stop no open, no load and no write. A write of a screen by this build puts the
//! records of the screen in the table again, with the defaults in the 2 columns: a record that had a mark is a
//! record of a floating pane then, and no pane is lost.
//!
//! The store of the test is not a file that the later build wrote. This build makes it, and the test runs the 2
//! statements of the later build on it. The compare of the schema text shows that the table is then the table
//! that [`TABLE`] and the 2 statements make.

use super::*;

/// The statement of the table as this build runs it at each open.
const TABLE: &str = "CREATE TABLE IF NOT EXISTS resource_floating_panes (
       screen_id TEXT NOT NULL,
       pane_id TEXT NOT NULL,
       position INTEGER NOT NULL,
       x INTEGER NOT NULL,
       y INTEGER NOT NULL,
       w INTEGER NOT NULL,
       h INTEGER NOT NULL,
       PRIMARY KEY (screen_id, pane_id)
     );";

/// The statements that add the 2 columns, as the later build runs them at an open.
const MARK_COLUMNS: [&str; 2] = [
    "ALTER TABLE resource_floating_panes ADD COLUMN quick INTEGER NOT NULL DEFAULT 0;",
    "ALTER TABLE resource_floating_panes ADD COLUMN quick_from TEXT;",
];

/// The columns of the table with the 2 columns: the name, the type, `NOT NULL`, the default, the place in the
/// key.
const COLUMNS: &str = "screen_id TEXT 1 - 1, pane_id TEXT 1 - 2, position INTEGER 1 - 0, \
                       x INTEGER 1 - 0, y INTEGER 1 - 0, w INTEGER 1 - 0, h INTEGER 1 - 0, \
                       quick INTEGER 1 0 0, quick_from TEXT 0 - 0";

/// The table of floating panes, and a second table for the compare of the schema text.
const NAME: &str = "resource_floating_panes";
const STATED: &str = "resource_floating_panes_as_stated";

/// The marks of a record as the later build writes them: `quick`, and whether `quick_from` is a pane.
const MARKS: [(i64, bool); 3] = [(2, true), (1, true), (1, false)];

fn text(registry: &WorkspaceRegistry, sql: &str) -> String {
    registry.query_text_for_test(sql).unwrap()
}

/// The columns of the table of floating panes, in the form of [`COLUMNS`].
fn columns(registry: &WorkspaceRegistry) -> String {
    text(
        registry,
        "SELECT group_concat(name || ' ' || type || ' ' || \"notnull\" || ' ' ||
                             coalesce(dflt_value, '-') || ' ' || pk, ', ')
         FROM (SELECT * FROM pragma_table_info('resource_floating_panes') ORDER BY cid)",
    )
}

/// The schema text of `table` as SQLite keeps it, with one space for each run of white space and with the name
/// of the table of floating panes.
fn schema_text(registry: &WorkspaceRegistry, table: &str) -> String {
    let sql = text(registry, &format!("SELECT sql FROM sqlite_master WHERE name = '{table}'"));
    sql.replace(STATED, NAME).split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The schema text of a table that [`TABLE`] and then `statements` make.
fn stated_schema_text(registry: &WorkspaceRegistry, statements: &[&str]) -> String {
    let run = |statement: &str| {
        registry.execute_sql_for_test(&statement.replace(NAME, STATED)).unwrap();
    };
    run(TABLE);
    statements.iter().copied().for_each(run);
    let stated = schema_text(registry, STATED);
    registry.execute_sql_for_test(&format!("DROP TABLE {STATED};")).unwrap();
    stated
}

/// `quick` and `quick_from` of the record of `pane` in the first screen.
fn mark_of(registry: &WorkspaceRegistry, pane: &PanePublicId) -> String {
    text(
        registry,
        &format!(
            "SELECT quick || '/' || coalesce(quick_from, 'NULL') FROM resource_floating_panes
             WHERE screen_id = '{screen}' AND pane_id = '{pane}'",
            screen = restore_screen_id(1),
        ),
    )
}

#[test]
fn a_store_with_the_2_columns_of_a_later_build_opens_loads_and_is_written() {
    // The fixture's first screen: a stack of panes 1 and 2 above pane 3 in one column, pane 4 in the next.
    let [one, low, right] = [1, 3, 4].map(restore_pane_id);
    let list = vec![
        Floating {
            pane: right.clone(),
            frame: FloatFrame { x: 100_000, y: 200_000, w: 400_000, h: 500_000 },
        },
        Floating {
            pane: low.clone(),
            frame: FloatFrame { x: 200_000, y: 200_000, w: 600_000, h: 600_000 },
        },
    ];
    for (index, (quick, with_from)) in MARKS.into_iter().enumerate() {
        let case = format!("quick {quick}, with a pane {with_from}");
        // This build makes the store: 2 floating panes in the first screen.
        let (root, session) =
            seed(&format!("later-{index}"), |seeded| seeded.floating = list.clone());
        let registry = WorkspaceRegistry::open(&root, &session).unwrap();
        assert_eq!(
            schema_text(&registry, NAME),
            stated_schema_text(&registry, &[]),
            "{case}: the table of this build is the table of `TABLE`"
        );

        // The store as the later build leaves it: the 2 columns, and a mark on the record of the right pane.
        for statement in MARK_COLUMNS {
            registry.execute_sql_for_test(statement).unwrap();
        }
        let (from, mark) = if with_from {
            (format!("'{one}'"), format!("{quick}/{one}"))
        } else {
            ("NULL".to_owned(), format!("{quick}/NULL"))
        };
        registry
            .execute_sql_for_test(&format!(
                "UPDATE resource_floating_panes SET quick = {quick}, quick_from = {from}
                 WHERE screen_id = '{screen}' AND pane_id = '{right}';",
                screen = restore_screen_id(1),
            ))
            .unwrap();
        assert_eq!(columns(&registry), COLUMNS, "{case}");
        assert_eq!(
            schema_text(&registry, NAME),
            stated_schema_text(&registry, &MARK_COLUMNS),
            "{case}: the table is the table that `TABLE` and the 2 statements make"
        );
        assert_eq!(mark_of(&registry, &right), mark, "{case}");
        assert_eq!(
            mark_of(&registry, &low),
            "0/NULL",
            "{case}: the defaults of a record with no mark"
        );
        drop(registry);

        // An open and a load by this build: both records, in their order, with their frames. They write nothing.
        let opened = WorkspaceRegistry::open(&root, &session);
        assert!(opened.is_ok(), "{case}: the store did not open: {:?}", opened.as_ref().err());
        let registry = opened.unwrap();
        let topology = registry.resource_topology_snapshot();
        assert!(topology.is_ok(), "{case}: the load failed: {:?}", topology.as_ref().err());
        assert_eq!(stored_list_in(&registry), list, "{case}: the load reads both records");
        assert_eq!(columns(&registry), COLUMNS, "{case}: an open changes no column");
        assert_eq!(mark_of(&registry, &right), mark, "{case}: an open and a load keep the mark");
        drop(registry);

        // A start of the daemon, and a write of the screen: the low pane does not float after it.
        let mux = open_restart_mux(&root, &session);
        assert_eq!(live_list(&mux), list, "{case}: the start has both floating panes");
        let panes = mux.with_state(|state| state.panes.len());
        let outcome = mux
            .float_pane_as(&Actor::Daemon, live_pane(&mux, &low), FloatMode::Off, None, None)
            .unwrap();
        assert!(outcome.changed, "{case}");
        mux.shutdown();
        drop(mux);

        // The write kept the 2 columns and put the defaults in them: the record of the right pane is a record
        // of a floating pane.
        let registry = WorkspaceRegistry::open(&root, &session).unwrap();
        assert_eq!(
            stored_list_in(&registry),
            list[..1],
            "{case}: the record of the right pane stays"
        );
        assert_eq!(columns(&registry), COLUMNS, "{case}: a write changes no column");
        assert_eq!(mark_of(&registry, &right), "0/NULL", "{case}: a write puts the defaults");
        drop(registry);

        // The next start: the right pane floats, and each pane is there.
        let mux = open_restart_mux(&root, &session);
        assert_eq!(live_list(&mux), list[..1], "{case}");
        assert_eq!(mux.with_state(|state| state.panes.len()), panes, "{case}: no pane is lost");
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}
