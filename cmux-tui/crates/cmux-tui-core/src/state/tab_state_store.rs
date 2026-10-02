//! Tab state rows of the v2 state resources: pins, per-tab zoom and browser
//! back/forward lists, the public tab group snapshots, and the personal
//! saved tab groups.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use crate::workspace_registry::presentation_store::{
    SavedTabGroupRecord, SavedTabMember, TabGroupState, delete_saved_tab_group_in,
    put_saved_tab_group_in, read_saved_tab_groups, write_tab_group_state,
};

/// URLs one back or forward list keeps.
pub(crate) const MAX_HISTORY_URLS: usize = 20;
pub(crate) const MIN_ZOOM: f64 = 0.25;
pub(crate) const MAX_ZOOM: f64 = 5.0;

/// Store a tab placement's pinned flag. Returns whether it changed.
pub(crate) fn set_tab_pinned(
    transaction: &Transaction<'_>,
    tab_id: &str,
    pinned: bool,
) -> anyhow::Result<bool> {
    let current = transaction
        .query_row("SELECT pinned FROM tab_presentation WHERE tab_id = ?1", [tab_id], |row| {
            row.get::<_, i64>(0)
        })
        .optional()?
        .is_some_and(|value| value != 0);
    if pinned {
        transaction.execute(
            "INSERT INTO tab_presentation(tab_id, pinned) VALUES(?1, 1)
             ON CONFLICT(tab_id) DO UPDATE SET pinned = 1",
            [tab_id],
        )?;
    } else {
        transaction.execute("DELETE FROM tab_presentation WHERE tab_id = ?1", [tab_id])?;
    }
    Ok(current != pinned)
}

/// A partial tab state update: `None` keeps a field, `Some(None)` clears
/// the zoom.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct TabStateUpdate {
    pub(crate) zoom: Option<Option<f64>>,
    pub(crate) back: Option<Vec<String>>,
    pub(crate) forward: Option<Vec<String>>,
    /// Install id of the app hosting a frontend-rendered browser tab, stored
    /// on its browser record. Only that app sends it; the CLI never does.
    pub(crate) owner: Option<String>,
}

impl TabStateUpdate {
    pub(crate) fn validate(&self) -> anyhow::Result<()> {
        if let Some(Some(zoom)) = self.zoom {
            anyhow::ensure!(
                zoom.is_finite() && (MIN_ZOOM..=MAX_ZOOM).contains(&zoom),
                "bad request: zoom must be between {MIN_ZOOM} and {MAX_ZOOM}"
            );
        }
        if let Some(owner) = &self.owner {
            crate::state::window_record_store::validate_key("owner", owner)?;
        }
        for list in [&self.back, &self.forward].into_iter().flatten() {
            anyhow::ensure!(
                list.len() <= MAX_HISTORY_URLS,
                "bad request: a history list holds at most {MAX_HISTORY_URLS} URLs"
            );
            for url in list {
                crate::workspace_registry::presentation_store::validate_frontend_browser_url(
                    "history URL",
                    url,
                )?;
            }
        }
        Ok(())
    }
}

pub(crate) fn update_tab_state(
    transaction: &Transaction<'_>,
    tab_id: &str,
    update: &TabStateUpdate,
) -> anyhow::Result<()> {
    transaction.execute("INSERT OR IGNORE INTO tab_state(tab_id) VALUES(?1)", [tab_id])?;
    if let Some(zoom) = update.zoom {
        transaction
            .execute("UPDATE tab_state SET zoom = ?2 WHERE tab_id = ?1", params![tab_id, zoom])?;
    }
    for (column, list) in [("back_json", &update.back), ("forward_json", &update.forward)] {
        if let Some(list) = list {
            let stored = (!list.is_empty()).then(|| serde_json::to_string(list)).transpose()?;
            transaction.execute(
                &format!("UPDATE tab_state SET {column} = ?2 WHERE tab_id = ?1"),
                params![tab_id, stored],
            )?;
        }
    }
    transaction.execute(
        "DELETE FROM tab_state
         WHERE tab_id = ?1 AND zoom IS NULL AND back_json IS NULL AND forward_json IS NULL",
        [tab_id],
    )?;
    if let Some(owner) = &update.owner {
        let updated = transaction.execute(
            "UPDATE frontend_browser_tabs SET owner = ?2
             WHERE browser_id = (SELECT content_id FROM resource_tabs WHERE public_id = ?1)",
            params![tab_id, owner],
        )?;
        anyhow::ensure!(updated == 1, "bad request: owner applies only to frontend browser tabs");
    }
    Ok(())
}

/// Replace every tab group row in the caller's transaction.
pub(crate) fn write_tab_groups(
    transaction: &Transaction<'_>,
    groups: &TabGroupState,
) -> anyhow::Result<()> {
    write_tab_group_state(transaction, groups)
}

