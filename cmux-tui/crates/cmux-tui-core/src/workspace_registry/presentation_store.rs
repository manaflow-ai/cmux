//! Durable frontend presentation metadata for the shared tree.
//!
//! Workspace groups and the per-workspace presentation fields (group
//! membership, color, icon, custom title) are shared durable state that every
//! frontend renders, so they live next to the workspace registry instead of in
//! a per-window frontend projection.
//!
//! Every table here is additive and carries no foreign key. An older binary
//! that opens the same registry ignores these tables, so creating them needs
//! no schema version bump and a rollback to that binary keeps working (it
//! simply stops showing the metadata). Rows that name a tombstoned workspace
//! are inert: snapshots join against live workspaces.
//!
//! Each mutation appends one `state` journal record with `advisory` replay.
//! The materialized table is authoritative for restoration, so a restore
//! preview never counts these records as unsupported required state.

use std::collections::{HashMap, HashSet};

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::{Value, json};

use super::session_journal::{JournalAppend, append_journal_record};
use super::{
    JournalClass, JournalProducer, JournalReplayPolicy, JournalSensitivity, JournalSubject,
    WorkspaceRegistry, new_uuid_v4, unix_epoch_ms,
};

/// Longest accepted group name or workspace title, in characters.
pub const MAX_PRESENTATION_TEXT_CHARS: usize = 256;
/// Longest accepted client-chosen group id, in bytes.
pub const MAX_WORKSPACE_GROUP_ID_BYTES: usize = 64;

pub(super) fn create_presentation_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_groups (
           group_id TEXT PRIMARY KEY NOT NULL,
           name TEXT NOT NULL,
           color TEXT,
           position INTEGER NOT NULL CHECK(position >= 0),
           collapsed INTEGER NOT NULL DEFAULT 0 CHECK(collapsed IN (0,1))
         );
         CREATE TABLE IF NOT EXISTS workspace_presentation (
           workspace_key TEXT PRIMARY KEY NOT NULL,
           group_id TEXT,
           color TEXT,
           icon TEXT,
           title TEXT
         );
         CREATE TABLE IF NOT EXISTS tab_presentation (
           tab_id TEXT PRIMARY KEY NOT NULL,
           pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1))
         );
         CREATE TABLE IF NOT EXISTS notification_acks (
           notification_id TEXT PRIMARY KEY NOT NULL,
           acked_at_ms INTEGER NOT NULL CHECK(acked_at_ms >= 0)
         );
         CREATE TABLE IF NOT EXISTS frontend_browser_tabs (
           browser_id TEXT PRIMARY KEY NOT NULL,
           engine TEXT NOT NULL CHECK(engine IN ('webkit','cef')),
           url TEXT NOT NULL,
           title TEXT,
           favicon_url TEXT,
           profile_id TEXT
         );",
    )?;
    Ok(())
}

/// One sidebar group. Groups are ordered by their index in
/// [`PresentationSnapshot::groups`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorkspaceGroupRecord {
    pub id: String,
    pub name: String,
    pub color: Option<String>,
    pub collapsed: bool,
}

/// Presentation fields of one live workspace.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorkspacePresentationRecord {
    pub group: Option<String>,
    pub color: Option<String>,
    pub icon: Option<String>,
    pub title: Option<String>,
}

impl WorkspacePresentationRecord {
    fn is_empty(&self) -> bool {
        self.group.is_none() && self.color.is_none() && self.icon.is_none() && self.title.is_none()
    }
}

/// A partial workspace presentation update. `None` leaves a field unchanged,
/// `Some(None)` clears it, and `Some(Some(value))` sets it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorkspacePresentationUpdate {
    pub group: Option<Option<String>>,
    pub color: Option<Option<String>>,
    pub icon: Option<Option<String>>,
    pub title: Option<Option<String>>,
}

