//! Public values of workspaces, screens, and tabs with their state fields.
//!
//! The state rows (workspace identity, pins, groups, zoom, browser history)
//! surface in each snapshot's `extra` map. [`decorate_changes`] runs on every
//! resource journal batch, so an upsert from any path (a topology move, a
//! rename, a state mutation) carries the same fields a fresh snapshot shows,
//! and a client that replaces a value never loses them.

use std::collections::{HashMap, HashSet};

use rusqlite::{Connection, OptionalExtension};
use serde_json::{Map, Value, json};

use super::store::resource_upsert;
use super::workspace_extras::workspace_extras;
use crate::resource::SessionPublicId;
use crate::workspace_registry::resource_store::{load_resource_topology, load_tab_with_focus};
use crate::workspace_registry::{meta_value, required_meta};

mod tab_extra;

fn extra_mut(value: &mut Value) -> Option<&mut Map<String, Value>> {
    let object = value.as_object_mut()?;
    let extra = object.entry("extra").or_insert_with(|| Value::Object(Map::new()));
    extra.as_object_mut()
}

fn merge_extra(value: &mut Value, fields: Map<String, Value>) {
    if fields.is_empty() {
        return;
    }
    if let Some(extra) = extra_mut(value) {
        extra.extend(fields);
    }
}

