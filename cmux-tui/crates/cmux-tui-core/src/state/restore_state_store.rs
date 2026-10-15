//! Pushed restore state (plans/cmux-next/reopen-closed.md 3.0): one row per
//! tab of the state its owner holds and the daemon cannot (an agent draft,
//! a page or viewer scroll), put by `tab.restore_state.put` or inline on
//! a close request.
//!
//! The row is keyed by the tab's public id and outlives the tab while a
//! closed-history group names that tab. `closed_group_tabs` indexes which
//! group names which tab (every `tab_id` string in its record); triggers on
//! `closed_groups` keep it and drop a row once no group names its tab and
//! the tab is not live, so a consumed, partly reopened or deleted group
//! takes its rows with it, whatever path removes the group. A close that
//! records no group (an incognito tab, a terminal that exited) drops the
//! row in the same patch ([`drop_orphans`]). Reopen moves the row to the
//! reopened tab ([`move_to_reopened`]).

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

/// Largest payload, as compact JSON.
pub(crate) const MAX_PAYLOAD_BYTES: usize = 16 * 1024;

/// Creates the tables and triggers. Runs after `closed_groups` exists, on
/// every open (all statements are idempotent). Trigger names carry a
/// version: a changed body gets a new name and the old trigger is dropped.
pub(crate) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let index_is_new: bool = transaction.query_row(
        "SELECT NOT EXISTS(
           SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'closed_group_tabs'
         )",
        [],
        |row| row.get(0),
    )?;
    const NAMED: &str = "SELECT value FROM json_tree({ROW}.record_json)
           WHERE key = 'tab_id' AND type = 'text'";
    let old = NAMED.replace("{ROW}", "OLD");
    let new = NAMED.replace("{ROW}", "NEW");
    let orphans = format!(
        "DELETE FROM tab_restore_state
           WHERE tab_id IN ({old})
             AND NOT EXISTS (
               SELECT 1 FROM closed_group_tabs AS named WHERE named.tab_id = tab_restore_state.tab_id
             )
             AND NOT EXISTS (
               SELECT 1 FROM resource_tabs AS live
               WHERE live.public_id = tab_restore_state.tab_id AND live.deleted_revision IS NULL
             );"
    );
    transaction.execute_batch(&format!(
        "CREATE TABLE IF NOT EXISTS closed_group_tabs (
           closed_id TEXT NOT NULL,
           tab_id TEXT NOT NULL,
           PRIMARY KEY(closed_id, tab_id)
         ) WITHOUT ROWID;
         CREATE INDEX IF NOT EXISTS closed_group_tabs_by_tab ON closed_group_tabs(tab_id);
         CREATE TABLE IF NOT EXISTS tab_restore_state (
           tab_id TEXT PRIMARY KEY NOT NULL,
           provider TEXT NOT NULL,
           version INTEGER NOT NULL CHECK(version >= 0),
           payload_json TEXT NOT NULL,
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
         );
         CREATE TRIGGER IF NOT EXISTS closed_groups_insert_names_tabs_v1
           AFTER INSERT ON closed_groups
         BEGIN
           INSERT OR IGNORE INTO closed_group_tabs(closed_id, tab_id)
             SELECT NEW.closed_id, value FROM ({new});
         END;
         CREATE TRIGGER IF NOT EXISTS closed_groups_update_names_tabs_v1
           AFTER UPDATE OF record_json ON closed_groups
         BEGIN
           DELETE FROM closed_group_tabs WHERE closed_id = OLD.closed_id;
           INSERT OR IGNORE INTO closed_group_tabs(closed_id, tab_id)
             SELECT NEW.closed_id, value FROM ({new});
           {orphans}
         END;
         CREATE TRIGGER IF NOT EXISTS closed_groups_delete_names_tabs_v1
           AFTER DELETE ON closed_groups
         BEGIN
           DELETE FROM closed_group_tabs WHERE closed_id = OLD.closed_id;
           {orphans}
         END;"
    ))?;
    if index_is_new {
        // Groups written before the index existed.
        transaction.execute_batch(
            "INSERT OR IGNORE INTO closed_group_tabs(closed_id, tab_id)
               SELECT g.closed_id, t.value FROM closed_groups AS g, json_tree(g.record_json) AS t
               WHERE t.key = 'tab_id' AND t.type = 'text';",
        )?;
    }
    Ok(())
}

