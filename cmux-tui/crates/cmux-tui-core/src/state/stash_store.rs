//! Storage of stashed tabs (`stash-v1`, bead cx-rws36): a native OneTab.
//! A stash is one group of browser tabs that left the workspace on purpose,
//! kept until the user restores or deletes it (no retention pruning).
//!
//! Members have the closed-history tab member shape
//! (`closed_history_store::tab_member`: kind, workspace, pane, index and one
//! screen with one tab record: url, profile, engine, back/forward history),
//! so restore reuses Reopen Closed's placement. Secret query keys are
//! stripped like closed history; incognito tabs are never stashed.
//!
//! A stash closes its tabs through the batch close path with closed history
//! recording on (so every other close-side effect runs), and
//! [`mark_capture`] names the stashed tabs: `capture_closed` takes them
//! ([`take_capture_mark`]) and leaves them out of the closed group, which
//! still keeps any workspace or screen the stash emptied (without the
//! pages). The batch close clears the mark after its patch
//! ([`clear_capture_mark`]), so it never outlives its transaction.
//!
//! Whole workspaces (`stash-workspaces-v1`): the close's transaction first
//! names its stash ([`pend_workspace_stash`]); `capture_closed` takes it
//! ([`take_workspace_stash`]) and stores the workspace members it captured
//! (closed-history workspace shape: screens, layouts, presentation, key) and
//! the tab groups they held in that stash ([`store_workspace_stash`])
//! instead of a closed group. Their terminals end with the close and keep no
//! archived screen (an archive is kept only for a closed-history group): a
//! restored terminal starts again in its directory.

use std::collections::HashSet;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::closed_history_privacy as privacy;
use super::closed_history_store::tab_member;
use crate::workspace_registry::{new_uuid_v4, unix_epoch_ms};
use cmux_json::JsonSet as _;

/// `stash.create|list|restore|delete|import`.
pub const CAPABILITY: &str = "stash-v1";
/// `stash.create {workspaces}`: whole workspaces, terminals included, as
/// `kind: "workspace"` members.
pub const WORKSPACES_CAPABILITY: &str = "stash-workspaces-v1";
/// The resource kind of a stash on `session.events`.
pub(crate) const RESOURCE: &str = "stash";
/// The longest URL a stash keeps (an import refuses longer ones).
const MAX_URL_BYTES: usize = 8192;
/// The most tabs `stash.list` shows of one stashed workspace (`tabs`);
/// `tab_count` counts them all.
const MAX_LISTED_WORKSPACE_TABS: usize = 50;
/// The longest stash name `stash.create` takes, in UTF-8 bytes.
pub(crate) const MAX_NAME_BYTES: usize = 1024;

pub(crate) fn create_stash_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS stashed_groups (
           seq INTEGER PRIMARY KEY AUTOINCREMENT,
           stash_id TEXT UNIQUE NOT NULL,
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
           record_json TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS stash_capture_tabs (
           tab_id TEXT PRIMARY KEY NOT NULL
         );
         CREATE TABLE IF NOT EXISTS stash_capture_workspaces (
           stash_id TEXT PRIMARY KEY NOT NULL,
           name TEXT
         );",
    )?;
    Ok(())
}

pub(crate) fn new_stash_id() -> String {
    format!("stash_{}", new_uuid_v4().replace('-', ""))
}

/// A member's stable id: `stash.restore` and `stash.delete` name members by
/// it, so a request made from an older listing never hits another page.
fn new_member_id() -> String {
    format!("member_{}", new_uuid_v4().replace('-', ""))
}

/// The members of a stash named by `ids` and the rest, in stash order. An
/// id the stash does not hold is `resource.not_found` (nothing changes).
pub(crate) fn choose_members(
    members: Vec<Value>,
    ids: Option<&[String]>,
) -> anyhow::Result<(Vec<Value>, Vec<Value>)> {
    let Some(ids) = ids else { return Ok((members, Vec::new())) };
    if let Some(unknown) =
        ids.iter().find(|id| !members.iter().any(|member| member["id"] == id.as_str()))
    {
        return Err(super::commit::state_not_found("stash", unknown));
    }
    Ok(members.into_iter().partition(|member| ids.iter().any(|id| member["id"] == id.as_str())))
}