/// The state fields of one workspace: the batch read with one id, so a value has the same fields
/// however it is decorated.
fn workspace_extra(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Map<String, Value>> {
    let mut extras = workspace_extras(connection, &[workspace_id])?;
    Ok(extras.remove(workspace_id).unwrap_or_default())
}

/// `connection.query_row` on the connection's prepared-statement cache: a
/// point read that runs once for each row of a list (a scoped tab list, the
/// screens of a snapshot, each upsert of a change batch) compiles its
/// statement once per connection, not once per row. Same statement, same row.
pub(crate) fn query_row_cached<T, P: rusqlite::Params>(
    connection: &Connection,
    sql: &str,
    params: P,
    read: impl FnOnce(&rusqlite::Row<'_>) -> rusqlite::Result<T>,
) -> rusqlite::Result<T> {
    connection.prepare_cached(sql)?.query_row(params, read)
}

fn screen_extra(connection: &Connection, screen_id: &str) -> anyhow::Result<Map<String, Value>> {
    let mut fields = Map::new();
    let state = query_row_cached(
        connection,
        "SELECT pinned, color, icon FROM screen_presentation WHERE screen_id = ?1",
        [screen_id],
        |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        },
    )
    .optional()?;
    if let Some((pinned, color, icon)) = state {
        if pinned != 0 {
            fields.insert("pinned".into(), json!(true));
        }
        if let Some(color) = color {
            fields.insert("color".into(), json!(color));
        }
        if let Some(icon) = icon {
            fields.insert("icon".into(), json!(icon));
        }
    }
    let group = query_row_cached(
        connection,
        "SELECT m.group_id
             FROM screen_group_members AS m
             JOIN screen_groups AS g ON g.group_id = m.group_id
             WHERE m.screen_id = ?1",
        [screen_id],
        |row| row.get::<_, String>(0),
    )
    .optional()?;
    if let Some(group) = group {
        fields.insert("screen_group_id".into(), json!(group));
    }
    Ok(fields)
}

/// Add the state fields of one public value in place.
pub(crate) fn decorate_value(
    connection: &Connection,
    resource: &str,
    value: &mut Value,
) -> anyhow::Result<()> {
    let Some(id) = value["id"].as_str().map(str::to_string) else { return Ok(()) };
    let fields = match resource {
        "workspace" => workspace_extra(connection, &id)?,
        "tab" => tab_extra::tab_extra(connection, &id)?,
        "screen" => screen_extra(connection, &id)?,
        _ => return Ok(()),
    };
    if resource == "tab" {
        merge_tab_extra(value, fields);
    } else {
        merge_extra(value, fields);
    }
    Ok(())
}

/// Add the state fields of a tab to its public value.
fn merge_tab_extra(value: &mut Value, fields: Map<String, Value>) {
    // The canonical kind of a conversation tab; connections without
    // `conversation-tabs-v1` see `browser` (server/conversation_tabs_wire.rs).
    if fields.contains_key("conversation") {
        value["content_kind"] = json!(super::conversation_tabs_store::CONVERSATION_KIND);
    }
    merge_extra(value, fields);
}

/// How many `tab_state` rows a session-wide tab list holds after its read.
#[cfg(test)]
pub(crate) fn session_tab_state_rows(connection: &Connection) -> anyhow::Result<usize> {
    Ok(tab_extra::SessionTabExtras::read(connection)?.state_rows())
}

/// Add the state fields of every tab of a session-wide list in place: what
/// [`decorate_value`] adds to each, with each state table read one time for
/// the list, not one time for each tab. Run it in the read transaction that
/// loaded `tabs`.
pub(crate) fn decorate_session_tabs(
    connection: &Connection,
    tabs: &mut [Value],
) -> anyhow::Result<()> {
    let mut extras = tab_extra::SessionTabExtras::read(connection)?;
    for tab in tabs {
        let Some(id) = tab["id"].as_str().map(str::to_string) else { continue };
        let fields = extras.take(&id)?;
        merge_tab_extra(tab, fields);
    }
    Ok(())
}

/// `change` is an upsert of a `resource` value.
fn is_upsert_of(change: &Value, resource: &str) -> bool {
    let field = |name: &str| change.get(name).and_then(Value::as_str);
    field("kind") == Some("upsert") && field("resource") == Some(resource)
}

/// Decorate every ordinary upsert of a change batch. The workspace upserts are read together, with
/// a fixed number of statements for all of them (`state/workspace_extras.rs`): a close states each
/// workspace after the closed one again.
pub(crate) fn decorate_changes(connection: &Connection, changes: &mut Value) -> anyhow::Result<()> {
    let Some(changes) = changes.as_array_mut() else { return Ok(()) };
    if !super::store::state_tables_ready(connection)? {
        return Ok(());
    }
    let workspaces = {
        let ids = changes
            .iter()
            .filter(|change| is_upsert_of(change, "workspace"))
            .filter_map(|change| change.get("value")?.get("id")?.as_str())
            .collect::<Vec<_>>();
        workspace_extras(connection, &ids)?
    };
    for change in changes {
        if change["kind"] != "upsert" {
            continue;
        }
        let resource = change["resource"].as_str().unwrap_or_default().to_string();
        let Some(value) = change.get_mut("value") else { continue };
        if resource == "workspace" {
            let id = value.get("id").and_then(Value::as_str);
            let fields = id.and_then(|id| workspaces.get(id)).cloned();
            if let Some(fields) = fields {
                merge_extra(value, fields);
            }
        } else {
            decorate_value(connection, &resource, value)?;
        }
    }
    Ok(())
}

/// Decorate the workspace, screen, and tab arrays of a session snapshot.
pub(crate) fn decorate_snapshot(
    connection: &Connection,
    snapshot: &mut Value,
) -> anyhow::Result<()> {
    for (collection, resource) in
        [("workspaces", "workspace"), ("screens", "screen"), ("tabs", "tab")]
    {
        if let Some(values) = snapshot[collection].as_array_mut() {
            for value in values {
                decorate_value(connection, resource, value)?;
            }
        }
    }
    Ok(())
}

/// The public value of a live workspace, decorated, or `None` when it is gone.
pub(crate) fn workspace_value(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Option<Value>> {
    let row = connection
        .query_row(
            "SELECT w.name, w.position
             FROM resource_workspaces AS rw
             JOIN workspaces AS w ON w.workspace_key = rw.workspace_key
             WHERE rw.public_id = ?1 AND w.tombstoned = 0 AND rw.deleted_revision IS NULL",
            [workspace_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let Some((name, position)) = row else { return Ok(None) };
    let index: i64 = connection.query_row(
        "SELECT COUNT(*) FROM workspaces WHERE tombstoned = 0 AND position < ?1",
        [position],
        |row| row.get(0),
    )?;
    let focused = meta_value(connection, "active_workspace_id")?.as_deref() == Some(workspace_id);
    let mut value = json!({
        "id": workspace_id,
        "session_id": required_meta(connection, "session_public_id")?,
        "name": name,
        "index": index,
        "focused": focused,
    });
    decorate_value(connection, "workspace", &mut value)?;
    Ok(Some(value))
}

/// Fresh decorated upserts for the named live workspaces, screens, and tabs,
/// read inside the caller's transaction after its writes. Gone ids yield
/// nothing.
///
/// A tab is read by point reads (its row and its pane's active tab), so a
/// restatement of tabs costs the same on a session of any size. Only a
/// screen's value, which names its panes and their tabs, reads the stored
/// topology.
pub(crate) fn fresh_upserts(
    connection: &Connection,
    workspaces: &[String],
    screens: &[String],
    tabs: &[String],
) -> anyhow::Result<Vec<Value>> {
    let mut changes = Vec::new();
    for workspace in workspaces {
        if let Some(value) = workspace_value(connection, workspace)? {
            changes.push(resource_upsert("workspace", workspace, value));
        }
    }
    if !screens.is_empty() {
        let session_id = SessionPublicId::parse(required_meta(connection, "session_public_id")?)?;
        let topology = load_resource_topology(connection, session_id, String::new())?;
        let tabs_by_pane = crate::resource_screen::tabs_by_pane(&topology.tabs);
        let panes_by_id =
            topology.panes.iter().map(|pane| (&pane.public_id, pane)).collect::<HashMap<_, _>>();
        let wanted_screens = screens.iter().map(String::as_str).collect::<HashSet<_>>();
        for screen in topology
            .screens
            .iter()
            .filter(|screen| wanted_screens.contains(screen.public_id.as_str()))
        {
            let mut value = crate::resource_screen::public_screen_value(
                &topology,
                screen,
                &tabs_by_pane,
                &panes_by_id,
            )?;
            decorate_value(connection, "screen", &mut value)?;
            changes.push(resource_upsert("screen", screen.public_id.as_str(), value));
        }
    }
    let mut wanted_tabs = HashSet::new();
    let mut rows = Vec::new();
    for tab in tabs {
        if wanted_tabs.insert(tab.as_str())
            && let Some(row) = load_tab_with_focus(connection, tab)?
        {
            rows.push(row);
        }
    }
    // The order the stored topology lists them in: by pane, then position.
    rows.sort_by(|(left, _), (right, _)| {
        (left.pane_id.as_str(), left.position).cmp(&(right.pane_id.as_str(), right.position))
    });
    for (tab, focused) in rows {
        let mut value = tab.public_value(focused);
        decorate_value(connection, "tab", &mut value)?;
        changes.push(resource_upsert("tab", tab.public_id.as_str(), value));
    }
    Ok(changes)
}

/// The value a fresh upsert list holds for `(resource, id)`.
pub(crate) fn upserted_value(changes: &[Value], resource: &str, id: &str) -> Option<Value> {
    changes
        .iter()
        .rev()
        .find(|change| {
            change["kind"] == "upsert" && change["resource"] == resource && change["id"] == id
        })
        .map(|change| change["value"].clone())
}

/// The session's own registry id (the personal-state session key).
pub(crate) fn local_registry_id(connection: &Connection) -> anyhow::Result<String> {
    required_meta(connection, "registry_id")
}

/// The live public id of this session's workspace `workspace_key`.
pub(crate) fn workspace_public_id_for_key(
    connection: &Connection,
    workspace_key: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT public_id FROM resource_workspaces
             WHERE workspace_key = ?1 AND deleted_revision IS NULL",
            [workspace_key],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// A session-qualified personal workspace reference in its public form.
pub(crate) fn workspace_ref(
    connection: &Connection,
    local_session: &str,
    session_id: &str,
    workspace_key: &str,
) -> anyhow::Result<Value> {
    let workspace_id = if session_id == local_session {
        workspace_public_id_for_key(connection, workspace_key)?
    } else {
        None
    };
    Ok(json!({
        "session_id": session_id,
        "workspace_ref": workspace_key,
        "workspace_id": workspace_id,
    }))
}
