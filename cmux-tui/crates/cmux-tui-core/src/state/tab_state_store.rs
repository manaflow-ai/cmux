//! Tab state rows of the v2 state resources: pins, per-tab zoom and browser
//! back/forward lists, the public tab group snapshots, and the personal
//! saved tab groups.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

#[cfg(test)]
#[path = "tab_attention_request_tests.rs"]
mod attention_request_tests;

use crate::workspace_registry::presentation_store::{
    SavedTabGroupRecord, SavedTabMember, TabGroupState, delete_saved_tab_group_in,
    put_saved_tab_group_in, read_saved_tab_groups, write_tab_group_state,
};

/// URLs one back or forward list keeps.
pub(crate) const MAX_HISTORY_URLS: usize = 20;
pub(crate) const MIN_ZOOM: f64 = 0.25;
pub(crate) const MAX_ZOOM: f64 = 5.0;

/// Store a tab placement's pinned flag. Returns whether it changed.
/// `url`: the page a browser tab is pinned on (Back to Pinned Page); a pin
/// already stored keeps its page, and an unpin forgets it with the row.
pub(crate) fn set_tab_pinned(
    transaction: &Transaction<'_>,
    tab_id: &str,
    pinned: bool,
    url: Option<&str>,
) -> anyhow::Result<bool> {
    let current = transaction
        .query_row("SELECT pinned FROM tab_presentation WHERE tab_id = ?1", [tab_id], |row| {
            row.get::<_, i64>(0)
        })
        .optional()?
        .is_some_and(|value| value != 0);
    if pinned {
        transaction.execute(
            "INSERT INTO tab_presentation(tab_id, pinned, url) VALUES(?1, 1, ?2)
             ON CONFLICT(tab_id) DO UPDATE SET pinned = 1, url = COALESCE(url, excluded.url)",
            params![tab_id, url],
        )?;
    } else {
        transaction.execute("DELETE FROM tab_presentation WHERE tab_id = ?1", [tab_id])?;
    }
    Ok(current != pinned)
}

