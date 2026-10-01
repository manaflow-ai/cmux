//! Screen metadata (pinned, color, icon) and screen groups. Both are shared
//! layout state of the workspace's home session, keyed by public screen
//! ids; group ids are `sgrp_<32 hex>`. Order lives in the screen rows
//! themselves; the mux keeps pinned screens first and group members
//! contiguous when it reorders.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::new_uuid_v4;
use super::presentation_store::{
    validate_presentation_color, validate_presentation_icon, validate_tab_group_color,
    validate_tab_group_name,
};

pub fn new_screen_group_id() -> String {
    format!("sgrp_{}", new_uuid_v4().replace('-', ""))
}

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

pub(crate) fn screen_pinned(connection: &Connection, screen_id: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row("SELECT pinned FROM screen_state WHERE screen_id = ?1", [screen_id], |row| {
            row.get::<_, i64>(0)
        })
        .optional()?
        .is_some_and(|value| value != 0))
}

pub(crate) fn update_screen_meta(
    transaction: &Transaction<'_>,
    screen_id: &str,
    update: &ScreenMetaUpdate,
) -> anyhow::Result<()> {
    update.validate()?;
    transaction.execute("INSERT OR IGNORE INTO screen_state(screen_id) VALUES(?1)", [screen_id])?;
    if let Some(pinned) = update.pinned {
        transaction.execute(
            "UPDATE screen_state SET pinned = ?2 WHERE screen_id = ?1",
            params![screen_id, i64::from(pinned)],
        )?;
        if pinned {
            transaction
                .execute("DELETE FROM screen_group_members WHERE screen_id = ?1", [screen_id])?;
        }
    }
    if let Some(color) = &update.color {
        transaction.execute(
            "UPDATE screen_state SET color = ?2 WHERE screen_id = ?1",
            params![screen_id, color],
        )?;
    }
    if let Some(icon) = &update.icon {
        transaction.execute(
            "UPDATE screen_state SET icon = ?2 WHERE screen_id = ?1",
            params![screen_id, icon],
        )?;
    }
    transaction.execute(
        "DELETE FROM screen_state WHERE screen_id = ?1 AND pinned = 0 AND color IS NULL AND icon IS NULL",
        [screen_id],
    )?;
    Ok(())
}

/// One screen group row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ScreenGroupRecord {
    pub(crate) id: String,
    pub(crate) workspace_id: String,
    pub(crate) name: String,
    pub(crate) color: String,
    pub(crate) collapsed: bool,
}

pub(crate) fn screen_group(
    connection: &Connection,
    group_id: &str,
) -> anyhow::Result<Option<ScreenGroupRecord>> {
    Ok(connection
        .query_row(
            "SELECT group_id, workspace_id, name, color, collapsed FROM screen_groups WHERE group_id = ?1",
            [group_id],
            |row| {
                Ok(ScreenGroupRecord {
                    id: row.get(0)?,
                    workspace_id: row.get(1)?,
                    name: row.get(2)?,
                    color: row.get(3)?,
                    collapsed: row.get::<_, i64>(4)? != 0,
                })
            },
        )
        .optional()?)
}

pub(crate) fn put_screen_group(
    transaction: &Transaction<'_>,
    group: &ScreenGroupRecord,
) -> anyhow::Result<()> {
    validate_tab_group_name(&group.name)?;
    validate_tab_group_color(&group.color)?;
    transaction.execute(
        "INSERT INTO screen_groups(group_id, workspace_id, name, color, collapsed)
         VALUES(?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(group_id) DO UPDATE SET
           workspace_id = excluded.workspace_id, name = excluded.name,
           color = excluded.color, collapsed = excluded.collapsed",
        params![group.id, group.workspace_id, group.name, group.color, i64::from(group.collapsed)],
    )?;
    Ok(())
}

/// The group a screen belongs to.
pub(crate) fn screen_group_of(
    connection: &Connection,
    screen_id: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT group_id FROM screen_group_members WHERE screen_id = ?1",
            [screen_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

pub(crate) fn set_screen_group_member(
    transaction: &Transaction<'_>,
    screen_id: &str,
    group_id: Option<&str>,
) -> anyhow::Result<()> {
    match group_id {
        Some(group_id) => transaction.execute(
            "INSERT INTO screen_group_members(screen_id, group_id) VALUES(?1, ?2)
             ON CONFLICT(screen_id) DO UPDATE SET group_id = excluded.group_id",
            params![screen_id, group_id],
        )?,
        None => transaction
            .execute("DELETE FROM screen_group_members WHERE screen_id = ?1", [screen_id])?,
    };
    Ok(())
}

/// Live member screens of a group, in screen order.
pub(crate) fn screen_group_members(
    connection: &Connection,
    group_id: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT m.screen_id FROM screen_group_members AS m
         JOIN screen_groups AS g ON g.group_id = m.group_id
         JOIN resource_screens AS s ON s.public_id = m.screen_id
         WHERE m.group_id = ?1 AND s.workspace_id = g.workspace_id AND s.deleted_revision IS NULL
         ORDER BY s.position ASC",
    )?;
    Ok(statement
        .query_map([group_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?)
}

/// Drop a group and its memberships.
pub(crate) fn delete_screen_group(
    transaction: &Transaction<'_>,
    group_id: &str,
) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM screen_group_members WHERE group_id = ?1", [group_id])?;
    transaction.execute("DELETE FROM screen_groups WHERE group_id = ?1", [group_id])?;
    Ok(())
}

/// Drop groups left without live members. Returns the dropped ids.
pub(crate) fn prune_screen_groups(transaction: &Transaction<'_>) -> anyhow::Result<Vec<String>> {
    let ids = {
        let mut statement =
            transaction.prepare("SELECT group_id FROM screen_groups ORDER BY group_id")?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    let mut dropped = Vec::new();
    for id in ids {
        if screen_group_members(transaction, &id)?.is_empty() {
            delete_screen_group(transaction, &id)?;
            dropped.push(id);
        }
    }
    Ok(dropped)
}

/// The public `ScreenGroupSnapshot`, or `None` when the group is gone.
pub(crate) fn screen_group_snapshot(
    connection: &Connection,
    group_id: &str,
) -> anyhow::Result<Option<Value>> {
    let Some(group) = screen_group(connection, group_id)? else { return Ok(None) };
    let screens = screen_group_members(connection, group_id)?;
    if screens.is_empty() {
        return Ok(None);
    }
    Ok(Some(json!({
        "id": group.id,
        "workspace_id": group.workspace_id,
        "name": group.name,
        "color": group.color,
        "collapsed": group.collapsed,
        "screen_ids": screens,
    })))
}

/// Every live screen group, optionally of one workspace.
pub(crate) fn screen_group_snapshots(
    connection: &Connection,
    workspace_id: Option<&str>,
) -> anyhow::Result<Vec<Value>> {
    let ids = {
        let mut statement = connection.prepare(
            "SELECT g.group_id FROM screen_groups AS g
             WHERE ?1 IS NULL OR g.workspace_id = ?1
             ORDER BY g.workspace_id ASC, (
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
