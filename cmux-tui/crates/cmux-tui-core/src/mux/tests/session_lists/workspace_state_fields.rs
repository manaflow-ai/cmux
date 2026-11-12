//! Final bench row (e), 2026-11-12: the daemon's reply to `workspace.list` at 50 workspaces went
//! from 0.753 to 1.14 ms at 2e5a10e4. That commit made the state fields of ONE workspace a read of
//! the 7 bulk statements of `state/workspace_extras.rs` with one id, and `workspace.list` (and the
//! session snapshot) decorated each workspace with it: 7 statements per workspace. The person's
//! session has about 826 workspaces.
//!
//! The checks: (1) a count with no clock: `workspace.list` and `session.snapshot` compile the same
//! number of statements at any number of workspaces, on a registry in memory and on a file
//! registry; (2) the bulk decoration of the snapshot's workspaces, screens and tabs equals the
//! decoration of each value, as JSON text, over a session where every state table has rows for
//! some values and none for others (workspaces: each of the 7 workspace fields, a closed creator;
//! screens: presentation, a group, both, none; tabs: each tab state table), and `workspace.list`
//! and `session.snapshot` answer exactly those values (`workspace.list` in its own order).

use super::tab_state_fields::{
    close_file_session, file_session_of, give_each_state_table_a_row, selects_of,
};
use super::*;

/// The statements `operation` compiles, and how many workspaces the session lists.
fn statements_of(mux: &Arc<Mux>, operation: &str) -> (usize, usize) {
    let statements = selects_of(mux, || {
        resource(mux, operation, json!({}));
    });
    let listed = resource(mux, "workspace.list", json!({}));
    (statements, listed.as_array().map_or(0, Vec::len))
}

/// The statements of one read of the sidebar document (`state/sidebar_doc_store.rs`: its
/// revision, the table check, the sections and the items). A request reads the document when the
/// process's one cached copy is of another registry, and the tests that run at the same time take
/// that copy for their own registries; the read is the same at any number of workspaces.
const SIDEBAR_DOCUMENT_READ: usize = 4;

fn check_statements(
    operation: &str,
    (few, few_workspaces): (usize, usize),
    (many, many_workspaces): (usize, usize),
) {
    assert!(
        few_workspaces >= 4 && many_workspaces >= few_workspaces * 4,
        "workspaces listed: {few_workspaces}, then {many_workspaces}"
    );
    assert!(few > 0, "the count sees the statements of {operation}");
    assert!(
        many.abs_diff(few) <= SIDEBAR_DOCUMENT_READ,
        "{operation} compiled {few} statements for {few_workspaces} workspaces and {many} for \
         {many_workspaces} workspaces: it reads state fields with statements of each value; one \
         statement set reads them for the whole session"
    );
}

/// `workspace.list` reads the workspaces' state fields with one statement set, at any size.
#[test]
fn a_workspace_list_runs_one_statement_set_at_any_number_of_workspaces() {
    let few = statements_of(&session_of(4), "workspace.list");
    let many = statements_of(&session_of(32), "workspace.list");
    check_statements("workspace.list", few, many);
}

/// The same count on a file registry (the list reads a pooled read-only connection).
#[test]
fn a_workspace_list_runs_one_statement_set_on_a_file_registry() {
    let (few_mux, few_root) = file_session_of("workspace-statements-few", 4);
    let (many_mux, many_root) = file_session_of("workspace-statements-many", 32);
    let few = statements_of(&few_mux, "workspace.list");
    let many = statements_of(&many_mux, "workspace.list");
    close_file_session(few_mux, few_root);
    close_file_session(many_mux, many_root);
    check_statements("workspace.list", few, many);
}

/// The session snapshot decorates its workspaces, screens and tabs with one statement set, at
/// any size (a registry in memory builds the snapshot on each read).
#[test]
fn a_session_snapshot_runs_one_statement_set_at_any_number_of_workspaces() {
    let few = statements_of(&session_of(4), "session.snapshot");
    let many = statements_of(&session_of(32), "session.snapshot");
    check_statements("session.snapshot", few, many);
}

/// Give two screens a presentation row, two a group membership (one screen has both), and leave
/// the others without a row.
fn give_screens_state_rows(mux: &Arc<Mux>) {
    let connection = mux.registry_connection.get();
    let screens = connection
        .prepare(
            "SELECT s.public_id, w.workspace_key FROM resource_screens AS s
             JOIN resource_workspaces AS w ON w.public_id = s.workspace_id
             WHERE s.deleted_revision IS NULL ORDER BY s.public_id",
        )
        .unwrap()
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap();
    assert!(screens.len() >= 4, "the session has four screens: {screens:?}");
    let run = |sql: &str, params: &[&dyn rusqlite::ToSql]| {
        connection.execute(sql, params).unwrap_or_else(|error| panic!("{sql}: {error}"));
    };
    run(
        "INSERT INTO screen_presentation(screen_id, pinned, color, icon)
         VALUES(?1, 1, '#123456', 'star')",
        &[&screens[0].0],
    );
    run(
        "INSERT INTO screen_presentation(screen_id, pinned, color, icon) VALUES(?1, 0, NULL, 'dot')",
        &[&screens[1].0],
    );
    run(
        "INSERT INTO screen_groups(group_id, workspace_key, name, color)
         VALUES('sgr_lists', ?1, 'group', 'red')",
        &[&screens[0].1],
    );
    for screen in [&screens[0].0, &screens[2].0] {
        run(
            "INSERT INTO screen_group_members(screen_id, group_id) VALUES(?1, 'sgr_lists')",
            &[screen],
        );
    }
}