/// One tab's restore state.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct RestoreState {
    pub(crate) provider: String,
    pub(crate) version: u64,
    pub(crate) payload: Value,
}

impl RestoreState {
    pub(crate) fn wire(&self) -> Value {
        json!({"provider": self.provider, "version": self.version, "payload": self.payload})
    }
}

/// Whether the live tab `tab_id` may store restore state: it is live and
/// its workspace is not incognito (ephemeral). None: no live tab.
pub(crate) fn storable(connection: &Connection, tab_id: &str) -> anyhow::Result<Option<bool>> {
    let workspace = connection
        .query_row(
            "SELECT s.workspace_id FROM resource_tabs AS t
             JOIN resource_panes AS p ON p.public_id = t.pane_id
             JOIN resource_screens AS s ON s.public_id = p.screen_id
             WHERE t.public_id = ?1 AND t.deleted_revision IS NULL",
            [tab_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let Some(workspace) = workspace else { return Ok(None) };
    Ok(Some(!super::closed_history_store::is_ephemeral(connection, &workspace)?))
}

/// Upsert the row of `tab_id` (the caller checked [`storable`]).
pub(crate) fn upsert(
    transaction: &Transaction<'_>,
    tab_id: &str,
    state: &RestoreState,
    now_ms: u64,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO tab_restore_state(tab_id, provider, version, payload_json, updated_at_ms)
         VALUES(?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(tab_id) DO UPDATE SET provider = excluded.provider,
           version = excluded.version, payload_json = excluded.payload_json,
           updated_at_ms = excluded.updated_at_ms",
        params![
            tab_id,
            state.provider,
            i64::try_from(state.version)?,
            serde_json::to_string(&state.payload)?,
            i64::try_from(now_ms)?,
        ],
    )?;
    Ok(())
}

/// Drop every row whose tab is neither live nor named by a closed group:
/// a patch closed it outside the closed history. Runs after a patch that
/// tombstones anything applies.
pub(crate) fn drop_orphans(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    if !super::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    transaction.execute(
        "DELETE FROM tab_restore_state
         WHERE NOT EXISTS (
           SELECT 1 FROM resource_tabs AS live
           WHERE live.public_id = tab_restore_state.tab_id AND live.deleted_revision IS NULL
         )
         AND NOT EXISTS (
           SELECT 1 FROM closed_group_tabs AS named WHERE named.tab_id = tab_restore_state.tab_id
         )",
        [],
    )?;
    Ok(())
}

/// Move the rows of reopened tabs (closed tab id -> reopened tab id) to the
/// reopened tabs, before the reopen removes their group. Returns the moved
/// state by reopened tab id.
pub(crate) fn move_to_reopened(
    transaction: &Transaction<'_>,
    reopened_as: &HashMap<String, String>,
) -> anyhow::Result<serde_json::Map<String, Value>> {
    let mut moved = serde_json::Map::new();
    for (closed, reopened) in reopened_as {
        let Some(state) = read(transaction, closed)? else { continue };
        transaction.execute("DELETE FROM tab_restore_state WHERE tab_id = ?1", [reopened])?;
        transaction.execute(
            "UPDATE tab_restore_state SET tab_id = ?2 WHERE tab_id = ?1",
            params![closed, reopened],
        )?;
        moved.insert(reopened.clone(), state.wire());
    }
    Ok(moved)
}

fn read(connection: &Connection, tab_id: &str) -> anyhow::Result<Option<RestoreState>> {
    let row = connection
        .query_row(
            "SELECT provider, version, payload_json FROM tab_restore_state WHERE tab_id = ?1",
            [tab_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?)),
        )
        .optional()?;
    let Some((provider, version, payload)) = row else { return Ok(None) };
    Ok(Some(RestoreState {
        provider,
        version: u64::try_from(version)?,
        payload: serde_json::from_str(&payload)?,
    }))
}