/// The close in this transaction stashes `tabs`: `capture_closed` records
/// none of them in the closed history.
pub(crate) fn mark_capture(transaction: &Transaction<'_>, tabs: &[String]) -> anyhow::Result<()> {
    clear_capture_mark(transaction)?;
    for tab in tabs {
        transaction
            .execute("INSERT OR IGNORE INTO stash_capture_tabs(tab_id) VALUES(?1)", [tab])?;
    }
    Ok(())
}

/// The tabs this transaction's close stashes (none for any other close),
/// cleared as they are read.
pub(crate) fn take_capture_mark(transaction: &Transaction<'_>) -> anyhow::Result<HashSet<String>> {
    let tabs = {
        let mut statement = transaction.prepare("SELECT tab_id FROM stash_capture_tabs")?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    clear_capture_mark(transaction)?;
    Ok(tabs)
}

pub(crate) fn clear_capture_mark(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM stash_capture_tabs", [])?;
    transaction.execute("DELETE FROM stash_capture_workspaces", [])?;
    Ok(())
}

/// The close in this transaction stashes the workspaces it closes, whole,
/// as stash `stash_id` named `name`: `capture_closed` stores them there
/// ([`take_workspace_stash`]) and records nothing in the closed history.
pub(crate) fn pend_workspace_stash(
    transaction: &Transaction<'_>,
    stash_id: &str,
    name: Option<&str>,
) -> anyhow::Result<()> {
    clear_capture_mark(transaction)?;
    transaction.execute(
        "INSERT INTO stash_capture_workspaces(stash_id, name) VALUES(?1, ?2)",
        params![stash_id, name],
    )?;
    Ok(())
}

/// The whole-workspace stash this transaction's close stores (none for any
/// other close): its id and name, cleared as it is read.
pub(crate) fn take_workspace_stash(
    transaction: &Transaction<'_>,
) -> anyhow::Result<Option<(String, Option<String>)>> {
    let pending = transaction
        .query_row("SELECT stash_id, name FROM stash_capture_workspaces LIMIT 1", [], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })
        .optional()?;
    transaction.execute("DELETE FROM stash_capture_workspaces", [])?;
    Ok(pending)
}

/// Store the workspace members a whole-workspace close captured (and the
/// tab groups they held) as stash `stash_id`, and queue its public upsert.
/// A member of another kind means a workspace stayed open (a session that
/// keeps emptied workspaces): the close fails, so nothing is half stashed.
pub(crate) fn store_workspace_stash(
    transaction: &Transaction<'_>,
    stash_id: &str,
    name: Option<&str>,
    mut members: Vec<Value>,
    tab_groups: Vec<Value>,
) -> anyhow::Result<()> {
    anyhow::ensure!(!members.is_empty(), "bad request: no workspace to stash");
    anyhow::ensure!(
        members.iter().all(|member| member["kind"] == "workspace"),
        "bad request: a workspace of this session stays open when its tabs close, so it cannot be stashed"
    );
    // The page titles, read while the rows are live (the closed-history
    // record keeps only a tab's own name).
    for member in &mut members {
        for screen in member["screens"].as_array_mut().into_iter().flatten() {
            for tab in screen["tabs"].as_array_mut().into_iter().flatten() {
                if tab["kind"] == "browser"
                    && let Some(tab_id) = tab["tab_id"].as_str().map(str::to_string)
                {
                    tab["title"] = json!(page_title(transaction, &tab_id)?);
                }
            }
        }
    }
    let extra = (!tab_groups.is_empty()).then(|| json!({"tab_groups": tab_groups}));
    let change = insert_stash_with(transaction, stash_id, name, None, members, extra)?;
    super::closed_history_store::queue_change(transaction, &change)
}

/// Why a tab cannot be stashed.
pub(crate) enum Refusal {
    /// In an incognito workspace, or no longer open.
    Private,
    /// A terminal, a conversation, a remote terminal, an app tab or a page
    /// that is not http(s).
    NotPage,
}

