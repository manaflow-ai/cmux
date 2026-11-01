//! Reads and restore-side writes of `closed-history-v2`
//! (plans/cmux-next/reopen-closed.md): the public `ClosedItemSnapshot` of a
//! group, the newest groups of a window, the group Reopen Closed takes when
//! the caller names none, and the removal of restored members.
//!
//! Window scope (decision D1): a window sees its own groups and the groups
//! no live window owns (closed windows, sessions without windows); it never
//! sees a group of another live window. A live window is one with a window
//! record.

use std::collections::HashSet;

use cmux_json::JsonSet as _;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

/// Groups a session snapshot carries (`extra.state.closed`) and a list
/// returns without `limit`.
pub(crate) const DEFAULT_LIST_LIMIT: usize = 100;
/// The largest `limit` a list accepts.
pub(crate) const MAX_LIST_LIMIT: usize = 1000;

/// The SQL condition "this group is visible from the window `?1`", or
/// every group when the caller names no window. A live window is one with
/// a window record that is not closed (`open: false`): a closed window's
/// groups, and its own window group, are visible from every window.
fn in_scope(window: Option<&str>) -> &'static str {
    match window {
        Some(_) => {
            "(window_id = ?1 OR window_id IS NULL
              OR window_id NOT IN (SELECT install_id || '/' || window_id FROM window_records
                                   WHERE IFNULL(json_extract(record_json, '$.open'), 1) != 0))"
        }
        None => "(?1 IS NULL)",
    }
}

/// The public `ClosedTabRecord` of one stored tab. A page tab names its
/// page, so Recently Closed can title it by the page rather than by its
/// `about:blank` placeholder (cx-h7y9). A terminal in `evicted` lost its
/// archived screen to the byte budget: its row says the scrollback was not
/// kept (cx-gzh.4.4).
fn public_tab(tab: &Value, evicted: &HashSet<String>) -> Value {
    let mut public = json!({
        "kind": tab["kind"],
        "name": tab["name"],
        "cwd": tab["cwd"],
        "url": tab["url"],
        "browser_profile_id": tab["browser_profile_id"],
        "pinned": tab["pinned"].as_bool().unwrap_or(false),
    });
    if let Some(page) = tab["conversation"]["page"].as_str() {
        public.set("page", json!(page));
    }
    // Keep the canonical agent-tab identity in closed history so clients can
    // still recognize a New Tab that became a chat. Host/install metadata is
    // daemon-owned and stays private; the public record carries only the
    // session id and harness type needed to identify the chat.
    if let Some(agent) = tab
        .get("conversation")
        .and_then(|conversation| conversation.get("agent_session"))
        .and_then(Value::as_object)
    {
        public.set("kind", json!(super::conversation_tabs_store::CONVERSATION_KIND));
        let string_or_null = |key: &str| {
            agent
                .get(key)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map_or(Value::Null, |value| json!(value))
        };
        public.set(
            "agent_session",
            json!({
                "session": string_or_null("session"),
                "harness": string_or_null("harness"),
            }),
        );
    }
    if reopens_empty(tab) {
        public.set("empty", json!(true));
    }
    if tab["terminal_id"].as_str().is_some_and(|id| evicted.contains(id)) {
        public.set("scrollback_not_kept", json!(true));
    }
    public
}

/// Whether a stored tab would reopen as nothing, so Recently Closed can leave it out: an
/// untouched New Tab page (a chat tab whose agent session has no session yet, no page and no
/// route) or a browser on a blank or New Tab page (`about:blank`, Chromium's
/// `chrome://newtab/`). A remote terminal, a chat, a page and any other conversation source
/// never are.
fn reopens_empty(tab: &Value) -> bool {
    if tab["kind"] != "browser" || !tab["remote"].is_null() {
        return false;
    }
    let conversation = &tab["conversation"];
    match conversation.as_object() {
        None => tab["url"].as_str().is_none_or(|url| {
            matches!(
                url.to_ascii_lowercase().as_str(),
                "" | "about:blank" | "chrome://newtab" | "chrome://newtab/"
            )
        }),
        Some(source) => {
            source.keys().all(|key| key == "agent_session")
                && source.get("agent_session").is_some_and(|agent| agent["session"].is_null())
        }
    }
}

