//! The public state-resource view of screen presentation and screen groups
//! (`screen_group` snapshots, the screen fields of `screen.update`), read
//! from the one storage `screen_store` owns: `screen_presentation`,
//! `screen_groups` (keyed by the stable workspace key), and
//! `screen_group_members`. The raw screen commands and the v2 operations
//! write those rows through the same commit (`state/screens.rs`).

use rusqlite::{Connection, OptionalExtension, Transaction};
use serde_json::{Value, json};

use crate::workspace_registry::presentation_store::{
    validate_presentation_color, validate_presentation_icon,
};
use crate::workspace_registry::screen_store::ScreenPresentationState;

/// A partial screen metadata update: `None` keeps a field, `Some(None)`
/// clears it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ScreenMetaUpdate {
    pub(crate) pinned: Option<bool>,
    pub(crate) color: Option<Option<String>>,
    pub(crate) icon: Option<Option<String>>,
}

impl ScreenMetaUpdate {
    pub(crate) fn validate(&self) -> anyhow::Result<()> {
        if let Some(Some(color)) = &self.color {
            validate_presentation_color(color)?;
        }
        if let Some(Some(icon)) = &self.icon {
            validate_presentation_icon(icon)?;
        }
        Ok(())
    }
}

/// Replace the screen rows in the caller's transaction.
pub(crate) fn write_screen_rows(
    transaction: &Transaction<'_>,
    state: &ScreenPresentationState,
) -> anyhow::Result<()> {
    crate::workspace_registry::screen_store::write_screen_state(transaction, state)
}

/// Live member screens of a group, in screen order, within the group's
/// workspace.
pub(crate) fn screen_group_members(
    connection: &Connection,
    group_id: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT m.screen_id FROM screen_group_members AS m
         JOIN screen_groups AS g ON g.group_id = m.group_id
         JOIN resource_workspaces AS w ON w.workspace_key = g.workspace_key
         JOIN resource_screens AS s ON s.public_id = m.screen_id
         WHERE m.group_id = ?1 AND s.workspace_id = w.public_id
           AND s.deleted_revision IS NULL AND w.deleted_revision IS NULL
         ORDER BY s.position ASC",
    )?;
    Ok(statement
        .query_map([group_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?)
}

/// The public `ScreenGroupSnapshot`, or `None` when the group is gone or has
/// no live member.
pub(crate) fn screen_group_snapshot(
    connection: &Connection,
    group_id: &str,
) -> anyhow::Result<Option<Value>> {
    let Some((workspace_id, name, color, collapsed, saved_id)) = connection
        .query_row(
            "SELECT w.public_id, g.name, g.color, g.collapsed, g.saved_id
             FROM screen_groups AS g
             JOIN resource_workspaces AS w ON w.workspace_key = g.workspace_key
             WHERE g.group_id = ?1 AND w.deleted_revision IS NULL",
            [group_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)? != 0,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .optional()?
    else {
        return Ok(None);
    };
    let screens = screen_group_members(connection, group_id)?;
    if screens.is_empty() {
        return Ok(None);
    }
    let mut snapshot = json!({
        "id": group_id,
        "workspace_id": workspace_id,
        "name": name,
        "color": color,
        "collapsed": collapsed,
        "screen_ids": screens,
    });
    if let Some(saved_id) = saved_id {
        snapshot["saved_id"] = json!(saved_id);
    }
    Ok(Some(snapshot))
}

/// Every live screen group, optionally of one workspace (public id), by
/// workspace and then by the position of the group's first member.
pub(crate) fn screen_group_snapshots(
    connection: &Connection,
    workspace_id: Option<&str>,
) -> anyhow::Result<Vec<Value>> {
    let ids = {
        let mut statement = connection.prepare(
            "SELECT g.group_id FROM screen_groups AS g
             JOIN resource_workspaces AS w ON w.workspace_key = g.workspace_key
             WHERE w.deleted_revision IS NULL AND (?1 IS NULL OR w.public_id = ?1)
             ORDER BY w.public_id ASC, (
               SELECT MIN(s.position) FROM screen_group_members AS m
               JOIN resource_screens AS s ON s.public_id = m.screen_id
               WHERE m.group_id = g.group_id AND s.deleted_revision IS NULL
             ) ASC, g.group_id ASC",
        )?;
        statement
            .query_map([workspace_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut groups = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(group) = screen_group_snapshot(connection, &id)? {
            groups.push(group);
        }
    }
    Ok(groups)
}