/// The public `TabGroupSnapshot` of a group, or `None` when it is gone.
pub(crate) fn tab_group_snapshot(
    connection: &Connection,
    group_id: &str,
) -> anyhow::Result<Option<Value>> {
    let row = connection
        .query_row(
            "SELECT pane_id, name, color, collapsed, saved_id FROM tab_groups WHERE group_id = ?1",
            [group_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .optional()?;
    let Some((pane_id, name, color, collapsed, saved_id)) = row else { return Ok(None) };
    let tabs = {
        let mut statement = connection.prepare(
            "SELECT m.tab_id FROM tab_group_members AS m
             JOIN resource_tabs AS t ON t.public_id = m.tab_id
             WHERE m.group_id = ?1 AND t.pane_id = ?2 AND t.deleted_revision IS NULL
             ORDER BY t.position ASC",
        )?;
        statement
            .query_map(params![group_id, pane_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    if tabs.is_empty() {
        return Ok(None);
    }
    Ok(Some(json!({
        "id": group_id,
        "pane_id": pane_id,
        "name": name,
        "color": color,
        "collapsed": collapsed != 0,
        "tab_ids": tabs,
        "saved_tab_group_id": saved_id,
    })))
}

/// Every live tab group, optionally of one pane, ordered by pane and strip
/// position.
pub(crate) fn tab_group_snapshots(
    connection: &Connection,
    pane_id: Option<&str>,
) -> anyhow::Result<Vec<Value>> {
    let ids = {
        let mut statement = connection.prepare(
            "SELECT g.group_id FROM tab_groups AS g
             WHERE ?1 IS NULL OR g.pane_id = ?1
             ORDER BY g.pane_id ASC, (
               SELECT MIN(t.position) FROM tab_group_members AS m
               JOIN resource_tabs AS t ON t.public_id = m.tab_id
               WHERE m.group_id = g.group_id AND t.deleted_revision IS NULL
             ) ASC, g.group_id ASC",
        )?;
        statement
            .query_map([pane_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut groups = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(group) = tab_group_snapshot(connection, &id)? {
            groups.push(group);
        }
    }
    Ok(groups)
}

/// Every stored tab group id, including groups whose members left.
pub(crate) fn tab_group_ids(connection: &Connection) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare("SELECT group_id FROM tab_groups ORDER BY group_id")?;
    Ok(statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?)
}

fn public_member(member: &SavedTabMember) -> Value {
    match member {
        SavedTabMember::Terminal { cwd, title, .. } => json!({
            "kind": "terminal",
            "name": title,
            "cwd": cwd,
            "url": null,
            "engine": null,
            "browser_profile_id": null,
        }),
        SavedTabMember::Browser { url, engine, profile_id, title } => json!({
            "kind": "browser",
            "name": title,
            "cwd": null,
            "url": url,
            "engine": engine,
            "browser_profile_id": profile_id,
        }),
    }
}

fn public_saved(record: &SavedTabGroupRecord, index: usize) -> Value {
    json!({
        "id": record.id,
        "room_id": record.room,
        "name": record.name,
        "color": record.color,
        "members": record.members.iter().map(public_member).collect::<Vec<_>>(),
        "index": index,
        "updated_at_ms": record.updated_at_ms.to_string(),
    })
}

/// Saved tab groups in bar order, optionally of one room.
pub(crate) fn saved_tab_group_snapshots(
    connection: &Connection,
    room: Option<&str>,
) -> anyhow::Result<Vec<Value>> {
    Ok(read_saved_tab_groups(connection)?
        .iter()
        .enumerate()
        .filter(|(_, record)| room.is_none_or(|room| record.room == room))
        .map(|(index, record)| public_saved(record, index))
        .collect())
}

pub(crate) fn saved_tab_group_snapshot(
    connection: &Connection,
    saved_id: &str,
) -> anyhow::Result<Option<Value>> {
    Ok(read_saved_tab_groups(connection)?
        .iter()
        .enumerate()
        .find(|(_, record)| record.id == saved_id)
        .map(|(index, record)| public_saved(record, index)))
}

pub(crate) fn saved_tab_group(
    connection: &Connection,
    saved_id: &str,
) -> anyhow::Result<Option<SavedTabGroupRecord>> {
    Ok(read_saved_tab_groups(connection)?.into_iter().find(|record| record.id == saved_id))
}

pub(crate) fn put_saved_tab_group(
    transaction: &Transaction<'_>,
    record: &SavedTabGroupRecord,
) -> anyhow::Result<()> {
    put_saved_tab_group_in(transaction, record)
}

pub(crate) fn delete_saved_tab_group(
    transaction: &Transaction<'_>,
    saved_id: &str,
) -> anyhow::Result<bool> {
    delete_saved_tab_group_in(transaction, saved_id)
}
