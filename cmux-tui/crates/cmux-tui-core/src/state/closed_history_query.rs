//! Reads and restore-side writes of `closed-history-v2`
//! (plans/cmux-next/reopen-closed.md): the public `ClosedItemSnapshot` of a
//! group, the newest groups of a window, the group Reopen Closed takes when
//! the caller names none, and the removal of restored members.
//!
//! Window scope (decision D1): a window sees its own groups and the groups
//! no live window owns (closed windows, sessions without windows); it never
//! sees a group of another live window. A live window is one with a window
//! record.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

/// Groups a session snapshot carries (`extra.state.closed`) and a list
/// returns without `limit`.
pub(crate) const DEFAULT_LIST_LIMIT: usize = 100;
/// The largest `limit` a list accepts.
pub(crate) const MAX_LIST_LIMIT: usize = 1000;

/// The SQL condition "this group is visible from the window `?1`", or
/// every group when the caller names no window.
fn in_scope(window: Option<&str>) -> &'static str {
    match window {
        Some(_) => {
            "(window_id = ?1 OR window_id IS NULL
              OR window_id NOT IN (SELECT install_id || '/' || window_id FROM window_records))"
        }
        None => "(?1 IS NULL)",
    }
}

fn public_tab(tab: &Value) -> Value {
    json!({
        "kind": tab["kind"],
        "name": tab["name"],
        "cwd": tab["cwd"],
        "url": tab["url"],
        "browser_profile_id": tab["browser_profile_id"],
        "pinned": tab["pinned"].as_bool().unwrap_or(false),
    })
}

/// The public `ClosedMemberRecord` of one stored member.
fn public_member(member: &Value) -> Value {
    let screens = member["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|screen| {
            let tabs = screen["tabs"].as_array().into_iter().flatten().map(public_tab);
            json!({"name": screen["name"], "tabs": tabs.collect::<Vec<_>>()})
        })
        .collect::<Vec<_>>();
    json!({
        "kind": member["kind"],
        "name": member["name"],
        "workspace_id": member["workspace_id"],
        "pane_id": member["pane_id"],
        "index": member["index"].as_u64().unwrap_or(0),
        "screens": screens,
    })
}

/// The public `ClosedItemSnapshot` of a stored group. The top-level fields
/// of a v1 item mirror the first member, so older clients keep working.
pub(crate) fn public_item(record: &Value) -> Value {
    let members = record["members"].as_array().cloned().unwrap_or_default();
    let first = members.first().map(public_member).unwrap_or_else(|| json!({}));
    json!({
        "id": record["id"],
        "kind": record["kind"],
        "name": first["name"],
        "workspace_id": first["workspace_id"],
        "pane_id": first["pane_id"],
        "index": first["index"].as_u64().unwrap_or(0),
        "closed_at_ms": record["closed_at_ms"],
        "screens": first["screens"].as_array().cloned().unwrap_or_default(),
        "window": record["window"],
        "member_count": members.len(),
        "members": members.iter().map(public_member).collect::<Vec<_>>(),
    })
}

/// The newest [`DEFAULT_LIST_LIMIT`] groups of every window.
pub(crate) fn closed_items(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    closed_items_in(connection, None, DEFAULT_LIST_LIMIT)
}

/// The newest `limit` groups visible from `window` (None: every group).
pub(crate) fn closed_items_in(
    connection: &Connection,
    window: Option<&str>,
    limit: usize,
) -> anyhow::Result<Vec<Value>> {
    let mut statement = connection.prepare(&format!(
        "SELECT record_json FROM closed_groups WHERE {} ORDER BY seq DESC LIMIT ?2",
        in_scope(window)
    ))?;
    let limit = i64::try_from(limit.min(MAX_LIST_LIMIT))?;
    let records = statement
        .query_map(params![window, limit], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    records.iter().map(|record| Ok(public_item(&serde_json::from_str(record)?))).collect()
}

/// The group Reopen Closed takes when the caller names none: the newest
/// group of `window`, else the newest group no live window owns. Without a
/// window: the newest group.
pub(crate) fn newest_for_window(
    connection: &Connection,
    window: Option<&str>,
) -> anyhow::Result<Option<String>> {
    let own = match window {
        Some(window) => connection
            .query_row(
                "SELECT closed_id FROM closed_groups WHERE window_id = ?1 ORDER BY seq DESC LIMIT 1",
                [window],
                |row| row.get::<_, String>(0),
            )
            .optional()?,
        None => None,
    };
    if own.is_some() {
        return Ok(own);
    }
    Ok(connection
        .query_row(
            &format!(
                "SELECT closed_id FROM closed_groups WHERE {} ORDER BY seq DESC LIMIT 1",
                in_scope(window)
            ),
            params![window],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// The full stored group (including the terminal ids reopen uses).
pub(crate) fn closed_record(
    connection: &Connection,
    closed_id: &str,
) -> anyhow::Result<Option<Value>> {
    let record = connection
        .query_row(
            "SELECT record_json FROM closed_groups WHERE closed_id = ?1",
            [closed_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    record.map(|record| Ok(serde_json::from_str(&record)?)).transpose()
}

/// Remove a fully reopened or deleted group. Returns whether it existed.
/// A group copied from `closed-history-v1` also leaves the v1 table and the
/// copy ledger, so a downgraded daemon cannot reopen the item again.
pub(crate) fn remove_closed(
    transaction: &Transaction<'_>,
    closed_id: &str,
) -> anyhow::Result<bool> {
    let removed =
        transaction.execute("DELETE FROM closed_groups WHERE closed_id = ?1", [closed_id])? > 0;
    let copied: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'closed_v1_copied')",
        [],
        |row| row.get(0),
    )?;
    if copied {
        transaction.execute("DELETE FROM closed_v1_copied WHERE closed_id = ?1", [closed_id])?;
        transaction.execute("DELETE FROM closed_history WHERE closed_id = ?1", [closed_id])?;
    }
    Ok(removed)
}

/// Keep only `members` of a partly reopened group; returns its new public
/// item. The group keeps its id, place in the order and window.
pub(crate) fn keep_members(
    transaction: &Transaction<'_>,
    closed_id: &str,
    mut record: Value,
    members: Vec<Value>,
) -> anyhow::Result<Value> {
    let kind = super::closed_history_store::group_kind(&members);
    record["kind"] = json!(kind);
    record["members"] = Value::Array(members);
    transaction.execute(
        "UPDATE closed_groups SET kind = ?2, record_json = ?3 WHERE closed_id = ?1",
        params![closed_id, kind, serde_json::to_string(&record)?],
    )?;
    Ok(public_item(&record))
}
