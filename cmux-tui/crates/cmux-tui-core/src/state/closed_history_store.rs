//! Closed history (`closed-history-v2`, plans/cmux-next/reopen-closed.md):
//! every close gesture of this session is one restore group, newest first.
//!
//! Recording happens where every close path meets: the resource patch that
//! tombstones the rows. [`capture_closed`] reads the rows before they are
//! tombstoned and stores ONE group per patch, with one member per top-most
//! closed object (a closed workspace records its screens and tabs, not each
//! of them). Content of an ephemeral workspace is never recorded. The group
//! names the window that listed the workspace (its window record), so
//! Reopen Closed can stay in that window. Groups are kept forever (ARCHIVE-1);
//! appends are one INSERT on an INTEGER PRIMARY KEY. The public changes of
//! the batch are queued in `state_pending_changes` and drained into the
//! same journal batch by [`drain_pending_changes`]. Reads live in
//! [`super::closed_history_query`].

use std::collections::HashSet;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

pub(crate) use super::closed_history_query::closed_items;
use super::closed_history_query::public_item;
use super::store::{state_delete, state_upsert};
use crate::workspace_registry::resource_store::{ResourceChange, ResourcePatch};
use crate::workspace_registry::{new_uuid_v4, unix_epoch_ms};

pub(crate) fn create_closed_history_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS closed_groups (
           seq INTEGER PRIMARY KEY AUTOINCREMENT,
           closed_id TEXT UNIQUE NOT NULL,
           kind TEXT NOT NULL CHECK(kind IN ('tab','screen','workspace')),
           window_id TEXT,
           closed_at_ms INTEGER NOT NULL CHECK(closed_at_ms >= 0),
           record_json TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS closed_groups_window ON closed_groups(window_id, seq);
         CREATE TABLE IF NOT EXISTS state_pending_changes (
           sequence INTEGER PRIMARY KEY AUTOINCREMENT,
           change_json TEXT NOT NULL
         );",
    )?;
    migrate_v1(transaction)
}

/// `closed-history-v1` rows become one-member groups with the same ids, in
/// their order; then the v1 table goes.
fn migrate_v1(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'closed_history')",
        [],
        |row| row.get(0),
    )?;
    if !exists {
        return Ok(());
    }
    let rows = {
        let mut statement = transaction.prepare(
            "SELECT closed_id, kind, record_json, closed_at_ms FROM closed_history ORDER BY sequence ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (closed_id, kind, record, closed_at_ms) in rows {
        let record: Value = serde_json::from_str(&record)?;
        let group = json!({
            "id": closed_id,
            "kind": kind,
            "window": null,
            "closed_at_ms": record["closed_at_ms"],
            "members": [member_of(&record)],
        });
        transaction.execute(
            "INSERT OR IGNORE INTO closed_groups(closed_id, kind, window_id, closed_at_ms, record_json)
             VALUES(?1, ?2, NULL, ?3, ?4)",
            params![closed_id, kind, closed_at_ms, serde_json::to_string(&group)?],
        )?;
    }
    transaction.execute_batch("DROP TABLE closed_history")?;
    Ok(())
}

/// The member part of a v1 record (or of a fresh capture).
fn member_of(record: &Value) -> Value {
    json!({
        "kind": record["kind"],
        "name": record["name"],
        "workspace_id": record["workspace_id"],
        "pane_id": record["pane_id"],
        "index": record["index"],
        "screens": record["screens"],
    })
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

/// Store one group of `members` (top-most closed objects, in restore order)
/// and queue its public upsert. `window` is the window record that listed
/// the workspace the group left.
fn insert_group(
    transaction: &Transaction<'_>,
    members: Vec<Value>,
    window: Option<String>,
) -> anyhow::Result<()> {
    let closed_id = format!("closed_{}", new_uuid_v4().replace('-', ""));
    let closed_at_ms = unix_epoch_ms()?;
    let kind = group_kind(&members);
    let record = json!({
        "id": closed_id,
        "kind": kind,
        "window": window,
        "closed_at_ms": closed_at_ms.to_string(),
        "members": members,
    });
    transaction.execute(
        "INSERT INTO closed_groups(closed_id, kind, window_id, closed_at_ms, record_json)
         VALUES(?1, ?2, ?3, ?4, ?5)",
        params![
            closed_id,
            kind,
            record["window"].as_str(),
            i64::try_from(closed_at_ms)?,
            serde_json::to_string(&record)?
        ],
    )?;
    queue_change(transaction, &state_upsert("closed", &closed_id, public_item(&record)))
}

/// The highest level among the members: a group with a screen is a screen
/// group, with a workspace a workspace group.
pub(crate) fn group_kind(members: &[Value]) -> &'static str {
    let has = |kind: &str| members.iter().any(|member| member["kind"] == kind);
    if has("workspace") {
        "workspace"
    } else if has("screen") {
        "screen"
    } else {
        "tab"
    }
}

