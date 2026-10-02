//! Closed history (`closed-history-v1`): the recently closed tabs, screens,
//! and workspaces of this session, newest first, bounded to
//! [`MAX_CLOSED_ITEMS`].
//!
//! Recording happens where every close path meets: the resource patch that
//! tombstones the rows. [`capture_closed`] reads the rows before they are
//! tombstoned and stores one record per top-most closed object (a closed
//! workspace records its screens and tabs, not each of them). Content of an
//! ephemeral workspace is never recorded. The public changes of the batch
//! (the new records and the evicted ones) are queued in
//! `state_pending_changes` and drained into the same journal batch by
//! [`drain_pending_changes`].

use std::collections::HashSet;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::store::{state_delete, state_upsert};
use crate::workspace_registry::resource_store::{ResourceChange, ResourcePatch};
use crate::workspace_registry::{new_uuid_v4, unix_epoch_ms};

/// Closed items kept per session.
pub(crate) const MAX_CLOSED_ITEMS: i64 = 50;

pub(crate) fn create_closed_history_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS closed_history (
           closed_id TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL CHECK(kind IN ('tab','screen','workspace')),
           record_json TEXT NOT NULL,
           closed_at_ms INTEGER NOT NULL CHECK(closed_at_ms >= 0),
           sequence INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS state_pending_changes (
           sequence INTEGER PRIMARY KEY AUTOINCREMENT,
           change_json TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// Queue one public state change into the current transaction's journal
/// batch (also used by the home placement of `workspace-kind-v1`).
pub(crate) fn queue_change(transaction: &Transaction<'_>, change: &Value) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO state_pending_changes(change_json) VALUES(?1)",
        [serde_json::to_string(change)?],
    )?;
    Ok(())
}

/// Move queued state changes into `changes` (a journal batch array).
pub(crate) fn drain_pending_changes(
    transaction: &Transaction<'_>,
    changes: &mut Value,
) -> anyhow::Result<()> {
    if !super::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    let queued = {
        let mut statement = transaction
            .prepare("SELECT change_json FROM state_pending_changes ORDER BY sequence")?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    if queued.is_empty() {
        return Ok(());
    }
    transaction.execute("DELETE FROM state_pending_changes", [])?;
    if let Some(array) = changes.as_array_mut() {
        for change in queued {
            let mut change: Value = serde_json::from_str(&change)?;
            change["sequence"] = json!(array.len());
            array.push(change);
        }
    }
    Ok(())
}

fn is_ephemeral(connection: &Connection, workspace_id: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT ephemeral FROM workspace_state WHERE workspace_id = ?1",
            [workspace_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .is_some_and(|value| value != 0))
}

/// What reopen needs of one closed tab. `terminal_id` (the public terminal
/// id) lets reopen attach a new view to a terminal that still runs.
fn tab_record(connection: &Connection, tab_id: &str) -> anyhow::Result<Option<Value>> {
    let row = connection
        .query_row(
            "SELECT content_kind, content_id, name FROM resource_tabs
             WHERE public_id = ?1 AND deleted_revision IS NULL",
            [tab_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((kind, content_id, name)) = row else { return Ok(None) };
    let pinned = connection
        .query_row("SELECT pinned FROM tab_presentation WHERE tab_id = ?1", [tab_id], |row| {
            row.get::<_, i64>(0)
        })
        .optional()?
        .is_some_and(|value| value != 0);
    let mut record = json!({
        "kind": kind,
        "name": name,
        "cwd": null,
        "url": null,
        "browser_profile_id": null,
        "pinned": pinned,
    });
    if kind == "terminal" {
        let cwd = connection
            .query_row(
                "SELECT json_extract(h.launch_spec_json, '$.cwd')
                 FROM resource_terminals AS t JOIN terminal_hosts AS h ON h.terminal_id = t.terminal_id
                 WHERE t.public_id = ?1",
                [&content_id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten();
        record["cwd"] = json!(cwd);
        record["terminal_id"] = json!(content_id);
    } else {
        let url = connection
            .query_row(
                "SELECT url FROM resource_browsers WHERE public_id = ?1",
                [&content_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let frontend = connection
            .query_row(
                "SELECT url, profile_id, engine FROM frontend_browser_tabs WHERE browser_id = ?1",
                [&content_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?;
        match frontend {
            Some((url, profile, engine)) => {
                record["url"] = json!(url);
                record["browser_profile_id"] = json!(profile);
                record["engine"] = json!(engine);
            }
            None => record["url"] = json!(url),
        }
    }
    Ok(Some(record))
}

fn screen_tabs(connection: &Connection, screen_id: &str) -> anyhow::Result<Vec<Value>> {
    let tabs = {
        let mut statement = connection.prepare(
            "SELECT t.public_id FROM resource_tabs AS t
             JOIN resource_panes AS p ON p.public_id = t.pane_id
             WHERE p.screen_id = ?1 AND p.deleted_revision IS NULL AND t.deleted_revision IS NULL
             ORDER BY p.creation_ordinal ASC, t.position ASC",
        )?;
        statement
            .query_map([screen_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut records = Vec::with_capacity(tabs.len());
    for tab in tabs {
        if let Some(record) = tab_record(connection, &tab)? {
            records.push(record);
        }
    }
    Ok(records)
}

fn screen_record(connection: &Connection, screen_id: &str) -> anyhow::Result<Value> {
    let name = connection
        .query_row("SELECT name FROM resource_screens WHERE public_id = ?1", [screen_id], |row| {
            row.get::<_, Option<String>>(0)
        })
        .optional()?
        .flatten();
    Ok(json!({"name": name, "tabs": screen_tabs(connection, screen_id)?}))
}

fn insert_record(
    transaction: &Transaction<'_>,
    kind: &str,
    mut record: Value,
) -> anyhow::Result<()> {
    let closed_id = format!("closed_{}", new_uuid_v4().replace('-', ""));
    let closed_at_ms = unix_epoch_ms()?;
    record["id"] = json!(closed_id);
    record["kind"] = json!(kind);
    record["closed_at_ms"] = json!(closed_at_ms.to_string());
    let sequence: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(sequence) + 1, 1) FROM closed_history",
        [],
        |row| row.get(0),
    )?;
    transaction.execute(
        "INSERT INTO closed_history(closed_id, kind, record_json, closed_at_ms, sequence)
         VALUES(?1, ?2, ?3, ?4, ?5)",
        params![
            closed_id,
            kind,
            serde_json::to_string(&record)?,
            i64::try_from(closed_at_ms)?,
            sequence
        ],
    )?;
    queue_change(transaction, &state_upsert("closed", &closed_id, public_item(&record)))?;
    let evicted = {
        let mut statement = transaction.prepare(
            "SELECT closed_id FROM closed_history ORDER BY sequence DESC LIMIT -1 OFFSET ?1",
        )?;
        statement
            .query_map([MAX_CLOSED_ITEMS], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for id in evicted {
        transaction.execute("DELETE FROM closed_history WHERE closed_id = ?1", [&id])?;
        queue_change(transaction, &state_delete("closed", &id))?;
    }
    Ok(())
}

fn workspace_of_screen(
    connection: &Connection,
    screen_id: &str,
) -> anyhow::Result<Option<(String, i64)>> {
    Ok(connection
        .query_row(
            "SELECT workspace_id, position FROM resource_screens WHERE public_id = ?1 AND deleted_revision IS NULL",
            [screen_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?)
}

/// Record the top-most objects `patch` closes, before it applies, and drop
/// the per-workspace state of closed workspaces.
pub(crate) fn capture_closed(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    let workspaces = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                Some(workspace_id.as_str().to_string())
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    let screens = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneScreen { screen_id } => Some(screen_id.as_str().to_string()),
            _ => None,
        })
        .collect::<Vec<_>>();
    let tabs = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneTab { tab_id, .. } => Some(tab_id.as_str().to_string()),
            _ => None,
        })
        .collect::<Vec<_>>();
    if (workspaces.is_empty() && screens.is_empty() && tabs.is_empty())
        || !super::store::state_tables_ready(transaction)?
    {
        return Ok(());
    }
    let closing_workspaces = workspaces.iter().cloned().collect::<HashSet<_>>();
    let closing_screens = screens.iter().cloned().collect::<HashSet<_>>();
    for workspace_id in &workspaces {
        record_workspace(transaction, workspace_id)?;
        if super::workspace_status_store::forget_workspace(transaction, workspace_id)? {
            queue_change(transaction, &state_delete("workspace_status", workspace_id))?;
        }
    }
    for screen_id in &screens {
        let Some((workspace_id, position)) = workspace_of_screen(transaction, screen_id)? else {
            continue;
        };
        if closing_workspaces.contains(&workspace_id) || is_ephemeral(transaction, &workspace_id)? {
            continue;
        }
        let record = screen_record(transaction, screen_id)?;
        insert_record(
            transaction,
            "screen",
            json!({
                "name": record["name"],
                "workspace_id": workspace_id,
                "pane_id": null,
                "index": position,
                "screens": [record],
            }),
        )?;
    }
    for tab_id in &tabs {
        let placement = transaction
            .query_row(
                "SELECT t.pane_id, t.position, p.screen_id FROM resource_tabs AS t
                 JOIN resource_panes AS p ON p.public_id = t.pane_id
                 WHERE t.public_id = ?1 AND t.deleted_revision IS NULL",
                [tab_id],
                |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?))
                },
            )
            .optional()?;
        let Some((pane_id, position, screen_id)) = placement else { continue };
        if closing_screens.contains(&screen_id) {
            continue;
        }
        let Some((workspace_id, _)) = workspace_of_screen(transaction, &screen_id)? else {
            continue;
        };
        if closing_workspaces.contains(&workspace_id) || is_ephemeral(transaction, &workspace_id)? {
            continue;
        }
        let Some(tab) = tab_record(transaction, tab_id)? else { continue };
        insert_record(
            transaction,
            "tab",
            json!({
                "name": tab["name"],
                "workspace_id": workspace_id,
                "pane_id": pane_id,
                "index": position,
                "screens": [{"name": null, "tabs": [tab]}],
            }),
        )?;
    }
    Ok(())
}

/// Record a closing workspace. An ephemeral workspace leaves no record.
fn record_workspace(transaction: &Transaction<'_>, workspace_id: &str) -> anyhow::Result<()> {
    if is_ephemeral(transaction, workspace_id)? {
        transaction
            .execute("DELETE FROM workspace_state WHERE workspace_id = ?1", [workspace_id])?;
        return Ok(());
    }
    let row = transaction
        .query_row(
            "SELECT w.name, w.position FROM resource_workspaces AS rw
             JOIN workspaces AS w ON w.workspace_key = rw.workspace_key
             WHERE rw.public_id = ?1",
            [workspace_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?;
    let Some((name, position)) = row else { return Ok(()) };
    let screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_screens
             WHERE workspace_id = ?1 AND deleted_revision IS NULL ORDER BY position ASC",
        )?;
        statement
            .query_map([workspace_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let screens = screens
        .iter()
        .map(|screen| screen_record(transaction, screen))
        .collect::<anyhow::Result<Vec<_>>>()?;
    insert_record(
        transaction,
        "workspace",
        json!({
            "name": name,
            "workspace_id": null,
            "pane_id": null,
            "index": position.unwrap_or(0),
            "screens": screens,
        }),
    )
}

/// The public `ClosedItemSnapshot` of a stored record.
fn public_item(record: &Value) -> Value {
    let screens = record["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|screen| {
            let tabs = screen["tabs"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|tab| {
                    json!({
                        "kind": tab["kind"],
                        "name": tab["name"],
                        "cwd": tab["cwd"],
                        "url": tab["url"],
                        "browser_profile_id": tab["browser_profile_id"],
                        "pinned": tab["pinned"].as_bool().unwrap_or(false),
                    })
                })
                .collect::<Vec<_>>();
            json!({"name": screen["name"], "tabs": tabs})
        })
        .collect::<Vec<_>>();
    json!({
        "id": record["id"],
        "kind": record["kind"],
        "name": record["name"],
        "workspace_id": record["workspace_id"],
        "pane_id": record["pane_id"],
        "index": record["index"].as_u64().unwrap_or(0),
        "closed_at_ms": record["closed_at_ms"],
        "screens": screens,
    })
}

/// Every retained closed item, newest first.
pub(crate) fn closed_items(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    let mut statement =
        connection.prepare("SELECT record_json FROM closed_history ORDER BY sequence DESC")?;
    let records =
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?;
    records.iter().map(|record| Ok(public_item(&serde_json::from_str(record)?))).collect()
}

/// The full stored record of one closed item (including the terminal ids
/// reopen uses).
pub(crate) fn closed_record(
    connection: &Connection,
    closed_id: &str,
) -> anyhow::Result<Option<Value>> {
    let record = connection
        .query_row(
            "SELECT record_json FROM closed_history WHERE closed_id = ?1",
            [closed_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    record.map(|record| Ok(serde_json::from_str(&record)?)).transpose()
}

/// Remove a reopened item. Returns whether it existed.
pub(crate) fn remove_closed(
    transaction: &Transaction<'_>,
    closed_id: &str,
) -> anyhow::Result<bool> {
    Ok(transaction.execute("DELETE FROM closed_history WHERE closed_id = ?1", [closed_id])? > 0)
}