/// Additive: the page a pinned browser tab was pinned on (cx-lle.6). Older
/// builds name their columns, so they keep reading and writing the table; a
/// pin they write has no page (Back to Pinned Page is unavailable for it).
pub(crate) fn add_tab_pinned_url_column(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let has_url = transaction
        .prepare("PRAGMA table_info(tab_presentation)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "url");
    if !has_url {
        transaction.execute_batch("ALTER TABLE tab_presentation ADD COLUMN url TEXT;")?;
    }
    Ok(())
}

/// Additive: a `tab_state` table an older build created has no icon
/// column. Older builds name their columns, so they keep reading and
/// writing the table.
pub(crate) fn add_tab_icon_column(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let has_icon = transaction
        .prepare("PRAGMA table_info(tab_state)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "icon");
    if !has_icon {
        transaction.execute_batch("ALTER TABLE tab_state ADD COLUMN icon TEXT;")?;
    }
    Ok(())
}

/// Additive: the manual tab unread mark (`tab-mark-unread-v1`). Older
/// builds name their columns, so they keep reading and writing the table;
/// an older build that empties a row of every field it knows drops the mark
/// with it (a rollback can lose manual unread marks, as for workspaces).
pub(crate) fn add_tab_marked_unread_column(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let has_column = transaction
        .prepare("PRAGMA table_info(tab_state)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "marked_unread");
    if !has_column {
        transaction.execute_batch("ALTER TABLE tab_state ADD COLUMN marked_unread INTEGER;")?;
    }
    Ok(())
}

/// Additive: an agent's "needs you here" mark on a tab (`tab-attention-v1`).
/// Older builds name their columns, so they keep reading and writing the
/// table; an older build that empties a row of every field it knows drops
/// the mark with it.
pub(crate) fn add_tab_attention_column(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let has_column = transaction
        .prepare("PRAGMA table_info(tab_state)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "attention_json");
    if !has_column {
        transaction.execute_batch("ALTER TABLE tab_state ADD COLUMN attention_json TEXT;")?;
    }
    // Upgrade pre-token marks once. The identity lives in the same JSON as
    // the mark, so a restart preserves it; legacy writers may replace the
    // JSON, in which case the next upgrade issues a new identity.
    let legacy = transaction
        .prepare("SELECT tab_id, attention_json FROM tab_state WHERE attention_json IS NOT NULL")?
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    for (tab, stored) in legacy {
        let Ok(mut value) = serde_json::from_str::<Value>(&stored) else { continue };
        let Some(object) = value.as_object_mut() else { continue };
        if object.get("reason").and_then(Value::as_str).is_none()
            || object.get("at_ms").and_then(Value::as_u64).is_none()
            || object
                .get("request_id")
                .and_then(Value::as_str)
                .is_some_and(valid_attention_request_id)
        {
            continue;
        }
        object.insert("request_id".into(), Value::String(new_attention_request_id()?));
        transaction.execute(
            "UPDATE tab_state SET attention_json = ?2 WHERE tab_id = ?1",
            params![tab, value.to_string()],
        )?;
    }
    Ok(())
}

fn valid_attention_request_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Owner-issued 128-bit identity, independent of the clock and row lifetime.
/// Entropy failure aborts the transaction; there is no time-based fallback.
fn new_attention_request_id() -> anyhow::Result<String> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| anyhow::anyhow!("random attention id: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// UTF-8 bytes an attention reason holds at most (the catalog's max_length unit).
pub(crate) const MAX_ATTENTION_REASON_BYTES: usize = 200;

/// The stored attention mark: why the agent needs the person in this tab,
/// and when it asked. Shown as the tab's `extra.attention`. A browser tab's
/// mark also records the page it was set on (`page`, never shown): the mark
/// clears once the tab is on another page, decided in the clearing
/// transaction ([`clear_attention_off_page`]), so a mark set on the new page
/// survives a navigation event that arrives after it.
fn attention_value(reason: &str, at_ms: u64, page: Option<&str>) -> anyhow::Result<Value> {
    let request_id = new_attention_request_id()?;
    Ok(match page {
        Some(page) => {
            json!({"reason": reason, "at_ms": at_ms, "request_id": request_id, "page": page})
        }
        None => json!({"reason": reason, "at_ms": at_ms, "request_id": request_id}),
    })
}

/// The mark as `extra.attention` shows it: `{reason, at_ms, request_id}`, without the
/// page it was set on.
pub(crate) fn shown_attention(stored: &str) -> anyhow::Result<Value> {
    let mut value: Value = serde_json::from_str(stored)?;
    if let Some(object) = value.as_object_mut() {
        object.remove("page");
    }
    Ok(value)
}

/// A live tab's attention mark as frontends draw it (`tab-attention-v1`):
/// the reason the person reads and when the agent asked (Unix ms). Loaded
/// into the presentation snapshot so the raw tree carries it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TabAttentionRecord {
    pub reason: String,
    pub at_ms: u64,
}

/// The attention mark of every live tab, by public tab id. A row whose JSON
/// does not hold a reason is skipped, as `extra.attention` would show none.
pub(crate) fn read_tab_attention(
    connection: &Connection,
) -> anyhow::Result<std::collections::HashMap<String, TabAttentionRecord>> {
    let mut statement = connection.prepare(
        "SELECT s.tab_id, s.attention_json FROM tab_state AS s
         JOIN resource_tabs AS t ON t.public_id = s.tab_id
         WHERE s.attention_json IS NOT NULL AND t.deleted_revision IS NULL",
    )?;
    let rows = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows
        .into_iter()
        .filter_map(|(tab, stored)| Some((tab, attention_record(&stored)?)))
        .collect())
}

/// A stored attention mark as frontends draw it, or `None` when its JSON
/// holds no reason.
fn attention_record(stored: &str) -> Option<TabAttentionRecord> {
    let value: Value = serde_json::from_str(stored).ok()?;
    let reason = value.get("reason")?.as_str()?.to_string();
    let at_ms = value.get("at_ms").and_then(Value::as_u64).unwrap_or(0);
    Some(TabAttentionRecord { reason, at_ms })
}

/// The attention mark of one live tab, as [`read_tab_attention`] lists it:
/// what the presentation cache holds for the tab after a commit that wrote
/// its mark.
pub(crate) fn tab_attention_record(
    connection: &Connection,
    tab_id: &str,
) -> anyhow::Result<Option<TabAttentionRecord>> {
    let stored = connection
        .query_row(
            "SELECT s.attention_json FROM tab_state AS s
             JOIN resource_tabs AS t ON t.public_id = s.tab_id
             WHERE s.tab_id = ?1 AND s.attention_json IS NOT NULL
               AND t.deleted_revision IS NULL",
            [tab_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    Ok(stored.as_deref().and_then(attention_record))
}

/// A partial tab state update: `None` keeps a field, `Some(None)` clears
/// the zoom or the icon.
#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct TabStateUpdate {
    pub(crate) zoom: Option<Option<f64>>,
    pub(crate) back: Option<Vec<String>>,
    pub(crate) forward: Option<Vec<String>>,
    /// Install id of the app hosting a frontend-rendered browser tab, stored
    /// on its browser record. Only that app sends it; the CLI never does.
    pub(crate) owner: Option<String>,
    /// The user's icon for the tab (the shared icon wire string: one emoji,
    /// an SF Symbol name, ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS, or a stored
    /// `image:`/`svg:` asset, `icon-assets-v1`, checked by `state_update_tab`).
    pub(crate) icon: Option<Option<String>>,
    /// The device a browser tab emulates (`browser.tab.emulate`,
    /// `browser.tab.emulate.clear`), resolved in the writing transaction.
    pub(crate) emulation: Option<crate::state::browser_devices::EmulationChange>,
    /// The person marked the tab unread by hand (`tab-mark-unread-v1`),
    /// apart from notification markers: `Some(true)` sets the mark,
    /// `Some(false)` clears it. Clients clear it when the tab is viewed.
    pub(crate) marked_unread: Option<bool>,
    /// An agent needs the person to act in this tab (`tab-attention-v1`):
    /// `Some(Some(reason))` sets the mark, `Some(None)` clears it. Viewing
    /// the tab keeps it; the agent's clear, a browser tab's navigation to
    /// another page, or the tab's close clears it.
    pub(crate) attention: Option<Option<String>>,
    /// With attention:null, clear only the request with this identity.
    /// Omission preserves the legacy unconditional clear API.
    pub(crate) attention_request_id: Option<String>,
    /// The page a browser tab shows when a new attention mark is set, stored
    /// with it. Filled by `state_update_tab` from the tab's surface, never
    /// from the request.
    pub(crate) attention_page: Option<String>,
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
        if let Some(Some(icon)) = &self.icon {
            crate::workspace_registry::presentation_store::validate_icon_value(icon)?;
        }
        if let Some(Some(reason)) = &self.attention {
            anyhow::ensure!(
                !reason.trim().is_empty(),
                "bad request: attention needs a reason the person can read"
            );
            anyhow::ensure!(
                reason.len() <= MAX_ATTENTION_REASON_BYTES,
                "bad request: an attention reason holds at most {MAX_ATTENTION_REASON_BYTES} bytes"
            );
            // One line: no control characters and no Unicode line or
            // paragraph separator (U+2028, U+2029, not `is_control`).
            anyhow::ensure!(
                !reason.chars().any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')),
                "bad request: an attention reason is one line of text"
            );
        }
        if let Some(id) = &self.attention_request_id {
            anyhow::ensure!(
                matches!(self.attention, Some(None)) && valid_attention_request_id(id),
                "bad request: attention_request_id requires attention:null and 32 lowercase hex bytes"
            );
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
    update_tab_state_at_time(transaction, tab_id, update, crate::mux::now_ms())
}

fn update_tab_state_at_time(
    transaction: &Transaction<'_>,
    tab_id: &str,
    update: &TabStateUpdate,
    at_ms: u64,
) -> anyhow::Result<()> {
    transaction.execute("INSERT OR IGNORE INTO tab_state(tab_id) VALUES(?1)", [tab_id])?;
    if let Some(zoom) = update.zoom {
        transaction
            .execute("UPDATE tab_state SET zoom = ?2 WHERE tab_id = ?1", params![tab_id, zoom])?;
    }
    if let Some(icon) = &update.icon {
        // Checked in the transaction that writes it, so no blob sweep runs in between.
        if let Some(icon) = icon {
            crate::workspace_registry::personal_store::require_icon_asset(transaction, icon)?;
        }
        transaction
            .execute("UPDATE tab_state SET icon = ?2 WHERE tab_id = ?1", params![tab_id, icon])?;
    }
    if let Some(change) = &update.emulation {
        let stored = crate::state::browser_devices::stored_emulation(transaction, tab_id, change)?;
        transaction.execute(
            "UPDATE tab_state SET emulation_json = ?2 WHERE tab_id = ?1",
            params![tab_id, stored],
        )?;
    }
    if let Some(marked) = update.marked_unread {
        // NULL, not 0, when clear: an unmarked row stays empty and is deleted below.
        let stored = marked.then_some(1_i64);
        transaction.execute(
            "UPDATE tab_state SET marked_unread = ?2 WHERE tab_id = ?1",
            params![tab_id, stored],
        )?;
    }
    if let Some(attention) = &update.attention {
        let stored = attention
            .as_deref()
            .map(|reason| {
                attention_value(reason.trim(), at_ms, update.attention_page.as_deref())
                    .map(|value| value.to_string())
            })
            .transpose()?;
        // Compare in the writing transaction, never against an earlier snapshot.
        // A stale identity is a no-op; other requested fields still update.
        transaction.execute(
            "UPDATE tab_state SET attention_json = ?2 WHERE tab_id = ?1
             AND (?3 IS NULL OR json_extract(attention_json, '$.request_id') = ?3)",
            params![tab_id, stored, update.attention_request_id],
        )?;
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
    drop_empty_tab_state_row(transaction, tab_id)?;
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

/// Delete a tab's state row once it holds no field.
fn drop_empty_tab_state_row(transaction: &Transaction<'_>, tab_id: &str) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM tab_state
         WHERE tab_id = ?1 AND zoom IS NULL AND back_json IS NULL AND forward_json IS NULL
           AND icon IS NULL AND emulation_json IS NULL AND marked_unread IS NULL
           AND attention_json IS NULL",
        [tab_id],
    )?;
    Ok(())
}

/// Whether a tab holds an attention mark (`tab-attention-v1`).
#[cfg(test)]
pub(crate) fn tab_has_attention(connection: &Connection, tab_id: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT attention_json IS NOT NULL FROM tab_state WHERE tab_id = ?1",
            [tab_id],
            |row| row.get::<_, bool>(0),
        )
        .optional()?
        .unwrap_or(false))
}

/// Whether a tab holds an attention mark (`tab-attention-v1`) set on a page
/// other than `page`: a cheap read before a navigation's clearing commit.
/// The commit decides again ([`clear_attention_off_page`]).
pub(crate) fn tab_has_attention_off_page(
    connection: &Connection,
    tab_id: &str,
    page: &str,
) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            &format!("SELECT 1 FROM tab_state WHERE tab_id = ?1 AND {ATTENTION_OFF_PAGE}"),
            params![tab_id, page],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// A mark set on another page than `?2`, or one that recorded no page.
const ATTENTION_OFF_PAGE: &str = "attention_json IS NOT NULL
    AND coalesce(json_extract(attention_json, '$.page'), '') <> ?2";

/// A navigation's clear: drop the tab's mark only when it was set on a page
/// other than `page`, in the clearing transaction, so a mark an agent sets on
/// the new page (before this commit) stays. Returns whether it cleared one.
pub(crate) fn clear_attention_off_page(
    transaction: &Transaction<'_>,
    tab_id: &str,
    page: &str,
) -> anyhow::Result<bool> {
    let cleared = transaction.execute(
        &format!(
            "UPDATE tab_state SET attention_json = NULL WHERE tab_id = ?1 AND {ATTENTION_OFF_PAGE}"
        ),
        params![tab_id, page],
    )?;
    if cleared != 0 {
        drop_empty_tab_state_row(transaction, tab_id)?;
    }
    Ok(cleared != 0)
}

/// Drop a closing tab's attention mark, so a reopened tab (which keeps its
/// id) does not ask for the person again.
pub(crate) fn clear_closed_tab_attention(
    transaction: &Transaction<'_>,
    tab_id: &str,
) -> anyhow::Result<()> {
    let cleared = transaction.execute(
        "UPDATE tab_state SET attention_json = NULL
         WHERE tab_id = ?1 AND attention_json IS NOT NULL",
        [tab_id],
    )?;
    if cleared != 0 {
        drop_empty_tab_state_row(transaction, tab_id)?;
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
            "SELECT pane_id, name, color, collapsed, saved_id, icon
             FROM tab_groups WHERE group_id = ?1",
            [group_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            },
        )
        .optional()?;
    let Some((pane_id, name, color, collapsed, saved_id, icon)) = row else { return Ok(None) };
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
        "icon": icon,
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
        "icon": record.icon,
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

#[cfg(test)]
mod marked_unread_tests;

#[cfg(test)]
mod attention_tests;