/// The stash member of open tab `tab_id` (read while its rows are live), with
/// its page title, or why it cannot be stashed.
pub(crate) fn stash_member(
    connection: &Connection,
    tab_id: &str,
) -> anyhow::Result<Result<Value, Refusal>> {
    let none = HashSet::new();
    let Some(mut member) = tab_member(connection, tab_id, &none, &none, &none)? else {
        return Ok(Err(Refusal::Private));
    };
    let tab = &member["screens"][0]["tabs"][0];
    let page = tab["kind"] == "browser"
        && tab.get("conversation").is_none_or(Value::is_null)
        && tab.get("remote").is_none_or(Value::is_null)
        && tab["url"].as_str().is_some_and(is_web_url);
    if !page || is_app_tab(connection, tab_id)? {
        return Ok(Err(Refusal::NotPage));
    }
    let title = json!(page_title(connection, tab_id)?);
    if let Some(tab) = member.pointer_mut("/screens/0/tabs/0") {
        tab.set("title", title);
    }
    Ok(Ok(member))
}

/// The page title of browser tab `tab_id`, when it has one.
fn page_title(connection: &Connection, tab_id: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT f.title FROM resource_tabs AS t
             JOIN frontend_browser_tabs AS f ON f.browser_id = t.content_id
             WHERE t.public_id = ?1",
            [tab_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten())
}