impl WorkspacePresentationUpdate {
    pub fn validate(&self) -> anyhow::Result<()> {
        if let Some(Some(group)) = &self.group {
            validate_workspace_group_id(group)?;
        }
        if let Some(Some(color)) = &self.color {
            validate_presentation_color(color)?;
        }
        if let Some(Some(icon)) = &self.icon {
            validate_presentation_icon(icon)?;
        }
        if let Some(Some(title)) = &self.title {
            validate_presentation_text("workspace title", title)?;
        }
        Ok(())
    }

    fn apply_to(&self, record: &mut WorkspacePresentationRecord) {
        if let Some(group) = &self.group {
            record.group = group.clone();
        }
        if let Some(color) = &self.color {
            record.color = color.clone();
        }
        if let Some(icon) = &self.icon {
            record.icon = icon.clone();
        }
        if let Some(title) = &self.title {
            record.title = title.clone();
        }
    }
}

/// Everything the tree serializer needs from this store, loaded once at
/// startup and kept current by the mux after each commit.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PresentationSnapshot {
    pub groups: Vec<WorkspaceGroupRecord>,
    /// Keyed by the stable workspace key.
    pub workspaces: HashMap<String, WorkspacePresentationRecord>,
    /// Public ids (`tab_...`) of pinned live tabs.
    pub pinned_tabs: HashSet<String>,
    /// Frontend-rendered browser contents keyed by public browser id
    /// (`browser_...`). Rows exist before their browser commits, so a
    /// pending creation is already known when its surface spawns.
    pub frontend_browsers: HashMap<String, FrontendBrowserRecord>,
}

/// Longest accepted frontend browser URL or favicon URL, in bytes.
pub const MAX_FRONTEND_BROWSER_URL_BYTES: usize = 32 * 1024;
/// Longest accepted frontend browser page title, in characters.
pub const MAX_FRONTEND_BROWSER_TITLE_CHARS: usize = 2048;

/// A browser tab whose page the frontend renders itself (WebKit or CEF).
/// The daemon stores its location and presentation and never attaches a
/// CDP target or renders frames for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FrontendBrowserRecord {
    pub engine: String,
    pub url: String,
    pub title: Option<String>,
    pub favicon_url: Option<String>,
    pub profile_id: Option<String>,
}

impl FrontendBrowserRecord {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            matches!(self.engine.as_str(), "webkit" | "cef"),
            "bad request: engine must be \"webkit\" or \"cef\""
        );
        validate_frontend_browser_url("url", &self.url)?;
        if let Some(favicon_url) = &self.favicon_url {
            validate_frontend_browser_url("favicon_url", favicon_url)?;
        }
        if let Some(title) = &self.title {
            validate_frontend_browser_title(title)?;
        }
        if let Some(profile_id) = &self.profile_id {
            anyhow::ensure!(
                !profile_id.is_empty()
                    && profile_id.len() <= 128
                    && profile_id.bytes().all(|byte| byte.is_ascii_graphic()),
                "bad request: profile_id must be 1-128 printable ASCII characters"
            );
        }
        Ok(())
    }
}

pub fn validate_frontend_browser_url(label: &str, value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(!value.trim().is_empty(), "bad request: {label} cannot be empty");
    anyhow::ensure!(
        value.len() <= MAX_FRONTEND_BROWSER_URL_BYTES,
        "bad request: {label} exceeds {MAX_FRONTEND_BROWSER_URL_BYTES} bytes"
    );
    anyhow::ensure!(
        !value.chars().any(char::is_control),
        "bad request: {label} contains a control character"
    );
    Ok(())
}

pub fn validate_frontend_browser_title(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        value.chars().count() <= MAX_FRONTEND_BROWSER_TITLE_CHARS,
        "bad request: title exceeds {MAX_FRONTEND_BROWSER_TITLE_CHARS} characters"
    );
    anyhow::ensure!(
        !value.chars().any(char::is_control),
        "bad request: title contains a control character"
    );
    Ok(())
}

fn browser_subject(browser_id: &str) -> JournalSubject {
    JournalSubject { kind: "browser".into(), id: browser_id.to_string() }
}

