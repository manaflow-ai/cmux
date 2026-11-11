//! The state fields of many workspaces, read together (`workspace_extras.rs`), are the fields
//! that the statements for one workspace gave, and each statement finds the rows of an id through
//! an index.
//!
//! The session of the equality test gets each kind of field through the operation that a client
//! sends: `workspace.update` (title, color, icon, description, task status), `workspace.create`
//! with `ephemeral`, `workspace.ensure_home` (kind), `workspace.agent_folder.set`,
//! `workspace.rename` (name provenance), `workspace.create` with `created_by` (one whose creator
//! lives, one whose creator is closed with `workspace.close`, one with no creator), and
//! `workspace_group.create` with `workspace.place` (a group; it adds no field to a value, the
//! workspace is in the session so that a grouped one is compared too). The one exception is the
//! app kind: `workspace.ensure_app` needs an installed app, so its row is written with the store
//! function that the operation uses (`EmptyWorkspaceMark::App`).

use std::collections::BTreeMap;

use rusqlite::{Connection, OptionalExtension};
use serde_json::{Map, json};

use super::home_store::EmptyWorkspaceMark;
use super::store::resource_upsert;
use super::tests::{empty_workspace, mutate, send, snapshot};
use super::values::{decorate_changes, decorate_value};
use super::workspace_extras::{STATEMENTS, workspace_extras};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

