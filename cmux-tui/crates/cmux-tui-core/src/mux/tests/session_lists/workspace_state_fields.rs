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

/// The statements `operation` compiles, and how many workspaces the session lists. `holder` reads
/// the sidebar document first, so the process-wide cached copy is of its registry: the count of
/// `mux` itself, or of another registry (then the request reads the rows of `mux` again).
fn statements_of(mux: &Arc<Mux>, operation: &str, holder: &Arc<Mux>) -> (usize, usize) {
    resource(holder, "workspace.list", json!({}));
    let statements = selects_of(mux, || {
        resource(mux, operation, json!({}));
    });
    let listed = resource(mux, "workspace.list", json!({}));
    (statements, listed.as_array().map_or(0, Vec::len))
}

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
    assert_eq!(
        many, few,
        "{operation} compiled {few} statements for {few_workspaces} workspaces and {many} for \
         {many_workspaces} workspaces: it reads state fields with statements of each value; one \
         statement set reads them for the whole session"
    );
}

/// The few workspaces are counted with their own sidebar document cached, the many with another
/// registry's cached: the counts must not depend on the process-wide cache.
fn few_and_many(
    operation: &str,
    few: &Arc<Mux>,
    many: &Arc<Mux>,
) -> ((usize, usize), (usize, usize)) {
    let other = session_of(1);
    let counts = (statements_of(few, operation, few), statements_of(many, operation, &other));
    other.shutdown();
    counts
}

/// `workspace.list` reads the workspaces' state fields with one statement set, at any size.
#[test]
fn a_workspace_list_runs_one_statement_set_at_any_number_of_workspaces() {
    let (few, many) = few_and_many("workspace.list", &session_of(4), &session_of(32));
    check_statements("workspace.list", few, many);
}

/// The same count on a file registry (the list reads a pooled read-only connection).
#[test]
fn a_workspace_list_runs_one_statement_set_on_a_file_registry() {
    let (few_mux, few_root) = file_session_of("workspace-statements-few", 4);
    let (many_mux, many_root) = file_session_of("workspace-statements-many", 32);
    let (few, many) = few_and_many("workspace.list", &few_mux, &many_mux);
    close_file_session(few_mux, few_root);
    close_file_session(many_mux, many_root);
    check_statements("workspace.list", few, many);
}

/// The session snapshot decorates its workspaces, screens and tabs with one statement set, at
/// any size (a registry in memory builds the snapshot on each read).
#[test]
fn a_session_snapshot_runs_one_statement_set_at_any_number_of_workspaces() {
    let (few, many) = few_and_many("session.snapshot", &session_of(4), &session_of(32));
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

/// Close `workspace` through the operation a client sends.
fn close_workspace(mux: &Arc<Mux>, workspace: &str) {
    let envelope = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "close",
                          "operation": "workspace.close", "idempotency_key": "close-a-creator",
                          "params": {"machine": "current", "session": "current",
                                     "workspace": workspace}});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "workspace.close: {response}");
}

/// Give each of `workspaces` a row in every state table that a workspace's `extra` reads: all 5
/// presentation fields, the ephemeral flag, an app kind, an agent folder, and a creator (`created`
/// pairs each workspace with its creator's key, which may be of a closed workspace, and a kind).
fn give_every_state_field(mux: &Arc<Mux>, workspaces: &[(String, Option<String>, &str)]) {
    let connection = mux.registry_connection.get();
    let key_of = |id: &str| -> String {
        connection
            .query_row(
                "SELECT workspace_key FROM resource_workspaces WHERE public_id = ?1",
                [id],
                |row| row.get(0),
            )
            .unwrap_or_else(|error| panic!("the key of {id}: {error}"))
    };
    for (index, (id, creator_key, created_kind)) in workspaces.iter().enumerate() {
        let key = key_of(id);
        let run = |sql: &str, params: &[&dyn rusqlite::ToSql]| {
            connection.execute(sql, params).unwrap_or_else(|error| panic!("{sql}: {error}"));
        };
        run(
            "INSERT INTO workspace_presentation(workspace_key, color, icon, title, description,
                                                task_status)
             VALUES(?1, ?2, ?3, ?4, ?5, 'working')
             ON CONFLICT(workspace_key) DO UPDATE SET color = excluded.color,
               icon = excluded.icon, title = excluded.title, description = excluded.description,
               task_status = excluded.task_status",
            &[
                &key,
                &format!("#00000{index}"),
                &format!("icon{index}"),
                &format!("Title {index}"),
                &format!("about {index}"),
            ],
        );
        run("INSERT OR REPLACE INTO workspace_state(workspace_id, ephemeral) VALUES(?1, 1)", &[id]);
        run(
            "INSERT OR REPLACE INTO workspace_kind(workspace_id, kind, app_id, workspace_key)
             VALUES(?1, 'app', ?2, ?3)",
            &[id, &format!("app{index}"), &key],
        );
        run(
            "INSERT OR REPLACE INTO workspace_agent_folder(workspace_id, path) VALUES(?1, ?2)",
            &[id, &format!("/tmp/folder{index}")],
        );
        run(
            "INSERT OR REPLACE INTO workspace_created_by(workspace_key, kind, creator_key, session)
             VALUES(?1, ?2, ?3, ?4)",
            &[&key, created_kind, creator_key, &(index % 2 == 0).then(|| format!("sess{index}"))],
        );
    }
}