/// The bulk decoration of the snapshot equals the decoration of each value, as JSON text, and
/// `workspace.list` and `session.snapshot` answer those values.
#[test]
fn the_bulk_decorations_equal_the_decoration_of_each_value() {
    let mux = test_mux();
    // The workspaces first: `session_with_each_field` writes the app kind with the store function
    // (not through the journal), so a mutation after it finds the journal's state and the
    // registry's different (the scoped projection check of debug builds).
    fill(&mux, 6);
    let fields = crate::state::workspace_extras_tests::session_with_each_field(&mux);
    give_each_state_table_a_row(&mux);
    give_screens_state_rows(&mux);

    let each = mux
        .read_registry_state(|connection| {
            let undecorated =
                crate::resource_api::undecorated_snapshot_values_for_test(connection, &mux)?;
            let mut each = undecorated.clone();
            crate::state::values::decorate_snapshot_one_by_one(connection, &mut each)?;
            let mut bulk = undecorated;
            crate::state::values::decorate_snapshot(connection, &mut bulk)?;
            assert_eq!(
                serde_json::to_string(&bulk)?,
                serde_json::to_string(&each)?,
                "the bulk decoration, then the decoration of each value"
            );
            Ok(each)
        })
        .unwrap();

    // The session has rows of each kind, so the comparison covers each statement.
    let find = |collection: &str, check: &dyn Fn(&Value) -> bool| {
        each[collection].as_array().unwrap().iter().any(|value| check(&value["extra"]))
    };
    assert!(find("workspaces", &|extra| extra["title"] == "API server"));
    assert!(find("workspaces", &|extra| extra["ephemeral"] == true));
    assert!(find("workspaces", &|extra| extra["kind"] == "home"));
    assert!(find("workspaces", &|extra| extra["app"] == "notes"));
    assert!(find("workspaces", &|extra| extra["agent_folder"] == fields.folder.as_str()));
    assert!(find("workspaces", &|extra| extra["created_by"] == json!({"kind": "script"})));
    assert!(
        find("workspaces", &|extra| extra["created_by"]["workspace"] == fields.creator.as_str())
    );
    assert!(find("workspaces", &|extra| extra.get("title").is_none()));
    assert!(find("screens", &|extra| extra["pinned"] == true
        && extra["screen_group_id"] == "sgr_lists"));
    assert!(find("screens", &|extra| extra["icon"] == "dot" && extra.get("pinned").is_none()));
    assert!(find("screens", &|extra| extra["screen_group_id"] == "sgr_lists"
        && extra.get("icon").is_none()));
    assert!(find("screens", &|extra| extra.get("screen_group_id").is_none()
        && extra.get("icon").is_none()));
    assert!(find("tabs", &|extra| extra["pinned"] == true && extra["zoom"] == 1.5));
    assert!(find("tabs", &|extra| extra["conversation"]["conversation"] == "conv_1"));

    // `workspace.list` gives the workspaces in their position order; the snapshot, in creation
    // order. Each listed workspace is the snapshot's value of that id, as text.
    let listed = resource(&mux, "workspace.list", json!({}));
    let by_id = |values: &Value| {
        values
            .as_array()
            .unwrap()
            .iter()
            .map(|value| {
                (value["id"].as_str().unwrap().to_owned(), serde_json::to_string(value).unwrap())
            })
            .collect::<std::collections::BTreeMap<_, _>>()
    };
    assert_eq!(
        listed.as_array().map(Vec::len),
        each["workspaces"].as_array().map(Vec::len),
        "workspace.list lists each workspace of the snapshot once"
    );
    assert_eq!(
        by_id(&listed),
        by_id(&each["workspaces"]),
        "workspace.list answers the workspaces decorated one by one"
    );
    let snapshot = resource(&mux, "session.snapshot", json!({}));
    for collection in ["workspaces", "screens", "tabs"] {
        assert_eq!(
            serde_json::to_string(&snapshot[collection]).unwrap(),
            serde_json::to_string(&each[collection]).unwrap(),
            "session.snapshot's {collection}, then its values decorated one by one"
        );
    }
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&fields.folder_root);
}
