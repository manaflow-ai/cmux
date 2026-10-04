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
use crate::resource::SessionPublicId;
use crate::workspace_registry::resource_store::load_resource_topology;
use crate::workspace_registry::{meta_value, required_meta};

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

fn workspace_extra(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Map<String, Value>> {
    let mut fields = Map::new();
    let presentation = connection
        .query_row(
            "SELECT p.title, p.color, p.icon
             FROM resource_workspaces AS rw
             JOIN workspace_presentation AS p ON p.workspace_key = rw.workspace_key
             WHERE rw.public_id = ?1",
            [workspace_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .optional()?;
    if let Some((title, color, icon)) = presentation {
        for (name, value) in [("title", title), ("color", color), ("icon", icon)] {
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
    // `workspace-kind-v1`: absent for a normal workspace.
    if let Some(kind) = super::home_store::workspace_kind(connection, workspace_id)? {
        fields.insert("kind".into(), json!(kind));
    }
    super::app_screens_store::workspace_extra(connection, workspace_id, &mut fields)?;
    Ok(fields)
}

fn tab_extra(connection: &Connection, tab_id: &str) -> anyhow::Result<Map<String, Value>> {
    let mut fields = Map::new();
    let pinned = connection
        .query_row("SELECT pinned FROM tab_presentation WHERE tab_id = ?1", [tab_id], |row| {
            row.get::<_, i64>(0)
        })
        .optional()?
        .is_some_and(|value| value != 0);
    if pinned {
        fields.insert("pinned".into(), json!(true));
    }
    let group = connection
        .query_row(
            "SELECT m.group_id
             FROM tab_group_members AS m
             JOIN tab_groups AS g ON g.group_id = m.group_id
             JOIN resource_tabs AS t ON t.public_id = m.tab_id AND t.pane_id = g.pane_id
             WHERE m.tab_id = ?1",
            [tab_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(group) = group {
        fields.insert("tab_group_id".into(), json!(group));
    }
    let state = connection
        .query_row(
            "SELECT zoom, back_json, forward_json FROM tab_state WHERE tab_id = ?1",
            [tab_id],
            |row| {
                Ok((
                    row.get::<_, Option<f64>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .optional()?;
    if let Some((zoom, back, forward)) = state {
        if let Some(zoom) = zoom {
            fields.insert("zoom".into(), json!(zoom));
        }
        for (name, list) in [("back", back), ("forward", forward)] {
            if let Some(list) = list {
                fields.insert(name.into(), serde_json::from_str(&list)?);
            }
        }
    }
    // The install id of the app that hosts a frontend-rendered browser.
    let owner = connection
        .query_row(
            "SELECT f.owner FROM resource_tabs AS t
             JOIN frontend_browser_tabs AS f ON f.browser_id = t.content_id
             WHERE t.public_id = ?1",
            [tab_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten();
    if let Some(owner) = owner {
        fields.insert("owner".into(), json!(owner));
    }
    // `conversation-tabs-v1`: the conversation a frontend tab shows.
    let conversation = connection
        .query_row(
            "SELECT c.conversation, c.owner FROM resource_tabs AS t
             JOIN conversation_tabs AS c ON c.browser_id = t.content_id
             WHERE t.public_id = ?1",
            [tab_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    if let Some((conversation, owner)) = conversation {
        fields.insert("conversation".into(), json!({"conversation": conversation, "owner": owner}));
    }
    // A keep-layout record (`end-terminals-keep-layout-v1`): restart a shell
    // in `cwd`. Absent (null) for every other tab, like the other extras.
    super::app_screens_store::tab_extra(connection, tab_id, &mut fields)?;
    let relaunch = super::kept_tab_store::relaunch_value(connection, tab_id)?;
    if !relaunch.is_null() {
        fields.insert("relaunch".into(), relaunch);
    }
    Ok(fields)
}

fn screen_extra(connection: &Connection, screen_id: &str) -> anyhow::Result<Map<String, Value>> {
    let mut fields = Map::new();
    let state = connection
        .query_row(
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
    let group = connection
        .query_row(
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
    super::app_screens_store::screen_extra(connection, screen_id, &mut fields)?;
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
        "tab" => tab_extra(connection, &id)?,
        "screen" => screen_extra(connection, &id)?,
        _ => return Ok(()),
    };
    // The canonical kind of a conversation tab; connections without
    // `conversation-tabs-v1` see `browser` (server/conversation_tabs_wire.rs).
    if resource == "tab" && fields.contains_key("conversation") {
        value["content_kind"] = json!(super::conversation_tabs_store::CONVERSATION_KIND);
    }
    // `app-screens-v1`: the canonical kind of an app tab.
    if resource == "tab" && fields.contains_key("app") {
        value["content_kind"] = json!(super::app_screens_store::APP_KIND);
    }
    merge_extra(value, fields);
    Ok(())
}

/// Decorate every ordinary upsert of a change batch.
pub(crate) fn decorate_changes(connection: &Connection, changes: &mut Value) -> anyhow::Result<()> {
    let Some(changes) = changes.as_array_mut() else { return Ok(()) };
    if !super::store::state_tables_ready(connection)? {
        return Ok(());
    }
    for change in changes {
        if change["kind"] != "upsert" {
            continue;
        }
        let resource = change["resource"].as_str().unwrap_or_default().to_string();
        if let Some(value) = change.get_mut("value") {
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
    if screens.is_empty() && tabs.is_empty() {
        return Ok(changes);
    }
    let session_id = SessionPublicId::parse(required_meta(connection, "session_public_id")?)?;
    let topology = load_resource_topology(connection, session_id, String::new())?;
    let tabs_by_pane = crate::resource_screen::tabs_by_pane(&topology.tabs);
    let panes_by_id =
        topology.panes.iter().map(|pane| (&pane.public_id, pane)).collect::<HashMap<_, _>>();
    let wanted_screens = screens.iter().map(String::as_str).collect::<HashSet<_>>();
    for screen in
        topology.screens.iter().filter(|screen| wanted_screens.contains(screen.public_id.as_str()))
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
    let wanted_tabs = tabs.iter().map(String::as_str).collect::<HashSet<_>>();
    for tab in topology.tabs.iter().filter(|tab| wanted_tabs.contains(tab.public_id.as_str())) {
        let focused = panes_by_id
            .get(&tab.pane_id)
            .is_some_and(|pane| pane.active_tab.as_ref() == Some(&tab.public_id));
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