/// The public `ClosedMemberRecord` of one stored member.
fn public_member(member: &Value, evicted: &HashSet<String>) -> Value {
    let screens = member["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|screen| {
            let tabs =
                screen["tabs"].as_array().into_iter().flatten().map(|tab| public_tab(tab, evicted));
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
    public_item_in(record, &HashSet::new())
}

/// [`public_item`], marking the tabs of `evicted` terminals.
fn public_item_in(record: &Value, evicted: &HashSet<String>) -> Value {
    let members = record["members"].as_array().cloned().unwrap_or_default();
    let first =
        members.first().map(|member| public_member(member, evicted)).unwrap_or_else(|| json!({}));
    // A deleted space is named by the space, not its first workspace (cx-ncc.44).
    let room = &record["room"]["profile"][0]["name"];
    let mut item = json!({
        "id": record["id"],
        "kind": record["kind"],
        // A window group has no member: its name is the window's workspace.
        "name": if room.is_string() {
            room.clone()
        } else if first["name"].is_null() {
            record["name"].clone()
        } else {
            first["name"].clone()
        },
        "workspace_id": first["workspace_id"],
        "pane_id": first["pane_id"],
        "index": first["index"].as_u64().unwrap_or(0),
        "closed_at_ms": record["closed_at_ms"],
        "screens": first["screens"].as_array().cloned().unwrap_or_default(),
        "window": record["window"],
        "member_count": members.len(),
        "members": members.iter().map(|member| public_member(member, evicted)).collect::<Vec<_>>(),
    });
    // An ungrouped tab or screen group (no member) sits in its workspace.
    // No pane: the app would take it for a closed tab of that pane.
    let ungrouped = ["tab_group", "screen_group"]
        .into_iter()
        .find_map(|field| record.get(field).filter(|group| group.is_object()));
    if let Some(group) = ungrouped {
        item.set("workspace_id", group["workspace_id"].clone());
    }
    // A deleted personal workspace group names the group it forms again.
    if let Some(group) = record.get("group").filter(|group| group.is_object()) {
        item.set(
            "group",
            crate::workspace_registry::personal_mutations::group_archive::public_group(group),
        );
    }
    item
}

/// Every tab a public item (`closed.list` shape) would recreate: every member's, else the top
/// level's (a v1 item), as the Swift `ClosedItem.tabs`.
pub(crate) fn closed_tabs(item: &Value) -> Vec<&Value> {
    fn tabs_of(screens: Option<&Value>) -> Vec<&Value> {
        screens
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|screen| screen.get("tabs").and_then(Value::as_array))
            .flatten()
            .collect()
    }
    match item.get("members").and_then(Value::as_array).filter(|members| !members.is_empty()) {
        Some(members) => members.iter().flat_map(|member| tabs_of(member.get("screens"))).collect(),
        None => tabs_of(item.get("screens")),
    }
}

/// The page a public item (`closed.list` shape) is only, by its address: a closed tab of one
/// browser on a real address. Recently Closed shows a page once however often it was closed,
/// removing or reopening that row takes every close of it, and the Swift
/// `DaemonClosedHistory.pageKey` keys a page the same way (Leo 2026-10-14). A terminal, chat,
/// page tab, screen, workspace, window, group or close of several tabs is no page: nothing tells
/// one close of it from another (two shells in one folder), so each close stays its own.
pub(crate) fn closed_page(item: &Value) -> Option<&str> {
    if item.get("kind").and_then(Value::as_str) != Some("tab")
        || !item.get("group").is_none_or(Value::is_null)
    {
        return None;
    }
    let tabs = closed_tabs(item);
    let &[tab] = tabs.as_slice() else { return None };
    let empty = tab.get("empty").and_then(Value::as_bool) == Some(true);
    if tab.get("kind").and_then(Value::as_str) != Some("browser")
        || empty
        || !tab.get("page").is_none_or(Value::is_null)
    {
        return None;
    }
    tab.get("url").and_then(Value::as_str).filter(|url| !url.is_empty() && *url != "about:blank")
}

/// Removes, in a reopen's commit, every other group that is only the page `page`
/// ([`closed_page`]; a closed tab group of that one page forms its group again, so it stays):
/// the page is open again, so no older close of it takes its Recently Closed row or reopens it
/// a second time. Answers the public changes. Best effort: a group it cannot read stays (and
/// so does every group, when the list cannot be read), so the reopen whose tabs already exist
/// still commits.
pub(crate) fn remove_other_closes(
    transaction: &Transaction<'_>,
    page: &str,
) -> anyhow::Result<Vec<Value>> {
    let mut changes = Vec::new();
    let Ok(items) = closed_items(transaction) else { return Ok(changes) };
    for item in items {
        let Some(id) = item.get("id").and_then(Value::as_str) else { continue };
        if closed_page(&item) != Some(page) {
            continue;
        }
        let Ok(record) = closed_record(transaction, id) else { continue };
        let grouped = record.is_some_and(|record| {
            ["tab_group", "screen_group"]
                .iter()
                .any(|key| record.get(*key).is_some_and(Value::is_object))
        });
        if !grouped && remove_closed(transaction, id)? {
            changes.push(crate::state::store::state_delete("closed", id));
        }
    }
    Ok(changes)
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
    let evicted = crate::workspace_registry::terminal_archive_store::evicted_terminals(connection)?;
    records
        .iter()
        .map(|record| Ok(public_item_in(&serde_json::from_str(record)?, &evicted)))
        .collect()
}

