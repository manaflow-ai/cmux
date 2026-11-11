//! The state fields of workspace values (`extra`), read for many workspaces at one time.
//!
//! A workspace value shows its state rows in `extra`: its presentation (title, color, icon,
//! description, task status), the ephemeral flag, its kind and app, its agent folder, the
//! provenance of its name, who made it, and its key. Reading them takes one statement for each
//! state table (7 statements), whatever the number of workspaces: each statement takes the ids as
//! one JSON array (`json_each`) and finds the rows of each id through the primary key of each
//! table that it joins. A change batch that states many workspaces (a close states each workspace
//! after the closed one again, because its index changed) therefore reads their fields with 7
//! statements, not with 7 for each workspace.
//!
//! One workspace is read with the same statements and one id (`state/values.rs`), so there is one
//! code path and one result for a value, however it is decorated.
//!
//! `CROSS JOIN` keeps the order of the loops as written: the ids are the outer loop and each
//! table is searched by its key. `workspace_extras_tests.rs` asserts the query plans.

use std::collections::HashMap;

use rusqlite::{Connection, Row};
use serde_json::{Map, Value, json};

/// `workspace-description-v1`, `workspace-status-v1` and the identity fields: absent until set.
const PRESENTATION: &str =
    "SELECT entry.value, p.title, p.color, p.icon, p.description, p.task_status
     FROM json_each(?1) AS entry
     CROSS JOIN resource_workspaces AS rw ON rw.public_id = entry.value
     CROSS JOIN workspace_presentation AS p ON p.workspace_key = rw.workspace_key";

const EPHEMERAL: &str = "SELECT entry.value, s.ephemeral
     FROM json_each(?1) AS entry
     CROSS JOIN workspace_state AS s ON s.workspace_id = entry.value";

/// `workspace-kind-v1`: no row for a normal workspace. `app-screens-v1`: the app of an app
/// workspace.
const KIND: &str = "SELECT entry.value, k.kind, k.app_id
     FROM json_each(?1) AS entry
     CROSS JOIN workspace_kind AS k ON k.workspace_id = entry.value";

/// AGENT-CWD-FOR-FOLDERLESS-WORKSPACE: no row until the user chose a folder.
const AGENT_FOLDER: &str = "SELECT entry.value, f.path
     FROM json_each(?1) AS entry
     CROSS JOIN workspace_agent_folder AS f ON f.workspace_id = entry.value";

/// `workspace-name-source-v1`: who chose the name and its revision, from the one stored row.
const NAME: &str = "SELECT entry.value, w.name_source, w.name_revision
     FROM json_each(?1) AS entry
     CROSS JOIN resource_workspaces AS rw ON rw.public_id = entry.value
     CROSS JOIN workspaces AS w ON w.workspace_key = rw.workspace_key";

/// `workspace-created-by-v1`: no row for a workspace made before it. The creator's public id is
/// NULL when the row names no creator or when that workspace does not live.
const CREATED_BY: &str = "SELECT entry.value, c.kind, c.session, creator.public_id
     FROM json_each(?1) AS entry
     CROSS JOIN resource_workspaces AS rw ON rw.public_id = entry.value
     CROSS JOIN workspace_created_by AS c ON c.workspace_key = rw.workspace_key
     LEFT JOIN resource_workspaces AS creator
       ON creator.workspace_key = c.creator_key AND creator.deleted_revision IS NULL";

/// The workspace's key: what its terminals and agent chats carry as `CMUX_WORKSPACE_ID`
/// (cx-ncc.96: `cmux agents chat` scopes chats by it).
const KEY: &str = "SELECT entry.value, rw.workspace_key
     FROM json_each(?1) AS entry
     CROSS JOIN resource_workspaces AS rw ON rw.public_id = entry.value";

/// Every statement that [`workspace_extras`] runs, in the order it runs them.
#[cfg(test)]
pub(crate) const STATEMENTS: [(&str, &str); 7] = [
    ("presentation", PRESENTATION),
    ("ephemeral", EPHEMERAL),
    ("kind", KIND),
    ("agent folder", AGENT_FOLDER),
    ("name", NAME),
    ("created by", CREATED_BY),
    ("key", KEY),
];

type Extras = HashMap<String, Map<String, Value>>;

/// Run `sql` with the ids and give each row, with the fields of its workspace, to `add`.
fn read(
    connection: &Connection,
    sql: &str,
    ids: &str,
    extras: &mut Extras,
    mut add: impl FnMut(&Row<'_>, &mut Map<String, Value>) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let mut statement = connection.prepare(sql)?;
    let mut rows = statement.query([ids])?;
    while let Some(row) = rows.next()? {
        let id = row.get::<_, String>(0)?;
        add(row, extras.entry(id).or_default())?;
    }
    Ok(())
}

/// The state fields of each of the workspaces `ids` (public ids), by id. An id with no state row
/// has no entry. The fields of one workspace are added in the order of the statements: title,
/// color, icon, description, task_status, ephemeral, kind, app, agent_folder, name_source,
/// name_revision, created_by, key.
pub(crate) fn workspace_extras(connection: &Connection, ids: &[&str]) -> anyhow::Result<Extras> {
    let mut extras = Extras::new();
    if ids.is_empty() {
        return Ok(extras);
    }
    let ids = serde_json::to_string(ids)?;
    read(connection, PRESENTATION, &ids, &mut extras, |row, fields| {
        let columns = ["title", "color", "icon", "description", "task_status"];
        for (column, name) in (1_usize..).zip(columns) {
            if let Some(value) = row.get::<_, Option<String>>(column)? {
                fields.insert(name.into(), json!(value));
            }
        }
        Ok(())
    })?;
    read(connection, EPHEMERAL, &ids, &mut extras, |row, fields| {
        if row.get::<_, i64>(1)? != 0 {
            fields.insert("ephemeral".into(), json!(true));
        }
        Ok(())
    })?;
    read(connection, KIND, &ids, &mut extras, |row, fields| {
        fields.insert("kind".into(), json!(row.get::<_, String>(1)?));
        if let Some(app) = row.get::<_, Option<String>>(2)? {
            fields.insert("app".into(), json!(app));
        }
        Ok(())
    })?;
    read(connection, AGENT_FOLDER, &ids, &mut extras, |row, fields| {
        fields.insert("agent_folder".into(), json!(row.get::<_, String>(1)?));
        Ok(())
    })?;
    read(connection, NAME, &ids, &mut extras, |row, fields| {
        let (source, revision) =
            crate::workspace_registry::workspace_name_store::stored_name_provenance(
                &row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            )?;
        fields.insert("name_source".into(), json!(source));
        // A decimal string, like a tab's.
        fields.insert("name_revision".into(), json!(revision.to_string()));
        Ok(())
    })?;
    read(connection, CREATED_BY, &ids, &mut extras, |row, fields| {
        let created_by = super::created_by::snapshot_value(
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<String>>(2)?,
        );
        fields.insert("created_by".into(), created_by);
        Ok(())
    })?;
    read(connection, KEY, &ids, &mut extras, |row, fields| {
        fields.insert("key".into(), json!(row.get::<_, String>(1)?));
        Ok(())
    })?;
    Ok(extras)
}