/// The state fields of one workspace, read with one statement for each state table and one id:
/// the code of `state/values.rs` (`workspace_extra`, with `home_store::workspace_kind`,
/// `agent_folder::agent_folder` and `created_by::snapshot`) before the batch read replaced it,
/// kept here as the reference.
fn fields_by_single_statements(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Map<String, Value>> {
    let mut fields = Map::new();
    let presentation = connection
        .query_row(
            "SELECT p.title, p.color, p.icon, p.description, p.task_status
             FROM resource_workspaces AS rw
             JOIN workspace_presentation AS p ON p.workspace_key = rw.workspace_key
             WHERE rw.public_id = ?1",
            [workspace_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .optional()?;
    if let Some((title, color, icon, description, task_status)) = presentation {
        let fields_of = [
            ("title", title),
            ("color", color),
            ("icon", icon),
            ("description", description),
            ("task_status", task_status),
        ];
        for (name, value) in fields_of {
            if let Some(value) = value {
                fields.insert(name.into(), json!(value));
            }
        }
    }
    let ephemeral = connection
        .query_row(
            "SELECT ephemeral FROM workspace_state WHERE workspace_id = ?1",
            [workspace_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .is_some_and(|value| value != 0);
    if ephemeral {
        fields.insert("ephemeral".into(), json!(true));
    }
    let kind = connection
        .query_row(
            "SELECT kind, app_id FROM workspace_kind WHERE workspace_id = ?1",
            [workspace_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .optional()?;
    if let Some((kind, app)) = kind {
        fields.insert("kind".into(), json!(kind));
        if let Some(app) = app {
            fields.insert("app".into(), json!(app));
        }
    }
    let agent_folder = connection
        .query_row(
            "SELECT path FROM workspace_agent_folder WHERE workspace_id = ?1",
            [workspace_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(path) = agent_folder {
        fields.insert("agent_folder".into(), json!(path));
    }
    let provenance = connection
        .query_row(
            "SELECT w.name_source, w.name_revision
             FROM resource_workspaces AS rw
             JOIN workspaces AS w ON w.workspace_key = rw.workspace_key
             WHERE rw.public_id = ?1",
            [workspace_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    if let Some((source, revision)) = provenance {
        let (source, revision) =
            crate::workspace_registry::workspace_name_store::stored_name_provenance(
                &source, revision,
            )?;
        fields.insert("name_source".into(), json!(source));
        fields.insert("name_revision".into(), json!(revision.to_string()));
    }
    let key = connection
        .query_row(
            "SELECT workspace_key FROM resource_workspaces WHERE public_id = ?1",
            [workspace_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(key) = key {
        let created_by = connection
            .query_row(
                "SELECT kind, creator_key, session FROM workspace_created_by
                 WHERE workspace_key = ?1",
                [key.as_str()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .optional()?;
        if let Some((kind, creator, session)) = created_by {
            let mut value = Map::new();
            value.insert("kind".into(), json!(kind));
            if let Some(creator) = creator {
                let id = connection
                    .query_row(
                        "SELECT public_id FROM resource_workspaces
                         WHERE workspace_key = ?1 AND deleted_revision IS NULL",
                        [creator.as_str()],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()?;
                if let Some(id) = id {
                    value.insert("workspace".into(), json!(id));
                }
            }
            if let Some(session) = session {
                value.insert("session".into(), json!(session));
            }
            fields.insert("created_by".into(), Value::Object(value));
        }
        fields.insert("key".into(), json!(key));
    }
    Ok(fields)
}

fn created(mux: &Arc<Mux>, name: &str, extra: Value) -> String {
    let mut params = json!({"name": name, "initial_content": "empty"});
    for (field, value) in extra.as_object().cloned().unwrap_or_default() {
        params[field] = value;
    }
    mutate(mux, "workspace.create", params, &format!("create-{name}"))["workspace_id"]
        .as_str()
        .unwrap()
        .to_string()
}

/// The workspaces of the session, by the kind of field that each one has.
struct Fields {
    shown: String,
    ephemeral: String,
    home: String,
    app: String,
    with_folder: String,
    creator: String,
    made_by_a_live_one: String,
    closed_creator: String,
    made_by_a_closed_one: String,
    folder_root: std::path::PathBuf,
    folder: String,
}

fn session_with_each_field(mux: &Arc<Mux>) -> Fields {
    let home = send(mux, "workspace.ensure_home", json!({}), Some("home")).unwrap();
    let home = home["value"]["workspace_id"].as_str().unwrap().to_string();
    let _plain = empty_workspace(mux, "plain");

    let shown = empty_workspace(mux, "shown");
    let presentation = json!({
        "workspace": shown,
        "title": "API server",
        "color": "#336699",
        "icon": "server.rack",
        "description": "notes",
        "task_status": "done",
    });
    mutate(mux, "workspace.update", presentation, "show");

    let ephemeral = created(mux, "ephemeral", json!({"ephemeral": true}));

    let with_folder = empty_workspace(mux, "with-folder");
    let folder_root = std::env::temp_dir()
        .join(format!("cmux-workspace-extras-{}", WorkspacePublicId::random().unwrap()));
    std::fs::create_dir_all(folder_root.join("project")).unwrap();
    let folder = std::fs::canonicalize(folder_root.join("project")).unwrap();
    let folder = folder.to_str().unwrap().to_string();
    let params = json!({"workspace": with_folder, "path": folder});
    mutate(mux, "workspace.agent_folder.set", params, "folder");

    let renamed = empty_workspace(mux, "before-the-rename");
    mutate(mux, "workspace.rename", json!({"workspace": renamed, "name": "renamed"}), "rename");

    let creator = empty_workspace(mux, "creator");
    let by_a_live_one = json!({"kind": "agent", "workspace": creator, "session": "s-1"});
    let made_by_a_live_one = created(mux, "child", json!({"created_by": by_a_live_one}));
    let closed_creator = empty_workspace(mux, "closed-creator");
    let by_a_closed_one = json!({"kind": "script", "workspace": closed_creator});
    let made_by_a_closed_one = created(mux, "orphan", json!({"created_by": by_a_closed_one}));
    let _made_by_a_person = created(mux, "person", json!({"created_by": {"kind": "person"}}));

    let grouped = empty_workspace(mux, "grouped");
    let group = mutate(mux, "workspace_group.create", json!({"name": "Work"}), "group")["id"]
        .as_str()
        .unwrap()
        .to_string();
    mutate(mux, "workspace.place", json!({"workspace": grouped, "group": group}), "place");

    let app = empty_workspace(mux, "app");

    // The creator of `made_by_a_closed_one` closes.
    mutate(mux, "workspace.close", json!({"workspace": closed_creator}), "close-the-creator");

    // The app kind, last (no operation runs after this write): the row that
    // `workspace.ensure_app` writes for its new workspace.
    {
        let registry = mux.workspace_registry.lock().unwrap();
        let connection = registry.connection.get();
        let transaction = connection.unchecked_transaction().unwrap();
        let key = transaction
            .query_row(
                "SELECT workspace_key FROM resource_workspaces WHERE public_id = ?1",
                [app.as_str()],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        EmptyWorkspaceMark::App("notes".into()).write(&transaction, &app, &key).unwrap();
        transaction.commit().unwrap();
    }

    Fields {
        shown,
        ephemeral,
        home,
        app,
        with_folder,
        creator,
        made_by_a_live_one,
        closed_creator,
        made_by_a_closed_one,
        folder_root,
        folder,
    }
}

/// The batch read gives each workspace the fields that the single statements give it, for every
/// kind of field, for a closed workspace and for an id that names nothing; the read of one id is
/// the read of many; and a change batch is decorated as its values are one by one.
#[test]
fn the_batch_read_gives_the_fields_of_the_single_statements() {
    let mux = Mux::new_for_test("workspace-extras-equal", SurfaceOptions::default());
    let fields = session_with_each_field(&mux);
    let snapshot = snapshot(&mux);
    let live = snapshot["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|workspace| workspace["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert!(live.len() >= 12, "the live workspaces of the session: {live:?}");
    assert!(!live.contains(&fields.closed_creator), "the creator is closed");
    let unknown = WorkspacePublicId::random().unwrap().to_string();
    let mut ids = live.iter().map(String::as_str).collect::<Vec<_>>();
    ids.extend([fields.closed_creator.as_str(), unknown.as_str()]);

    mux.read_registry_state(|connection| {
        let together = workspace_extras(connection, &ids)?;
        let mut expected = BTreeMap::new();
        for id in &ids {
            let single = fields_by_single_statements(connection, id)?;
            assert_eq!(
                together.get(*id).cloned().unwrap_or_default(),
                single,
                "workspace {id}: the batch read, then the single statements"
            );
            let alone = workspace_extras(connection, &[*id])?;
            assert_eq!(
                alone.get(*id),
                together.get(*id),
                "workspace {id}: read alone, then read with the others"
            );
            assert!(alone.len() <= 1, "workspace {id}: a read of one id gave {alone:?}");
            expected.insert((*id).to_string(), single);
        }
        assert!(!together.contains_key(&unknown), "an id that names no workspace has no fields");

        // The session has each kind of field, so the comparison above covers each statement.
        let shown = &expected[&fields.shown];
        assert_eq!(shown["title"], "API server");
        assert_eq!(shown["color"], "#336699");
        assert_eq!(shown["icon"], "server.rack");
        assert!(shown.contains_key("description") && shown.contains_key("task_status"));
        assert_eq!(expected[&fields.ephemeral]["ephemeral"], true);
        assert_eq!(expected[&fields.home]["kind"], "home");
        assert!(!expected[&fields.home].contains_key("app"));
        assert_eq!(expected[&fields.app]["kind"], "app");
        assert_eq!(expected[&fields.app]["app"], "notes");
        assert_eq!(expected[&fields.with_folder]["agent_folder"], fields.folder);
        for id in &live {
            let stated = &expected[id];
            for name in ["name_source", "name_revision", "key"] {
                assert!(stated.contains_key(name), "workspace {id} has no {name}: {stated:?}");
            }
        }
        assert_eq!(
            expected[&fields.made_by_a_live_one]["created_by"],
            json!({"kind": "agent", "workspace": fields.creator, "session": "s-1"}),
            "the creator lives"
        );
        assert_eq!(
            expected[&fields.made_by_a_closed_one]["created_by"],
            json!({"kind": "script"}),
            "the creator is closed: no `workspace`"
        );
        let stored_creator: Option<String> = connection.query_row(
            "SELECT c.creator_key FROM workspace_created_by AS c
             JOIN resource_workspaces AS rw ON rw.workspace_key = c.workspace_key
             WHERE rw.public_id = ?1",
            [fields.made_by_a_closed_one.as_str()],
            |row| row.get(0),
        )?;
        assert!(stored_creator.is_some(), "the row still names the closed creator");

        // A change batch: each workspace value (one of them two times), a delete, and the
        // session's screens and tabs, decorated together and one by one.
        let mut stated = ids.clone();
        stated.push(fields.shown.as_str());
        let mut changes = stated
            .iter()
            .map(|id| resource_upsert("workspace", id, json!({"id": id, "name": "a name"})))
            .collect::<Vec<_>>();
        changes.push(json!({"kind": "delete", "sequence": 0, "resource": "workspace",
            "id": fields.closed_creator}));
        for (collection, resource) in [("screens", "screen"), ("tabs", "tab")] {
            for value in snapshot[collection].as_array().cloned().unwrap_or_default() {
                let id = value["id"].as_str().unwrap_or_default().to_string();
                changes.push(resource_upsert(resource, &id, value));
            }
        }
        let mut one_by_one = changes.clone();
        for change in &mut one_by_one {
            if change["kind"] == "upsert" {
                let resource = change["resource"].as_str().unwrap_or_default().to_string();
                decorate_value(connection, &resource, &mut change["value"])?;
            }
        }
        let mut together = Value::Array(changes);
        decorate_changes(connection, &mut together)?;
        assert_eq!(together, Value::Array(one_by_one), "a change batch, then each of its values");
        let decorated = together.as_array().unwrap();
        assert_eq!(decorated[0]["value"]["extra"], Value::Object(expected[ids[0]].clone()));
        Ok(())
    })
    .unwrap();
    let _ = std::fs::remove_dir_all(&fields.folder_root);
}

/// Each statement of the batch read goes through the ids one time and finds the rows of each id
/// with a search by a key: no scan of a table for each id and no index that SQLite builds for
/// the query. The number of searches is the number of tables that the statement joins.
#[test]
fn each_statement_of_the_batch_read_searches_by_a_key() {
    let mux = Mux::new_for_test("workspace-extras-plan", SurfaceOptions::default());
    let _workspace = empty_workspace(&mux, "one");
    let joined_tables = [
        ("presentation", 2),
        ("ephemeral", 1),
        ("kind", 1),
        ("agent folder", 1),
        ("name", 2),
        ("created by", 3),
        ("key", 1),
    ];
    mux.read_registry_state(|connection| {
        for ((name, sql), (expected_name, tables)) in STATEMENTS.into_iter().zip(joined_tables) {
            assert_eq!(name, expected_name, "the statements, in their order");
            let mut statement = connection.prepare(&format!("EXPLAIN QUERY PLAN {sql}"))?;
            let plan = statement
                .query_map(["[]"], |row| row.get::<_, String>(3))?
                .collect::<Result<Vec<_>, _>>()?;
            eprintln!("query plan, {name}: {plan:?}");
            let scans = plan.iter().filter(|step| step.starts_with("SCAN")).collect::<Vec<_>>();
            assert_eq!(scans.len(), 1, "{name}: one scan, of the ids: {plan:?}");
            assert!(scans[0].starts_with("SCAN entry"), "{name}: the scan is of the ids: {plan:?}");
            assert!(
                !plan.iter().any(|step| step.contains("AUTOMATIC")),
                "{name}: an index built for the query: {plan:?}"
            );
            let searches = plan
                .iter()
                .filter(|step| step.starts_with("SEARCH ") && step.contains(" USING "))
                .count();
            assert_eq!(searches, tables, "{name}: one search by a key for each table: {plan:?}");
        }
        Ok(())
    })
    .unwrap();
}