/// The replies are byte-equal to the per-workspace path when every workspace has every state
/// field. Four workspaces each have all 7 kinds of field (one made by a closed workspace, one by
/// a live one, one by a script, one by an agent), one workspace has none, and one is closed.
/// `workspace.list` is compared as the whole serialized array, in its own order; the snapshot's
/// workspaces, screens and tabs as serialized arrays.
#[test]
fn the_replies_are_byte_equal_to_the_per_workspace_path_when_each_workspace_has_every_field() {
    let mux = session_of(6);
    let ids = resource(&mux, "workspace.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .map(|workspace| workspace["id"].as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(ids.len(), 6);
    let closed_key = mux
        .registry_connection
        .get()
        .query_row(
            "SELECT workspace_key FROM resource_workspaces WHERE public_id = ?1",
            [&ids[5]],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    let live_key = mux
        .registry_connection
        .get()
        .query_row(
            "SELECT workspace_key FROM resource_workspaces WHERE public_id = ?1",
            [&ids[0]],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    close_workspace(&mux, &ids[5]);
    give_every_state_field(
        &mux,
        &[
            (ids[0].clone(), Some(closed_key), "script"),
            (ids[1].clone(), Some(live_key), "agent"),
            (ids[2].clone(), None, "script"),
            (ids[3].clone(), None, "agent"),
        ],
    );

    let each = mux
        .read_registry_state(|connection| {
            let mut each =
                crate::resource_api::undecorated_snapshot_values_for_test(connection, &mux)?;
            crate::state::values::decorate_snapshot_one_by_one(connection, &mut each)?;
            Ok(each)
        })
        .unwrap();
    let per_workspace = each["workspaces"].as_array().unwrap();
    assert_eq!(per_workspace.len(), 5, "the closed workspace is not listed");
    let fields = [
        "title",
        "color",
        "icon",
        "description",
        "task_status",
        "ephemeral",
        "kind",
        "app",
        "agent_folder",
        "name_source",
        "name_revision",
        "created_by",
        "key",
    ];
    for id in &ids[..4] {
        let value = per_workspace.iter().find(|value| value["id"] == id.as_str()).unwrap();
        for field in fields {
            assert!(value["extra"].get(field).is_some(), "{id} has no {field}: {value}");
        }
    }
    let bare = per_workspace.iter().find(|value| value["id"] == ids[4].as_str()).unwrap();
    assert!(bare["extra"].get("title").is_none() && bare["extra"].get("kind").is_none());
    let creators = ids[..4]
        .iter()
        .map(|id| {
            per_workspace.iter().find(|value| value["id"] == id.as_str()).unwrap()["extra"]
                ["created_by"]
                .clone()
        })
        .collect::<Vec<_>>();
    assert_eq!(creators[0], json!({"kind": "script", "session": "sess0"}), "closed creator");
    assert_eq!(creators[1]["workspace"], ids[0].as_str(), "live creator");

    let listed = resource(&mux, "workspace.list", json!({}));
    let expected_list = listed
        .as_array()
        .unwrap()
        .iter()
        .map(|value| per_workspace.iter().find(|each| each["id"] == value["id"]).cloned().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        serde_json::to_vec(&listed).unwrap(),
        serde_json::to_vec(&expected_list).unwrap(),
        "workspace.list, then the per-workspace path in the list's order"
    );
    let snapshot = resource(&mux, "session.snapshot", json!({}));
    for collection in ["workspaces", "screens", "tabs"] {
        assert_eq!(
            serde_json::to_vec(&snapshot[collection]).unwrap(),
            serde_json::to_vec(&each[collection]).unwrap(),
            "session.snapshot's {collection}, then the per-value path"
        );
    }
    mux.shutdown();
}