fn validate_browser_public_id(browser_id: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        browser_id.len() == 40
            && browser_id.starts_with("browser_")
            && browser_id[8..].bytes().all(|byte| byte.is_ascii_hexdigit()),
        "bad request: invalid browser id {browser_id}"
    );
    Ok(())
}

fn read_frontend_browser(
    connection: &Connection,
    browser_id: &str,
) -> anyhow::Result<Option<FrontendBrowserRecord>> {
    Ok(connection
        .query_row(
            "SELECT engine, url, title, favicon_url, profile_id FROM frontend_browser_tabs
             WHERE browser_id = ?1",
            [browser_id],
            |row| {
                Ok(FrontendBrowserRecord {
                    engine: row.get(0)?,
                    url: row.get(1)?,
                    title: row.get(2)?,
                    favicon_url: row.get(3)?,
                    profile_id: row.get(4)?,
                })
            },
        )
        .optional()?)
}

impl PresentationSnapshot {
    pub fn workspace(&self, key: &str) -> Option<&WorkspacePresentationRecord> {
        self.workspaces.get(key)
    }

    pub fn group(&self, id: &str) -> Option<&WorkspaceGroupRecord> {
        self.groups.iter().find(|group| group.id == id)
    }

    pub fn group_index(&self, id: &str) -> Option<usize> {
        self.groups.iter().position(|group| group.id == id)
    }

    /// Apply an update the registry has already committed.
    pub fn apply_workspace_update(&mut self, key: &str, update: &WorkspacePresentationUpdate) {
        let record = self.workspaces.entry(key.to_string()).or_default();
        update.apply_to(record);
        if record.is_empty() {
            self.workspaces.remove(key);
        }
    }

    /// Drop the membership of every workspace in a deleted group.
    pub fn remove_group(&mut self, id: &str) {
        self.groups.retain(|group| group.id != id);
        let mut empty = Vec::new();
        for (key, record) in &mut self.workspaces {
            if record.group.as_deref() == Some(id) {
                record.group = None;
                if record.is_empty() {
                    empty.push(key.clone());
                }
            }
        }
        for key in empty {
            self.workspaces.remove(&key);
        }
    }
}

pub fn new_workspace_group_id() -> String {
    format!("grp_{}", new_uuid_v4().replace('-', ""))
}

pub fn validate_workspace_group_id(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= MAX_WORKSPACE_GROUP_ID_BYTES
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric()
                    || matches!(byte, b'_' | b'-' | b'.' | b':')),
        "bad request: group id must be 1-{MAX_WORKSPACE_GROUP_ID_BYTES} ASCII letters, digits, '_', '-', '.', or ':'"
    );
    Ok(())
}

/// A name or title: nonempty after trimming, bounded, and free of control
/// characters.
pub fn validate_presentation_text(label: &str, value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(!value.trim().is_empty(), "bad request: {label} cannot be empty");
    anyhow::ensure!(
        value.chars().count() <= MAX_PRESENTATION_TEXT_CHARS,
        "bad request: {label} exceeds {MAX_PRESENTATION_TEXT_CHARS} characters"
    );
    anyhow::ensure!(
        !value.chars().any(char::is_control),
        "bad request: {label} contains a control character"
    );
    Ok(())
}

/// A color is either a frontend palette token (`gray`, `slate-2`, ...) or a
/// `#RRGGBB` / `#RRGGBBAA` hex value. The daemon validates only the shape;
/// the frontend owns the palette.
pub fn validate_presentation_color(value: &str) -> anyhow::Result<()> {
    let hex = value.strip_prefix('#').is_some_and(|digits| {
        matches!(digits.len(), 6 | 8) && digits.bytes().all(|byte| byte.is_ascii_hexdigit())
    });
    let token = !value.is_empty()
        && value.len() <= 32
        && value.as_bytes()[0].is_ascii_lowercase()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');
    anyhow::ensure!(
        hex || token,
        "bad request: color must be a palette token ([a-z][a-z0-9-]{{0,31}}) or #RRGGBB[AA]"
    );
    Ok(())
}