/// The window record (`install/window`) whose sidebar lists the workspace,
/// or that shows it. None when no window lists it (a TUI-only session).
fn window_of_workspace(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT r.install_id || '/' || r.window_id
             FROM resource_workspaces AS w, window_records AS r
             WHERE w.public_id = ?1
               AND (json_extract(r.record_json, '$.workspace_key') = w.workspace_key
                 OR EXISTS (SELECT 1 FROM json_each(r.record_json, '$.workspace_keys') AS k
                            WHERE k.value = w.workspace_key))
             ORDER BY r.updated_at_ms DESC LIMIT 1",
            [workspace_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
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

/// The workspaces, screens and tabs `patch` tombstones, in patch order.
struct Closing {
    workspaces: Vec<String>,
    screens: Vec<String>,
    tabs: Vec<String>,
}

impl Closing {
    fn of(patch: &ResourcePatch) -> Self {
        let mut closing = Self { workspaces: Vec::new(), screens: Vec::new(), tabs: Vec::new() };
        for change in &patch.changes {
            match change {
                ResourceChange::TombstoneWorkspace { workspace_id } => {
                    closing.workspaces.push(workspace_id.as_str().to_string());
                }
                ResourceChange::TombstoneScreen { screen_id } => {
                    closing.screens.push(screen_id.as_str().to_string());
                }
                ResourceChange::TombstoneTab { tab_id, .. } => {
                    closing.tabs.push(tab_id.as_str().to_string());
                }
                _ => {}
            }
        }
        closing
    }

    fn is_empty(&self) -> bool {
        self.workspaces.is_empty() && self.screens.is_empty() && self.tabs.is_empty()
    }
}

/// The members of one capture and the window they left.
#[derive(Default)]
struct Capture {
    members: Vec<Value>,
    window: Option<String>,
}

impl Capture {
    fn note_window(&mut self, connection: &Connection, workspace_id: &str) -> anyhow::Result<()> {
        if self.window.is_none() {
            self.window = window_of_workspace(connection, workspace_id)?;
        }
        Ok(())
    }
}

/// Record the top-most objects `patch` closes as ONE group, before it
/// applies, and drop the per-workspace state of closed workspaces.
pub(crate) fn capture_closed(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    let closing = Closing::of(patch);
    if closing.is_empty() || !super::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    let closing_workspaces = closing.workspaces.iter().cloned().collect::<HashSet<_>>();
    let closing_screens = closing.screens.iter().cloned().collect::<HashSet<_>>();
    let mut capture = Capture::default();
    for workspace_id in &closing.workspaces {
        capture_workspace(transaction, workspace_id, &mut capture)?;
        if super::workspace_status_store::forget_workspace(transaction, workspace_id)? {
            queue_change(transaction, &state_delete("workspace_status", workspace_id))?;
        }
    }
    for screen_id in &closing.screens {
        capture_screen(transaction, screen_id, &closing_workspaces, &mut capture)?;
    }
    let mut tabs = Vec::new();
    for tab_id in &closing.tabs {
        tabs.extend(tab_member(transaction, tab_id, &closing_workspaces, &closing_screens)?);
    }
    // Restore order: ascending position per pane, so each tab goes back to
    // its own index after the lower ones are in place.
    tabs.sort_by(|left, right| {
        (left["pane_id"].as_str(), left["index"].as_i64())
            .cmp(&(right["pane_id"].as_str(), right["index"].as_i64()))
    });
    for tab in tabs {
        if let Some(workspace) = tab["workspace_id"].as_str().map(str::to_string) {
            capture.note_window(transaction, &workspace)?;
        }
        capture.members.push(tab);
    }
    if capture.members.is_empty() {
        return Ok(());
    }
    insert_group(transaction, capture.members, capture.window)
}

fn capture_screen(
    transaction: &Transaction<'_>,
    screen_id: &str,
    closing_workspaces: &HashSet<String>,
    capture: &mut Capture,
) -> anyhow::Result<()> {
    let Some((workspace_id, position)) = workspace_of_screen(transaction, screen_id)? else {
        return Ok(());
    };
    if closing_workspaces.contains(&workspace_id) || is_ephemeral(transaction, &workspace_id)? {
        return Ok(());
    }
    let record = screen_record(transaction, screen_id)?;
    capture.note_window(transaction, &workspace_id)?;
    capture.members.push(json!({
        "kind": "screen",
        "name": record["name"],
        "workspace_id": workspace_id,
        "pane_id": null,
        "index": position,
        "screens": [record],
    }));
    Ok(())
}

/// The member of one closing tab, unless its screen or workspace closes
/// with it (they record it) or its workspace is ephemeral.
fn tab_member(
    transaction: &Transaction<'_>,
    tab_id: &str,
    closing_workspaces: &HashSet<String>,
    closing_screens: &HashSet<String>,
) -> anyhow::Result<Option<Value>> {
    let placement = transaction
        .query_row(
            "SELECT t.pane_id, t.position, p.screen_id FROM resource_tabs AS t
             JOIN resource_panes AS p ON p.public_id = t.pane_id
             WHERE t.public_id = ?1 AND t.deleted_revision IS NULL",
            [tab_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?)),
        )
        .optional()?;
    let Some((pane_id, position, screen_id)) = placement else { return Ok(None) };
    if closing_screens.contains(&screen_id) {
        return Ok(None);
    }
    let Some((workspace_id, _)) = workspace_of_screen(transaction, &screen_id)? else {
        return Ok(None);
    };
    if closing_workspaces.contains(&workspace_id) || is_ephemeral(transaction, &workspace_id)? {
        return Ok(None);
    }
    let Some(tab) = tab_record(transaction, tab_id)? else { return Ok(None) };
    Ok(Some(json!({
        "kind": "tab",
        "name": tab["name"],
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "index": position,
        "screens": [{"name": null, "tabs": [tab]}],
    })))
}

/// Record a closing workspace. An ephemeral workspace leaves no record.
fn capture_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    capture: &mut Capture,
) -> anyhow::Result<()> {
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
    capture.note_window(transaction, workspace_id)?;
    capture.members.push(json!({
        "kind": "workspace",
        "name": name,
        "workspace_id": null,
        "pane_id": null,
        "index": position.unwrap_or(0),
        "screens": screens,
    }));
    Ok(())
}
