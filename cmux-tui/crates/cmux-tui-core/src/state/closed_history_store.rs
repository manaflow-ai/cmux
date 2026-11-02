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

use super::closed_history_privacy as privacy;
pub(crate) use super::closed_history_query::closed_items;
use super::closed_history_query::public_item;
use super::store::{state_delete, state_upsert};
use crate::workspace_registry::resource_store::{ResourceChange, ResourcePatch};
use crate::workspace_registry::{new_uuid_v4, unix_epoch_ms};
use cmux_json::JsonSet as _;

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
         CREATE TABLE IF NOT EXISTS closed_group_pending (
           closed_id TEXT PRIMARY KEY NOT NULL,
           extra_json TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS state_pending_changes (
           sequence INTEGER PRIMARY KEY AUTOINCREMENT,
           change_json TEXT NOT NULL
         );",
    )?;
    migrate_v1(transaction)?;
    // After the copy, so groups copied from v1 are scrubbed too.
    privacy::scrub_closed_groups(transaction)
}

/// `closed-history-v1` rows are COPIED to one-member groups with the same
/// ids. The v1 table stays untouched and read-only for one release, so a
/// downgraded daemon still sees its history; a later release drops it in
/// its own commit. `closed_v1_copied` remembers every copied id, so the
/// copy is idempotent (a reopened group never comes back) and rows a
/// downgraded daemon adds meanwhile are copied once, as the newest groups.
/// It keys on ids: v1 sequences restart at 1 when the v1 table empties.
fn migrate_v1(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'closed_history')",
        [],
        |row| row.get(0),
    )?;
    if !exists {
        return Ok(());
    }
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS closed_v1_copied (
           closed_id TEXT PRIMARY KEY NOT NULL,
           closed_at_ms INTEGER NOT NULL,
           v1_sequence INTEGER
         );",
    )?;
    add_ledger_sequences(transaction)?;
    reconcile_v1(transaction)?;
    let rows = {
        let mut statement = transaction.prepare(
            "SELECT closed_id, kind, record_json, closed_at_ms, sequence FROM closed_history
             WHERE closed_id NOT IN (SELECT closed_id FROM closed_v1_copied)
             ORDER BY sequence ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (closed_id, kind, record, closed_at_ms, sequence) in rows {
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
        transaction.execute(
            "INSERT INTO closed_v1_copied(closed_id, closed_at_ms, v1_sequence) VALUES(?1, ?2, ?3)",
            params![closed_id, closed_at_ms, sequence],
        )?;
    }
    Ok(())
}

/// The first v2 build kept no v1 sequence in the ledger: add the column
/// and fill it for every row still in v1 (a removed row stays unknown).
fn add_ledger_sequences(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let has_sequence = transaction
        .prepare("PRAGMA table_info(closed_v1_copied)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "v1_sequence");
    if !has_sequence {
        transaction
            .execute_batch("ALTER TABLE closed_v1_copied ADD COLUMN v1_sequence INTEGER;")?;
    }
    transaction.execute_batch(
        "UPDATE closed_v1_copied SET v1_sequence =
           (SELECT h.sequence FROM closed_history AS h WHERE h.closed_id = closed_v1_copied.closed_id)
         WHERE v1_sequence IS NULL;",
    )?;
    Ok(())
}

/// Copied v1 rows that a downgraded v1 daemon removed since the copy. A v1
/// daemon removes a row when it reopens it, or when it evicts its rows with
/// the lowest sequence past 50. A removed row with a copied row of a LOWER
/// sequence still present was reopened (eviction takes the lowest first),
/// so its group goes too and the item is never reopened twice. Any other
/// removed row may have been evicted, so its group stays (history is kept;
/// a row the older daemon reopened from the bottom can be reopened once
/// more, which v1 data cannot prevent). Sequences compare only among
/// ledger rows: v1 restarts at 1 only after its table empties, and then no
/// older ledger row is present. The ledger forgets every removed row.
fn reconcile_v1(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let removed = {
        let mut statement = transaction.prepare(
            "SELECT closed_id, v1_sequence FROM closed_v1_copied
             WHERE closed_id NOT IN (SELECT closed_id FROM closed_history)",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    if removed.is_empty() {
        return Ok(());
    }
    let lowest_present: Option<i64> = transaction.query_row(
        "SELECT MIN(c.v1_sequence) FROM closed_v1_copied AS c
         JOIN closed_history AS h ON h.closed_id = c.closed_id",
        [],
        |row| row.get(0),
    )?;
    for (closed_id, sequence) in removed {
        if let (Some(sequence), Some(lowest)) = (sequence, lowest_present)
            && sequence > lowest
        {
            transaction.execute("DELETE FROM closed_groups WHERE closed_id = ?1", [&closed_id])?;
        }
        transaction.execute("DELETE FROM closed_v1_copied WHERE closed_id = ?1", [&closed_id])?;
    }
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
/// Returns the placement shift the queued markers name
/// ([`super::placement_shift`]); markers are not changes.
pub(crate) fn drain_pending_changes(
    transaction: &Transaction<'_>,
    changes: &mut Value,
) -> anyhow::Result<Option<super::placement_shift::PlacementShift>> {
    if !super::store::state_tables_ready(transaction)? {
        return Ok(None);
    }
    let queued = {
        let mut statement = transaction
            .prepare("SELECT change_json FROM state_pending_changes ORDER BY sequence")?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    if queued.is_empty() {
        return Ok(None);
    }
    transaction.execute("DELETE FROM state_pending_changes", [])?;
    let mut shift = None;
    if let Some(array) = changes.as_array_mut() {
        for change in queued {
            let queued: Value = serde_json::from_str(&change)?;
            let batch = match queued {
                Value::Array(batch) => batch,
                change => vec![change],
            };
            for mut change in batch {
                if let Some(marker) = super::placement_shift::marker(&change) {
                    super::placement_shift::merge(&mut shift, marker);
                    continue;
                }
                change.set("sequence", json!(array.len()));
                array.push(change);
            }
        }
    }
    Ok(shift)
}

pub(super) fn is_ephemeral(connection: &Connection, workspace_id: &str) -> anyhow::Result<bool> {
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
        // The closed tab's id: a closed tab group names its tabs by it.
        "tab_id": tab_id,
        "kind": kind,
        "name": name,
        "cwd": null,
        "url": null,
        "browser_profile_id": null,
        "pinned": pinned,
    });
    if kind == "terminal" {
        // The closed tab keeps its own copy of the relaunch record, so reopen
        // works after the terminal's row is gone.
        let relaunch =
            crate::workspace_registry::relaunch_store::closed_fields(connection, &content_id)?;
        record.set("cwd", relaunch.as_ref().map_or(Value::Null, |fields| fields["cwd"].clone()));
        record.set("relaunch", relaunch.unwrap_or(Value::Null));
        record.set("terminal_id", json!(content_id));
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
                record.set("url", json!(privacy::strip_url(&url)));
                record.set("browser_profile_id", json!(profile));
                record.set("engine", json!(engine));
                // Back/forward entries and scroll come back on reopen
                // (cx-d0d.11); `closed.list` never shows them.
                record.set(
                    "browser_history",
                    connection
                        .query_row(
                            "SELECT history FROM frontend_browser_history WHERE browser_id = ?1",
                            [&content_id],
                            |row| row.get::<_, String>(0),
                        )
                        .optional()?
                        .map_or(Value::Null, |history| privacy::strip_history(&history)),
                );
            }
            None => {
                record.set("url", json!(url.map(|url| privacy::strip_url(&url))));
            }
        }
        // A conversation tab reopens as one, from this record.
        if let Some(conversation) =
            super::conversation_tabs_store::tab_conversation_wire(connection, tab_id)?
        {
            record.set("conversation", conversation);
        }
        // A remote-terminal tab reopens as one (`remote-terminal-tabs-v1`).
        if let Some(remote) =
            super::remote_terminal_tabs_store::tab_remote_wire(connection, tab_id)?
        {
            record.set("remote", remote);
        }
    }
    Ok(Some(record))
}

/// The tab records of a screen, without `skip` (tabs a stash keeps), and
/// the panes they sat in: each pane's tabs as indexes into the records, in
/// strip order, and the index of its selected tab among them.
fn screen_tabs(
    connection: &Connection,
    screen_id: &str,
    skip: &HashSet<String>,
) -> anyhow::Result<(Vec<Value>, serde_json::Map<String, Value>)> {
    let tabs = {
        let mut statement = connection.prepare(
            "SELECT t.public_id, p.public_id, p.active_tab_id FROM resource_tabs AS t
             JOIN resource_panes AS p ON p.public_id = t.pane_id
             WHERE p.screen_id = ?1 AND p.deleted_revision IS NULL AND t.deleted_revision IS NULL
             ORDER BY p.creation_ordinal ASC, t.position ASC",
        )?;
        statement
            .query_map([screen_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut records = Vec::with_capacity(tabs.len());
    let mut panes = serde_json::Map::new();
    for (tab, pane, active) in tabs.iter().filter(|(tab, _, _)| !skip.contains(tab)) {
        let Some(record) = tab_record(connection, tab)? else { continue };
        let entry = panes.entry(pane.clone()).or_insert_with(|| json!({"tabs": [], "active": 0}));
        let strip = entry["tabs"].as_array().map_or(0, Vec::len);
        if active.as_deref() == Some(tab.as_str()) {
            entry["active"] = json!(strip);
        }
        if let Some(strip) = entry["tabs"].as_array_mut() {
            strip.push(json!(records.len()));
        }
        records.push(record);
    }
    Ok((records, panes))
}

/// A closing screen: its name and tab records (`tabs`, the flat list older
/// readers take), and its layout (`layout`, the split tree of pane ids;
/// `panes`, each pane's tabs and selected tab; `active_pane`;
/// `zoomed_pane`), so a reopen rebuilds the splits it had.
fn screen_record(
    connection: &Connection,
    screen_id: &str,
    skip: &HashSet<String>,
) -> anyhow::Result<Value> {
    let row = connection
        .query_row(
            "SELECT name, layout_json, active_pane_id, zoomed_pane_id
             FROM resource_screens WHERE public_id = ?1",
            [screen_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            },
        )
        .optional()?;
    let (tabs, panes) = screen_tabs(connection, screen_id, skip)?;
    let Some((name, layout, active_pane, zoomed_pane)) = row else {
        return Ok(json!({"name": null, "tabs": tabs}));
    };
    let layout = serde_json::from_str::<Value>(&layout).unwrap_or(Value::Null);
    Ok(json!({
        "name": name,
        "tabs": tabs,
        "layout": layout,
        "panes": panes,
        "active_pane": active_pane,
        "zoomed_pane": zoomed_pane,
    }))
}

/// Store one group of `members` (top-most closed objects, in restore order)
/// and queue its public upsert. `window` is the window record that listed
/// the workspace the group left.
fn insert_group(
    transaction: &Transaction<'_>,
    members: Vec<Value>,
    window: Option<String>,
    tab_groups: Vec<Value>,
) -> anyhow::Result<()> {
    let (closed_id, mut extra) = match take_pending_group(transaction)? {
        Some((closed_id, extra)) => (closed_id, Some(extra)),
        None => (new_closed_id(), None),
    };
    if !tab_groups.is_empty() {
        let fields = extra.get_or_insert_with(|| json!({}));
        fields["tab_groups"] = Value::Array(tab_groups);
    }
    insert_record(transaction, closed_id, members, window, extra)
}

/// Store group `closed_id` of `members` with the fields of `extra` and
/// queue its public upsert.
fn insert_record(
    transaction: &Transaction<'_>,
    closed_id: String,
    members: Vec<Value>,
    window: Option<String>,
    extra: Option<Value>,
) -> anyhow::Result<()> {
    let closed_at_ms = unix_epoch_ms()?;
    let mut record = json!({
        "id": closed_id,
        "kind": group_kind(&members),
        "window": window,
        "closed_at_ms": closed_at_ms.to_string(),
        "members": members,
    });
    if let Some(Value::Object(extra)) = extra {
        for (key, value) in extra {
            record[key] = value;
        }
        // A deleted space with no workspace left to close is still a
        // workspace-level group: reopening it restores the space. An
        // ungrouped tab or screen group stays a tab- or screen-level one.
        if record["members"].as_array().is_some_and(Vec::is_empty) {
            record.set(
                "kind",
                json!(if record.get("tab_group").is_some() {
                    "tab"
                } else if record.get("screen_group").is_some() {
                    "screen"
                } else {
                    "workspace"
                }),
            );
        }
    }
    let kind = record["kind"].as_str().unwrap_or("tab").to_string();
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

/// A window the app closed (`window_record.put` turned its record's `open`
/// to false): one `window` group with no member that names the window
/// record `window` (`install/window`). The window keeps its workspaces, so
/// reopening the group only tells the app to show that window again
/// (plans/cmux-next/reopen-closed.md 4). The `kind` column's CHECK predates
/// window groups; the record's `kind` is the group's level. An incognito
/// window (`keys` are only ephemeral workspaces) records nothing: None.
/// Returns the group's public change.
pub(crate) fn insert_window_group(
    transaction: &Transaction<'_>,
    window: &str,
    name: Option<String>,
    keys: &[String],
) -> anyhow::Result<Option<Value>> {
    if privacy::is_private_window(transaction, keys)? {
        return Ok(None);
    }
    let closed_id = new_closed_id();
    let closed_at_ms = unix_epoch_ms()?;
    let record = json!({
        "id": closed_id,
        "kind": "window",
        "window": window,
        "window_record": window,
        "name": name,
        "closed_at_ms": closed_at_ms.to_string(),
        "members": [],
    });
    transaction.execute(
        "INSERT INTO closed_groups(closed_id, kind, window_id, closed_at_ms, record_json)
         VALUES(?1, 'workspace', ?2, ?3, ?4)",
        params![closed_id, window, i64::try_from(closed_at_ms)?, serde_json::to_string(&record)?],
    )?;
    Ok(Some(state_upsert("closed", &closed_id, public_item(&record))))
}

/// Remove the window groups of window record `window` (it opened again or
/// is gone). Returns their public deletes.
pub(crate) fn remove_window_groups(
    transaction: &Transaction<'_>,
    window: &str,
) -> anyhow::Result<Vec<Value>> {
    let ids = {
        let mut statement = transaction.prepare(
            "SELECT closed_id FROM closed_groups
             WHERE window_id = ?1 AND json_extract(record_json, '$.kind') = 'window'",
        )?;
        statement
            .query_map([window], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut changes = Vec::with_capacity(ids.len());
    for id in ids {
        super::closed_history_query::remove_closed(transaction, &id)?;
        changes.push(state_delete("closed", &id));
    }
    Ok(changes)
}

/// The name of the workspace whose key is `key`, for a window group's title.
pub(crate) fn workspace_name(
    transaction: &Transaction<'_>,
    key: &str,
) -> anyhow::Result<Option<String>> {
    Ok(transaction
        .query_row("SELECT name FROM workspaces WHERE workspace_key = ?1", [key], |row| {
            row.get::<_, Option<String>>(0)
        })
        .optional()?
        .flatten())
}

/// Ungroup of a tab or screen group (`archive` under `field`, `tab_group`
/// or `screen_group`: its id, workspace, name, color and members in order):
/// one group with no member, since its tabs or screens stay open, in the
/// window that lists its workspace. Reopening it forms the group again
/// around them. An incognito workspace records nothing.
pub(crate) fn record_ungrouped_group(
    transaction: &Transaction<'_>,
    field: &str,
    archive: &Value,
) -> anyhow::Result<()> {
    let Some(workspace_id) = archive["workspace_id"].as_str() else { return Ok(()) };
    if !super::store::state_tables_ready(transaction)? || is_ephemeral(transaction, workspace_id)? {
        return Ok(());
    }
    let window = window_of_workspace(transaction, workspace_id)?;
    let extra = json!({"name": archive["name"], field: archive});
    insert_record(transaction, new_closed_id(), Vec::new(), window, Some(extra))
}

/// The sequence of the newest stored closed group (0: none, or no closed
/// history yet). With [`closed_ids_after`] a close finds the groups its own
/// transaction stored (`closed_ids`, GPUI Undo of a bulk close).
pub(crate) fn closed_seq(connection: &Connection) -> anyhow::Result<i64> {
    if !super::store::state_tables_ready(connection)? {
        return Ok(0);
    }
    Ok(connection
        .query_row("SELECT COALESCE(MAX(seq), 0) FROM closed_groups", [], |row| row.get(0))?)
}

/// The ids of the closed groups stored after sequence `seq`, oldest first.
pub(crate) fn closed_ids_after(connection: &Connection, seq: i64) -> anyhow::Result<Vec<String>> {
    if !super::store::state_tables_ready(connection)? {
        return Ok(Vec::new());
    }
    let mut statement =
        connection.prepare("SELECT closed_id FROM closed_groups WHERE seq > ?1 ORDER BY seq")?;
    Ok(statement.query_map([seq], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?)
}

/// A new closed group id.
pub(crate) fn new_closed_id() -> String {
    format!("closed_{}", new_uuid_v4().replace('-', ""))
}

/// Announce, inside a transaction, the next group it stores: that group
/// gets `closed_id` and the fields of `extra` (a deleted space's record).
/// [`flush_pending_group`] stores it with no member when no close does.
pub(crate) fn pend_group(
    transaction: &Transaction<'_>,
    closed_id: &str,
    extra: &Value,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO closed_group_pending(closed_id, extra_json) VALUES(?1, ?2)",
        params![closed_id, serde_json::to_string(extra)?],
    )?;
    Ok(())
}

fn take_pending_group(transaction: &Transaction<'_>) -> anyhow::Result<Option<(String, Value)>> {
    let pending = transaction
        .query_row("SELECT closed_id, extra_json FROM closed_group_pending LIMIT 1", [], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .optional()?;
    let Some((closed_id, extra)) = pending else { return Ok(None) };
    transaction.execute("DELETE FROM closed_group_pending WHERE closed_id = ?1", [&closed_id])?;
    Ok(Some((closed_id, serde_json::from_str(&extra)?)))
}

/// Store the announced group that no close stored (no member).
pub(crate) fn flush_pending_group(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let pending: bool =
        transaction
            .query_row("SELECT EXISTS(SELECT 1 FROM closed_group_pending)", [], |row| row.get(0))?;
    if pending { insert_group(transaction, Vec::new(), None, Vec::new()) } else { Ok(()) }
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
             ORDER BY EXISTS (SELECT 1 FROM json_each(r.record_json, '$.workspace_keys') AS k
                              WHERE k.value = w.workspace_key) DESC,
                      r.updated_at_ms DESC
             LIMIT 1",
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

/// The workspaces, screens, panes and tabs `patch` tombstones, in patch
/// order.
struct Closing {
    workspaces: Vec<String>,
    screens: Vec<String>,
    panes: HashSet<String>,
    tabs: Vec<String>,
}

impl Closing {
    fn of(patch: &ResourcePatch) -> Self {
        let mut closing = Self {
            workspaces: Vec::new(),
            screens: Vec::new(),
            panes: HashSet::new(),
            tabs: Vec::new(),
        };
        for change in &patch.changes {
            match change {
                ResourceChange::TombstoneWorkspace { workspace_id } => {
                    closing.workspaces.push(workspace_id.as_str().to_string());
                }
                ResourceChange::TombstoneScreen { screen_id } => {
                    closing.screens.push(screen_id.as_str().to_string());
                }
                ResourceChange::TombstonePane { pane_id } => {
                    closing.panes.insert(pane_id.as_str().to_string());
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
    if !super::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    // A whole-workspace stash (`stash-workspaces-v1`) takes this close's
    // capture instead of the closed history.
    let whole_stash = super::stash_store::take_workspace_stash(transaction)?;
    if closing.is_empty() {
        anyhow::ensure!(whole_stash.is_none(), "bad request: no workspace to stash");
        return Ok(());
    }
    let closing_workspaces = closing.workspaces.iter().cloned().collect::<HashSet<_>>();
    let closing_screens = closing.screens.iter().cloned().collect::<HashSet<_>>();
    // Tabs a stash (`stash-v1`) keeps: never in the closed group, but a
    // workspace or screen the stash empties still is.
    let stashed = super::stash_store::take_capture_mark(transaction)?;
    // Before `capture_workspace` forgets which closing workspaces are
    // ephemeral: their groups are never recorded.
    let closing_tabs = closing.tabs.iter().cloned().collect::<HashSet<_>>();
    let mut tab_groups = super::closed_tab_groups::closing_tab_groups(
        transaction,
        &closing_tabs,
        &closing_screens,
        &closing_workspaces,
    )?;
    // A stashed tab is not in this close, so no reopened group may claim it.
    for archive in &mut tab_groups {
        if let Some(tab_ids) = archive["tab_ids"].as_array_mut() {
            tab_ids.retain(|tab| tab.as_str().is_none_or(|tab| !stashed.contains(tab)));
        }
    }
    tab_groups.retain(|archive| archive["tab_ids"].as_array().is_some_and(|tabs| !tabs.is_empty()));
    let mut capture = Capture::default();
    for workspace_id in &closing.workspaces {
        capture_workspace(transaction, workspace_id, &stashed, &mut capture)?;
        if super::workspace_status_store::forget_workspace(transaction, workspace_id)? {
            queue_change(transaction, &state_delete("workspace_status", workspace_id))?;
        }
        if super::workspace_checklist_store::forget_workspace(transaction, workspace_id)? {
            queue_change(transaction, &state_delete("workspace_checklist", workspace_id))?;
        }
    }
    for screen_id in &closing.screens {
        capture_screen(transaction, screen_id, &closing_workspaces, &stashed, &mut capture)?;
    }
    let mut tabs = Vec::new();
    for tab_id in closing.tabs.iter().filter(|tab| !stashed.contains(*tab)) {
        tabs.extend(tab_member(
            transaction,
            tab_id,
            &closing_workspaces,
            &closing_screens,
            &closing.panes,
        )?);
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
    if let Some((stash_id, name)) = whole_stash {
        return super::stash_store::store_workspace_stash(
            transaction,
            &stash_id,
            name.as_deref(),
            capture.members,
            tab_groups,
        );
    }
    if capture.members.is_empty() {
        return Ok(());
    }
    insert_group(transaction, capture.members, capture.window, tab_groups)
}

fn capture_screen(
    transaction: &Transaction<'_>,
    screen_id: &str,
    closing_workspaces: &HashSet<String>,
    stashed: &HashSet<String>,
    capture: &mut Capture,
) -> anyhow::Result<()> {
    let Some((workspace_id, position)) = workspace_of_screen(transaction, screen_id)? else {
        return Ok(());
    };
    if closing_workspaces.contains(&workspace_id) || is_ephemeral(transaction, &workspace_id)? {
        return Ok(());
    }
    let record = screen_record(transaction, screen_id, stashed)?;
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
/// with it (they record it) or its workspace is ephemeral. A tab whose
/// pane closes with it keeps where that pane was split (`split`).
pub(crate) fn tab_member(
    transaction: &Connection,
    tab_id: &str,
    closing_workspaces: &HashSet<String>,
    closing_screens: &HashSet<String>,
    closing_panes: &HashSet<String>,
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
    let mut member = json!({
        "kind": "tab",
        // The closed tab's id: a closed tab group names its tabs by it.
        "tab_id": tab_id,
        "name": tab["name"],
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "index": position,
        "screens": [{"name": null, "tabs": [tab]}],
    });
    if closing_panes.contains(&pane_id)
        && let Some(split) =
            super::closed_pane_split::pane_placement(transaction, &screen_id, &pane_id)?
    {
        member.set("split", split);
    }
    Ok(Some(member))
}

/// Record a closing workspace. An ephemeral workspace leaves no record.
fn capture_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    stashed: &HashSet<String>,
    capture: &mut Capture,
) -> anyhow::Result<()> {
    if is_ephemeral(transaction, workspace_id)? {
        transaction
            .execute("DELETE FROM workspace_state WHERE workspace_id = ?1", [workspace_id])?;
        return Ok(());
    }
    let row = transaction
        .query_row(
            "SELECT w.name, w.position, w.workspace_key FROM resource_workspaces AS rw
             JOIN workspaces AS w ON w.workspace_key = rw.workspace_key
             WHERE rw.public_id = ?1",
            [workspace_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<i64>>(1)?,
                    row.get::<_, String>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((name, position, workspace_key)) = row else { return Ok(()) };
    let screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_screens
             WHERE workspace_id = ?1 AND deleted_revision IS NULL ORDER BY position ASC",
        )?;
        statement
            .query_map([workspace_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let active_screen = transaction
        .query_row(
            "SELECT active_screen_id FROM resource_workspaces WHERE public_id = ?1",
            [workspace_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten()
        .and_then(|active| screens.iter().position(|screen| *screen == active));
    let screens = screens
        .iter()
        .map(|screen| screen_record(transaction, screen, stashed))
        .collect::<anyhow::Result<Vec<_>>>()?;
    capture.note_window(transaction, workspace_id)?;
    // `workspace_key`: reopen moves the closed workspace's personal row
    // (group, place, theme) to the new workspace. `presentation`: its
    // shared color, icon, title and pin, which reopen sets again.
    // `closed_workspace_id`: its `ws_` id, so `closed.reopen {workspace}`
    // (a `cmux://workspace/` link to it) finds it.
    capture.members.push(json!({
        "kind": "workspace",
        "name": name,
        "workspace_key": workspace_key,
        "closed_workspace_id": workspace_id,
        "workspace_id": null,
        "pane_id": null,
        "index": position.unwrap_or(0),
        "screens": screens,
        "active_screen": active_screen,
        "presentation": workspace_presentation(transaction, &workspace_key)?,
    }));
    Ok(())
}

/// The shared presentation (color, icon, custom title, pin) of the closing
/// workspace `workspace_key`; null when it has none.
fn workspace_presentation(connection: &Connection, workspace_key: &str) -> anyhow::Result<Value> {
    Ok(connection
        .query_row(
            "SELECT color, icon, title, pinned FROM workspace_presentation WHERE workspace_key = ?1",
            [workspace_key],
            |row| {
                Ok(json!({
                    "color": row.get::<_, Option<String>>(0)?,
                    "icon": row.get::<_, Option<String>>(1)?,
                    "title": row.get::<_, Option<String>>(2)?,
                    "pinned": row.get::<_, i64>(3)? != 0,
                }))
            },
        )
        .optional()?
        .unwrap_or(Value::Null))
}
