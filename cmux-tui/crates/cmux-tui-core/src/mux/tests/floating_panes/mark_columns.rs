//! The table of floating panes in a store of this build: the 7 columns of each build before the mark of the
//! quick terminal (`quick-terminal-v1`), and the 2 columns of the mark.
//!
//! This build makes the table with the statement of [`TABLE`] and adds the 2 columns with the 2 statements of
//! [`MARK_COLUMNS`], at each open, to a table that does not have them. It does not change the schema version of
//! the store. So a store of this build has the table that these 3 statements make, and a store of a build
//! before the mark has that same table after its first open by this build. A build before the mark names its 7
//! columns in each statement of the table: a test of that build, with these same 3 statements, shows that it
//! opens, loads and writes such a store.

use cmux_layout_reducer::floating_panes::Quick;

use super::*;

/// The statement of the table as this build and each build before the mark run it at each open.
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

/// The statements that add the 2 columns, as this build runs them at an open.
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

#[test]
fn a_store_of_this_build_has_the_2_columns_of_the_quick_terminal_mark() {
    let (root, session) = seed("mark-columns", |_| {});
    let registry = WorkspaceRegistry::open(&root, &session).unwrap();
    assert_eq!(columns(&registry), COLUMNS);
    let made = schema_text(&registry, NAME);
    assert_eq!(
        made,
        stated_schema_text(&registry, &MARK_COLUMNS),
        "the table is the table that `TABLE` and the 2 statements make"
    );
    drop(registry);

    // A second open adds no column.
    let registry = WorkspaceRegistry::open(&root, &session).unwrap();
    assert_eq!(schema_text(&registry, NAME), made, "a second open changes nothing of the table");

    // The table of a build before the mark, with no record: the next open by this build makes it the same
    // table.
    registry.execute_sql_for_test(&format!("DROP TABLE {NAME}; {TABLE}")).unwrap();
    assert_eq!(schema_text(&registry, NAME), stated_schema_text(&registry, &[]));
    drop(registry);
    let registry = WorkspaceRegistry::open(&root, &session).unwrap();
    assert_eq!(
        columns(&registry),
        COLUMNS,
        "the open adds the 2 columns to a table of before the mark"
    );
    assert_eq!(schema_text(&registry, NAME), made, "the same table as in a store of this build");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

/// SQLite reads the name of a column with no regard to the case of its letters. A table whose columns of the
/// mark have their names in other letters, which no build makes, has the 2 columns: the open adds no column,
/// and the store opens and loads the mark.
#[test]
fn a_column_of_the_mark_with_its_name_in_other_letters_is_the_column() {
    let (root, session) = seed("mark-column-letters", |_| {});
    let (screen, pane) = (restore_screen_id(1), restore_pane_id(4));
    let other_letters = TABLE.replace(
        "h INTEGER NOT NULL,",
        "h INTEGER NOT NULL, QUICK INTEGER NOT NULL DEFAULT 0, Quick_From TEXT,",
    );
    assert_ne!(other_letters, TABLE, "the fixture: the statement has the 2 columns");
    let registry = WorkspaceRegistry::open(&root, &session).unwrap();
    registry
        .execute_sql_for_test(&format!(
            "DROP TABLE {NAME}; {other_letters}
             INSERT INTO {NAME}(screen_id, pane_id, position, x, y, w, h, QUICK, Quick_From)
             VALUES('{screen}', '{pane}', 0, 250000, 250000, 500000, 500000, 2, NULL);"
        ))
        .unwrap();
    let expected =
        COLUMNS.replace("quick INTEGER", "QUICK INTEGER").replace("quick_from", "Quick_From");
    assert_eq!(columns(&registry), expected, "the fixture: the 2 columns in other letters");
    drop(registry);

    let opened = WorkspaceRegistry::open(&root, &session);
    assert!(opened.is_ok(), "the store did not open: {:?}", opened.as_ref().err());
    let registry = opened.unwrap();
    assert_eq!(columns(&registry), expected, "the open changed the columns");
    let mut marked = Floating::plain(pane, FloatFrame::centered(500_000, 500_000));
    marked.quick = Some(Quick { hidden: true, from: None });
    assert_eq!(stored_list_in(&registry), [marked], "the load reads the mark");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}