/// An SF Symbol name such as `terminal`, `folder.fill`, or `0.circle`.
pub fn validate_presentation_icon(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= 128
            && !value.starts_with('.')
            && !value.ends_with('.')
            && value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'.'),
        "bad request: icon must be an SF Symbol name (lowercase letters, digits, and dots)"
    );
    Ok(())
}

fn transaction_session_id(transaction: &Transaction<'_>) -> anyhow::Result<String> {
    transaction
        .query_row("SELECT value FROM meta WHERE key = 'session_public_id'", [], |row| row.get(0))
        .context("read journal session id")
}

/// Append the immutable fact for one presentation mutation in the caller's
/// transaction.
pub(super) fn append_presentation_record(
    transaction: &Transaction<'_>,
    kind: &str,
    subjects: Vec<JournalSubject>,
    payload: &Value,
) -> anyhow::Result<()> {
    let mut all =
        vec![JournalSubject { kind: "session".into(), id: transaction_session_id(transaction)? }];
    all.extend(subjects);
    let producer = JournalProducer { kind: "presentation".into(), id: "cmux-tui".into() };
    let event_id = format!("event_presentation_{}", new_uuid_v4().replace('-', ""));
    append_journal_record(
        transaction,
        &JournalAppend {
            event_id: &event_id,
            schema_version: 1,
            kind,
            class: JournalClass::State,
            replay: JournalReplayPolicy::Advisory,
            occurred_at_ms: unix_epoch_ms()?,
            producer: &producer,
            authority: None,
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: &all,
            sensitivity: JournalSensitivity::Metadata,
            payload,
            content: None,
            resource_revision: None,
            previous_resource_revision: None,
        },
    )?;
    Ok(())
}

fn group_subject(id: &str) -> JournalSubject {
    JournalSubject { kind: "workspace_group".into(), id: id.to_string() }
}