/// The group Reopen Closed takes when the caller names none: the newest
/// group of `window`, else the newest group no live window owns. Without a
/// window: the newest group that is not a closed window (only an app can
/// show a window again, and it names its window).
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
                "SELECT closed_id FROM closed_groups WHERE {} {} ORDER BY seq DESC LIMIT 1",
                in_scope(window),
                if window.is_none() {
                    "AND IFNULL(json_extract(record_json, '$.kind'), '') != 'window'"
                } else {
                    ""
                }
            ),
            params![window],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// The public upserts of `closed_ids` (groups whose archive lost its
/// screen), so a client that follows the change stream shows the note. A
/// group already gone is skipped.
pub(crate) fn closed_upserts(
    connection: &Connection,
    closed_ids: &[String],
) -> anyhow::Result<Vec<Value>> {
    let evicted = crate::workspace_registry::terminal_archive_store::evicted_terminals(connection)?;
    let mut upserts = Vec::new();
    for closed_id in closed_ids {
        if let Some(record) = closed_record(connection, closed_id)? {
            let item = public_item_in(&record, &evicted);
            upserts.push(crate::state::store::state_upsert("closed", closed_id, item));
        }
    }
    Ok(upserts)
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
    record.set("kind", json!(kind));
    record.set("members", Value::Array(members));
    transaction.execute(
        "UPDATE closed_groups SET kind = ?2, record_json = ?3 WHERE closed_id = ?1",
        params![closed_id, kind, serde_json::to_string(&record)?],
    )?;
    let evicted =
        crate::workspace_registry::terminal_archive_store::evicted_terminals(transaction)?;
    Ok(public_item_in(&record, &evicted))
}

/// The newest group whose workspace member recorded closed workspace
/// `workspace` (a `ws_` id), and that member's index. None when no group
/// holds it (live, closed before its id was recorded, or deleted from the
/// history). For `closed.reopen {workspace}` (durable-links-DESIGN.md).
pub(crate) fn group_member_holding_workspace(
    connection: &Connection,
    workspace: &str,
) -> anyhow::Result<Option<(String, usize)>> {
    // A `ws_` id is hex after its prefix. Its `_` is a LIKE wildcard, so LIKE only narrows the
    // candidates; the exact `closed_workspace_id` check below decides.
    let Some(suffix) = workspace.strip_prefix("ws_") else {
        return Ok(None);
    };
    if !suffix.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Ok(None);
    }
    let mut statement = connection.prepare(
        "SELECT closed_id, record_json FROM closed_groups
         WHERE record_json LIKE '%' || ?1 || '%' ORDER BY seq DESC",
    )?;
    let rows = statement
        .query_map([workspace], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;
    for row in rows {
        let (closed_id, record) = row?;
        let record: Value = serde_json::from_str(&record)?;
        let members = record.get("members").and_then(Value::as_array).cloned().unwrap_or_default();
        let holds = |member: &Value| {
            member["kind"] == "workspace"
                && member["closed_workspace_id"].as_str() == Some(workspace)
        };
        if let Some(index) = members.iter().position(holds) {
            return Ok(Some((closed_id, index)));
        }
    }
    Ok(None)
}

/// The newest group that holds tab `tab` (a `tab_` id) and the index of its
/// member that recreates it: a tab member, or the screen or workspace member
/// whose screens hold it. None when no group holds it (live, or deleted from
/// the history). For `closed.reopen {tab}` (durable-links-DESIGN.md).
pub(crate) fn group_member_holding_tab(
    connection: &Connection,
    tab: &str,
) -> anyhow::Result<Option<(String, usize)>> {
    // A `tab_` id is lowercase hex after its prefix: no LIKE wildcard in it.
    if !tab.starts_with("tab_") || !tab[4..].bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Ok(None);
    }
    let mut statement = connection.prepare(
        "SELECT closed_id, record_json FROM closed_groups
         WHERE record_json LIKE '%' || ?1 || '%' ORDER BY seq DESC",
    )?;
    let rows = statement
        .query_map([tab], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;
    for row in rows {
        let (closed_id, record) = row?;
        let record: Value = serde_json::from_str(&record)?;
        let members = record["members"].as_array().cloned().unwrap_or_default();
        let holds = |member: &Value| {
            member["tab_id"].as_str() == Some(tab)
                || closed_tabs(&serde_json::json!({"members": [member]}))
                    .iter()
                    .any(|closed| closed["tab_id"].as_str() == Some(tab))
        };
        if let Some(index) = members.iter().position(holds) {
            return Ok(Some((closed_id, index)));
        }
    }
    Ok(None)
}