/// Whether open tab `tab_id` shows an app (`app-screens-v1`): never stashed.
fn is_app_tab(connection: &Connection, tab_id: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM resource_tabs AS t JOIN app_tabs AS a ON a.browser_id = t.content_id
             WHERE t.public_id = ?1",
            [tab_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// The public tab ids of a workspace's open tabs, in sidebar order.
pub(crate) fn workspace_tabs(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT t.public_id FROM resource_tabs AS t
         JOIN resource_panes AS p ON p.public_id = t.pane_id
         JOIN resource_screens AS s ON s.public_id = p.screen_id
         WHERE s.workspace_id = ?1 AND s.deleted_revision IS NULL
           AND p.deleted_revision IS NULL AND t.deleted_revision IS NULL
         ORDER BY s.position ASC, p.creation_ordinal ASC, t.position ASC",
    )?;
    Ok(statement
        .query_map([workspace_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?)
}

/// The name of the workspace a stash is named after.
pub(crate) fn workspace_name(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT w.name FROM resource_workspaces AS rw
             JOIN workspaces AS w ON w.workspace_key = rw.workspace_key
             WHERE rw.public_id = ?1",
            [workspace_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten())
}

/// One member of an imported page: a tab with no place, restored like a
/// closed tab whose pane is gone.
pub(crate) fn imported_member(url: &str, title: Option<&str>, engine: Option<&str>) -> Value {
    json!({
        "kind": "tab",
        "name": null,
        "workspace_id": null,
        "pane_id": null,
        "index": null,
        "screens": [{"name": null, "tabs": [{
            "kind": "browser",
            "name": null,
            "url": privacy::strip_url(url),
            "title": title,
            "browser_profile_id": null,
            "engine": engine,
            "pinned": false,
        }]}],
    })
}

/// An http or https URL with a host, at most 8192 bytes: what an import
/// keeps (a stash only ever reopens web pages).
pub(crate) fn is_web_url(raw: &str) -> bool {
    raw.len() <= MAX_URL_BYTES
        && !raw.chars().any(char::is_control)
        && url::Url::parse(raw).is_ok_and(|url| {
            matches!(url.scheme(), "http" | "https")
                && url.host_str().is_some_and(|h| !h.is_empty())
        })
}

/// Store a stash of `members` named `name`; returns its public upsert.
pub(crate) fn insert_stash(
    transaction: &Transaction<'_>,
    stash_id: &str,
    name: Option<&str>,
    created_at_ms: Option<u64>,
    members: Vec<Value>,
) -> anyhow::Result<Value> {
    insert_stash_with(transaction, stash_id, name, created_at_ms, members, None)
}

/// [`insert_stash`] with the fields of `extra` (`tab_groups`) in its record.
fn insert_stash_with(
    transaction: &Transaction<'_>,
    stash_id: &str,
    name: Option<&str>,
    created_at_ms: Option<u64>,
    mut members: Vec<Value>,
    extra: Option<Value>,
) -> anyhow::Result<Value> {
    for member in &mut members {
        member["id"] = json!(new_member_id());
    }
    let created_at_ms = match created_at_ms {
        Some(created) => created,
        None => unix_epoch_ms()?,
    };
    let mut record = json!({
        "id": stash_id,
        "name": name,
        "created_at_ms": created_at_ms.to_string(),
        "members": members,
    });
    if let Some(Value::Object(extra)) = extra {
        for (key, value) in extra {
            record[key] = value;
        }
    }
    transaction.execute(
        "INSERT INTO stashed_groups(stash_id, created_at_ms, record_json) VALUES(?1, ?2, ?3)",
        params![stash_id, i64::try_from(created_at_ms)?, serde_json::to_string(&record)?],
    )?;
    Ok(super::store::state_upsert(RESOURCE, stash_id, public_stash(&record)))
}

pub(crate) fn stash_record(
    connection: &Connection,
    stash_id: &str,
) -> anyhow::Result<Option<Value>> {
    let stored = connection
        .query_row(
            "SELECT record_json FROM stashed_groups WHERE stash_id = ?1",
            [stash_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    stored.map(|text| -> anyhow::Result<Value> { Ok(serde_json::from_str(&text)?) }).transpose()
}

/// Keep only `keep` of a stash; with none left it is removed. Returns the
/// public change and how many members remain.
pub(crate) fn keep_stash_members(
    transaction: &Transaction<'_>,
    stash_id: &str,
    mut record: Value,
    keep: Vec<Value>,
) -> anyhow::Result<(Value, usize)> {
    let remaining = keep.len();
    if keep.is_empty() {
        transaction.execute("DELETE FROM stashed_groups WHERE stash_id = ?1", [stash_id])?;
        return Ok((super::store::state_delete(RESOURCE, stash_id), 0));
    }
    record.set("members", Value::Array(keep));
    transaction.execute(
        "UPDATE stashed_groups SET record_json = ?2 WHERE stash_id = ?1",
        params![stash_id, serde_json::to_string(&record)?],
    )?;
    Ok((super::store::state_upsert(RESOURCE, stash_id, public_stash(&record)), remaining))
}

/// `StashSnapshot`: the group and its pages (or workspaces), never their
/// back/forward history.
pub(crate) fn public_stash(record: &Value) -> Value {
    let members = record["members"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|member| {
            if member["kind"] == "workspace" {
                return public_workspace_member(member);
            }
            let tab = &member["screens"][0]["tabs"][0];
            json!({
                "id": member["id"],
                "kind": "tab",
                "url": tab["url"],
                "title": tab.get("title").cloned().unwrap_or(Value::Null),
                "browser_profile_id": tab["browser_profile_id"],
                "workspace_id": member["workspace_id"],
            })
        })
        .collect::<Vec<_>>();
    json!({
        "id": record["id"],
        "name": record["name"],
        "created_at_ms": record["created_at_ms"],
        "member_count": members.len(),
        "members": members,
    })
}

/// A stashed workspace in `stash.list`: its name, how many tabs it holds,
/// and the first [`MAX_LISTED_WORKSPACE_TABS`] of them (kind, title, and the
/// URL of a web page; no directory, command or history).
fn public_workspace_member(member: &Value) -> Value {
    let tabs = member["screens"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|screen| screen["tabs"].as_array().into_iter().flatten())
        .collect::<Vec<_>>();
    let listed = tabs
        .iter()
        .take(MAX_LISTED_WORKSPACE_TABS)
        .map(|tab| {
            let present = |field: &str| tab.get(field).is_some_and(|value| !value.is_null());
            let kind = if present("conversation") {
                "conversation"
            } else if present("remote") {
                "remote_terminal"
            } else {
                tab["kind"].as_str().unwrap_or("terminal")
            };
            let url = tab["url"].as_str().filter(|url| kind == "browser" && is_web_url(url));
            let title = tab.get("title").and_then(Value::as_str).or_else(|| tab["name"].as_str());
            json!({"kind": kind, "title": title, "url": url})
        })
        .collect::<Vec<_>>();
    json!({
        "id": member["id"],
        "kind": "workspace",
        "name": member["name"],
        "url": null,
        "title": null,
        "browser_profile_id": null,
        "workspace_id": null,
        "tab_count": tabs.len(),
        "tabs": listed,
    })
}

/// Every stash, newest first.
pub(crate) fn stash_list(connection: &Connection) -> anyhow::Result<Vec<Value>> {
    let mut statement = connection
        .prepare("SELECT record_json FROM stashed_groups ORDER BY created_at_ms DESC, seq DESC")?;
    let rows =
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?;
    rows.iter()
        .map(|text| -> anyhow::Result<Value> {
            Ok(public_stash(&serde_json::from_str::<Value>(text)?))
        })
        .collect()
}