fn workspace_subject(
    transaction: &Transaction<'_>,
    workspace_key: &str,
) -> anyhow::Result<Option<JournalSubject>> {
    let public_id = transaction
        .query_row(
            "SELECT public_id FROM resource_workspaces WHERE workspace_key = ?1",
            [workspace_key],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    Ok(public_id.map(|id| JournalSubject { kind: "workspace".into(), id }))
}

fn read_groups(transaction: &Connection) -> anyhow::Result<Vec<WorkspaceGroupRecord>> {
    let mut statement = transaction.prepare(
        "SELECT group_id, name, color, collapsed FROM workspace_groups
         ORDER BY position ASC, group_id ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(WorkspaceGroupRecord {
            id: row.get(0)?,
            name: row.get(1)?,
            color: row.get(2)?,
            collapsed: row.get::<_, i64>(3)? != 0,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

fn write_group_order(transaction: &Connection, groups: &[String]) -> anyhow::Result<()> {
    for (position, id) in groups.iter().enumerate() {
        transaction.execute(
            "UPDATE workspace_groups SET position = ?2 WHERE group_id = ?1",
            params![id, i64::try_from(position)?],
        )?;
    }
    Ok(())
}

fn read_group(transaction: &Connection, id: &str) -> anyhow::Result<Option<WorkspaceGroupRecord>> {
    Ok(read_groups(transaction)?.into_iter().find(|group| group.id == id))
}

fn read_workspace_presentation(
    transaction: &Connection,
    workspace_key: &str,
) -> anyhow::Result<WorkspacePresentationRecord> {
    Ok(transaction
        .query_row(
            "SELECT group_id, color, icon, title FROM workspace_presentation
             WHERE workspace_key = ?1",
            [workspace_key],
            |row| {
                Ok(WorkspacePresentationRecord {
                    group: row.get(0)?,
                    color: row.get(1)?,
                    icon: row.get(2)?,
                    title: row.get(3)?,
                })
            },
        )
        .optional()?
        .unwrap_or_default())
}

/// Write one workspace's presentation row inside a workspace-registry
/// transaction. A named group must exist.
pub(super) fn write_workspace_presentation(
    transaction: &Transaction<'_>,
    workspace_key: &str,
    update: &WorkspacePresentationUpdate,
) -> anyhow::Result<()> {
    update.validate()?;
    if let Some(Some(group)) = &update.group {
        let exists = transaction
            .query_row("SELECT 1 FROM workspace_groups WHERE group_id = ?1", [group], |_| Ok(()))
            .optional()?
            .is_some();
        anyhow::ensure!(exists, "unknown workspace group {group}");
    }
    let mut record = read_workspace_presentation(transaction, workspace_key)?;
    update.apply_to(&mut record);
    if record.is_empty() {
        transaction.execute(
            "DELETE FROM workspace_presentation WHERE workspace_key = ?1",
            [workspace_key],
        )?;
    } else {
        transaction.execute(
            "INSERT INTO workspace_presentation(workspace_key, group_id, color, icon, title)
             VALUES(?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(workspace_key) DO UPDATE SET
               group_id = excluded.group_id,
               color = excluded.color,
               icon = excluded.icon,
               title = excluded.title",
            params![workspace_key, record.group, record.color, record.icon, record.title],
        )?;
    }
    let subjects = workspace_subject(transaction, workspace_key)?.into_iter().collect();
    append_presentation_record(
        transaction,
        "workspace.presentation.updated",
        subjects,
        &json!({
            "workspace_key": workspace_key,
            "group": record.group,
            "color": record.color,
            "icon": record.icon,
            "title": record.title,
        }),
    )
}

impl WorkspaceRegistry {
    /// Groups in order plus the presentation of every live workspace.
    pub fn presentation_snapshot(&self) -> anyhow::Result<PresentationSnapshot> {
        let groups = read_groups(&self.connection)?;
        let mut statement = self.connection.prepare(
            "SELECT p.workspace_key, p.group_id, p.color, p.icon, p.title
             FROM workspace_presentation AS p
             JOIN workspaces AS w ON w.workspace_key = p.workspace_key
             WHERE w.tombstoned = 0",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                WorkspacePresentationRecord {
                    group: row.get(1)?,
                    color: row.get(2)?,
                    icon: row.get(3)?,
                    title: row.get(4)?,
                },
            ))
        })?;
        let mut workspaces = HashMap::new();
        for row in rows {
            let (key, mut record) = row?;
            if record.group.as_deref().is_some_and(|id| !groups.iter().any(|g| g.id == id)) {
                record.group = None;
            }
            if !record.is_empty() {
                workspaces.insert(key, record);
            }
        }
        let pinned_tabs = self
            .connection
            .prepare(
                "SELECT p.tab_id FROM tab_presentation AS p
                 JOIN resource_tabs AS t ON t.public_id = p.tab_id
                 WHERE p.pinned = 1 AND t.deleted_revision IS NULL",
            )?
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?;
        let mut frontend_browsers = HashMap::new();
        {
            let mut statement = self.connection.prepare(
                "SELECT f.browser_id, f.engine, f.url, f.title, f.favicon_url, f.profile_id
                 FROM frontend_browser_tabs AS f
                 WHERE NOT EXISTS (
                   SELECT 1 FROM resource_browsers AS b
                   WHERE b.public_id = f.browser_id AND b.lifecycle = 'tombstoned'
                 )",
            )?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    FrontendBrowserRecord {
                        engine: row.get(1)?,
                        url: row.get(2)?,
                        title: row.get(3)?,
                        favicon_url: row.get(4)?,
                        profile_id: row.get(5)?,
                    },
                ))
            })?;
            for row in rows {
                let (browser_id, record) = row?;
                frontend_browsers.insert(browser_id, record);
            }
        }
        Ok(PresentationSnapshot { groups, workspaces, pinned_tabs, frontend_browsers })
    }

    /// Create a group at `index` (default: last). Creating an id that
    /// already exists with the same name is an idempotent retry and returns
    /// the stored group with `false`.
    pub fn create_workspace_group(
        &mut self,
        id: &str,
        name: &str,
        color: Option<&str>,
        collapsed: bool,
        index: Option<usize>,
    ) -> anyhow::Result<(WorkspaceGroupRecord, bool)> {
        validate_workspace_group_id(id)?;
        validate_presentation_text("group name", name)?;
        if let Some(color) = color {
            validate_presentation_color(color)?;
        }
        let tx = self.connection.transaction()?;
        if let Some(existing) = read_group(&tx, id)? {
            anyhow::ensure!(
                existing.name == name,
                "workspace group {id} already exists with a different name"
            );
            return Ok((existing, false));
        }
        let mut order = read_groups(&tx)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
        let index = index.unwrap_or(order.len()).min(order.len());
        tx.execute(
            "INSERT INTO workspace_groups(group_id, name, color, position, collapsed)
             VALUES(?1, ?2, ?3, ?4, ?5)",
            params![id, name, color, i64::try_from(order.len())?, i64::from(collapsed)],
        )?;
        order.insert(index, id.to_string());
        write_group_order(&tx, &order)?;
        let group = WorkspaceGroupRecord {
            id: id.to_string(),
            name: name.to_string(),
            color: color.map(str::to_string),
            collapsed,
        };
        append_presentation_record(
            &tx,
            "workspace.group.created",
            vec![group_subject(id)],
            &json!({"group": group, "index": index}),
        )?;
        tx.commit()?;
        Ok((group, true))
    }

    /// Rename, recolor, or collapse a group. `color: Some(None)` clears it.
    pub fn update_workspace_group(
        &mut self,
        id: &str,
        name: Option<&str>,
        color: Option<Option<&str>>,
        collapsed: Option<bool>,
    ) -> anyhow::Result<WorkspaceGroupRecord> {
        validate_workspace_group_id(id)?;
        if let Some(name) = name {
            validate_presentation_text("group name", name)?;
        }
        if let Some(Some(color)) = color {
            validate_presentation_color(color)?;
        }
        let tx = self.connection.transaction()?;
        let mut group =
            read_group(&tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown workspace group {id}"))?;
        if let Some(name) = name {
            group.name = name.to_string();
        }
        if let Some(color) = color {
            group.color = color.map(str::to_string);
        }
        if let Some(collapsed) = collapsed {
            group.collapsed = collapsed;
        }
        tx.execute(
            "UPDATE workspace_groups SET name = ?2, color = ?3, collapsed = ?4 WHERE group_id = ?1",
            params![id, group.name, group.color, i64::from(group.collapsed)],
        )?;
        append_presentation_record(
            &tx,
            "workspace.group.updated",
            vec![group_subject(id)],
            &json!({"group": group}),
        )?;
        tx.commit()?;
        Ok(group)
    }

    /// Delete a group. Its workspaces stay in place and become ungrouped;
    /// their keys are returned.
    pub fn delete_workspace_group(&mut self, id: &str) -> anyhow::Result<Vec<String>> {
        validate_workspace_group_id(id)?;
        let tx = self.connection.transaction()?;
        anyhow::ensure!(read_group(&tx, id)?.is_some(), "unknown workspace group {id}");
        let members = {
            let mut statement = tx.prepare(
                "SELECT workspace_key FROM workspace_presentation WHERE group_id = ?1
                 ORDER BY workspace_key",
            )?;
            statement
                .query_map([id], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        tx.execute("DELETE FROM workspace_groups WHERE group_id = ?1", [id])?;
        tx.execute("UPDATE workspace_presentation SET group_id = NULL WHERE group_id = ?1", [id])?;
        tx.execute(
            "DELETE FROM workspace_presentation
             WHERE group_id IS NULL AND color IS NULL AND icon IS NULL AND title IS NULL",
            [],
        )?;
        let order = read_groups(&tx)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
        write_group_order(&tx, &order)?;
        append_presentation_record(
            &tx,
            "workspace.group.deleted",
            vec![group_subject(id)],
            &json!({"group_id": id, "ungrouped_workspace_keys": members}),
        )?;
        tx.commit()?;
        Ok(members)
    }

    /// Move a group to a zero-based insertion index among groups, with the
    /// same insertion-point semantics as `move-workspace`. Returns the final
    /// index.
    pub fn move_workspace_group(&mut self, id: &str, index: usize) -> anyhow::Result<usize> {
        validate_workspace_group_id(id)?;
        let tx = self.connection.transaction()?;
        let mut order = read_groups(&tx)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
        let old_index = order
            .iter()
            .position(|candidate| candidate == id)
            .ok_or_else(|| anyhow::anyhow!("unknown workspace group {id}"))?;
        let new_index = if index > old_index { index.saturating_sub(1) } else { index }
            .min(order.len().saturating_sub(1));
        if new_index != old_index {
            let moved = order.remove(old_index);
            order.insert(new_index, moved);
            write_group_order(&tx, &order)?;
            append_presentation_record(
                &tx,
                "workspace.group.moved",
                vec![group_subject(id)],
                &json!({"group_id": id, "index": new_index}),
            )?;
        }
        tx.commit()?;
        Ok(new_index)
    }

    /// Store a tab placement's pinned flag, keyed by its public tab id.
    /// Rows of closed tabs are pruned on the way. Returns whether the flag
    /// changed.
    pub fn set_tab_pinned(&mut self, tab_id: &str, pinned: bool) -> anyhow::Result<bool> {
        anyhow::ensure!(
            tab_id.starts_with("tab_") && tab_id.len() <= 64,
            "bad request: invalid tab id {tab_id}"
        );
        let tx = self.connection.transaction()?;
        let live = tx
            .query_row(
                "SELECT 1 FROM resource_tabs WHERE public_id = ?1 AND deleted_revision IS NULL",
                [tab_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        anyhow::ensure!(live, "unknown tab {tab_id}");
        let current = tx
            .query_row("SELECT pinned FROM tab_presentation WHERE tab_id = ?1", [tab_id], |row| {
                row.get::<_, i64>(0)
            })
            .optional()?
            .is_some_and(|value| value != 0);
        tx.execute(
            "DELETE FROM tab_presentation WHERE tab_id NOT IN (
               SELECT public_id FROM resource_tabs WHERE deleted_revision IS NULL
             )",
            [],
        )?;
        if current == pinned {
            tx.commit()?;
            return Ok(false);
        }
        if pinned {
            tx.execute(
                "INSERT INTO tab_presentation(tab_id, pinned) VALUES(?1, 1)
                 ON CONFLICT(tab_id) DO UPDATE SET pinned = 1",
                [tab_id],
            )?;
        } else {
            tx.execute("DELETE FROM tab_presentation WHERE tab_id = ?1", [tab_id])?;
        }
        append_presentation_record(
            &tx,
            "tab.presentation.updated",
            vec![JournalSubject { kind: "tab".into(), id: tab_id.to_string() }],
            &json!({"tab_id": tab_id, "pinned": pinned}),
        )?;
        tx.commit()?;
        Ok(true)
    }

    /// Register a frontend-rendered browser before its tab commits, so the
    /// daemon never bootstraps a CDP target for it. The browser id must be
    /// fresh.
    pub fn put_frontend_browser(
        &mut self,
        browser_id: &str,
        record: &FrontendBrowserRecord,
    ) -> anyhow::Result<()> {
        validate_browser_public_id(browser_id)?;
        record.validate()?;
        let tx = self.connection.transaction()?;
        let exists = tx
            .query_row("SELECT 1 FROM resource_browsers WHERE public_id = ?1", [browser_id], |_| {
                Ok(())
            })
            .optional()?
            .is_some();
        anyhow::ensure!(!exists, "browser {browser_id} already exists");
        tx.execute(
            "INSERT INTO frontend_browser_tabs(browser_id, engine, url, title, favicon_url, profile_id)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                browser_id,
                record.engine,
                record.url,
                record.title,
                record.favicon_url,
                record.profile_id
            ],
        )?;
        append_presentation_record(
            &tx,
            "browser.frontend.registered",
            vec![browser_subject(browser_id)],
            &json!({"browser_id": browser_id, "browser": record}),
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Update a frontend browser's location and presentation. `None` leaves
    /// a field unchanged; `favicon_url: Some(None)` clears the favicon.
    pub fn update_frontend_browser(
        &mut self,
        browser_id: &str,
        url: Option<&str>,
        title: Option<&str>,
        favicon_url: Option<Option<&str>>,
    ) -> anyhow::Result<(FrontendBrowserRecord, bool)> {
        validate_browser_public_id(browser_id)?;
        let tx = self.connection.transaction()?;
        let before = read_frontend_browser(&tx, browser_id)?
            .ok_or_else(|| anyhow::anyhow!("browser {browser_id} is not frontend-rendered"))?;
        let mut record = before.clone();
        if let Some(url) = url {
            record.url = url.to_string();
        }
        if let Some(title) = title {
            record.title = Some(title.to_string());
        }
        if let Some(favicon_url) = favicon_url {
            record.favicon_url = favicon_url.map(str::to_string);
        }
        record.validate()?;
        if record == before {
            tx.commit()?;
            return Ok((record, false));
        }
        tx.execute(
            "UPDATE frontend_browser_tabs SET url = ?2, title = ?3, favicon_url = ?4
             WHERE browser_id = ?1",
            params![browser_id, record.url, record.title, record.favicon_url],
        )?;
        append_presentation_record(
            &tx,
            "browser.frontend.updated",
            vec![browser_subject(browser_id)],
            &json!({"browser_id": browser_id, "browser": record}),
        )?;
        tx.commit()?;
        Ok((record, true))
    }

    /// Forget a frontend browser whose tab creation failed.
    pub fn delete_frontend_browser(&mut self, browser_id: &str) -> anyhow::Result<()> {
        self.connection
            .execute("DELETE FROM frontend_browser_tabs WHERE browser_id = ?1", [browser_id])?;
        Ok(())
    }

    /// Notification ids acknowledged as read on the shared console. A
    /// restart restores an unread marker only for unacknowledged ones.
    pub(crate) fn acked_notification_ids(&self) -> anyhow::Result<HashSet<String>> {
        let mut statement =
            self.connection.prepare("SELECT notification_id FROM notification_acks")?;
        let ids = statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?;
        Ok(ids)
    }

    /// Durably acknowledge notifications, then drop acknowledgements of
    /// notifications no longer retained by committed receipts. Returns how
    /// many ids were newly acknowledged.
    pub fn ack_notifications_durable(
        &mut self,
        notification_ids: &[String],
        acked_at_ms: u64,
        subjects: Vec<JournalSubject>,
    ) -> anyhow::Result<usize> {
        if notification_ids.is_empty() {
            return Ok(0);
        }
        let tx = self.connection.transaction()?;
        let mut added = 0;
        for id in notification_ids {
            anyhow::ensure!(
                id.starts_with("notification_") && id.len() <= 64,
                "bad request: invalid notification id {id}"
            );
            added += tx.execute(
                "INSERT OR IGNORE INTO notification_acks(notification_id, acked_at_ms)
                 VALUES(?1, ?2)",
                params![id, i64::try_from(acked_at_ms)?],
            )?;
        }
        tx.execute(
            "DELETE FROM notification_acks WHERE notification_id NOT IN (
               SELECT json_extract(outcome_json, '$.value.id')
               FROM resource_effect_receipts
               WHERE operation = 'notification.create' AND state = 'committed'
                 AND json_extract(outcome_json, '$.value.id') IS NOT NULL
             )",
            [],
        )?;
        if added > 0 {
            append_presentation_record(
                &tx,
                "notification.acknowledged",
                subjects,
                &json!({"notification_ids": notification_ids, "acked_at_ms": acked_at_ms}),
            )?;
        }
        tx.commit()?;
        Ok(added)
    }
}
