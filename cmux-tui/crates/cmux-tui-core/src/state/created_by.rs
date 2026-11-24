//! `workspace.create {created_by}` (ask-48544d7525): who made a workspace,
//! the person, an agent session or a script, and the workspace it ran in.
//! A place hint, never a trust claim: an agent or script workspace goes
//! below its creator, after the creator's earlier children, in its group,
//! so it never lands next to the person's selection. Stored by workspace
//! key, so it survives a restart, and shown as `extra.created_by` on the
//! workspace (the sidebar's creator tree reads it).
//!
//! `created-by-detail-v1` (Leo, 2026-11-19: "acpmux should expose these a lot better"): an agent's
//! create also names its acpmux session (`session_name`), the `host` it runs on and a one-line
//! `purpose`, and `room.create` and `tab.create_*` take the same `created_by`. A space or tab
//! keeps it in `resource_created_by` and shows it as `created_by` (a space) or
//! `extra.created_by` (a tab). Shown to say who made a thing and why, never a trust claim.

use std::cell::RefCell;
use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Map, Value, json};

/// The longest creator chain walked; a longer one (or a cycle) stops there.
const MAX_CHAIN: usize = 16;

thread_local! {
    static SCOPED: RefCell<Option<CreatedBy>> = const { RefCell::new(None) };
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CreatorKind {
    Person,
    Agent,
    Script,
}

impl CreatorKind {
    fn from_wire(value: &str) -> Option<Self> {
        match value {
            "person" => Some(Self::Person),
            "agent" => Some(Self::Agent),
            "script" => Some(Self::Script),
            _ => None,
        }
    }

    fn wire(self) -> &'static str {
        match self {
            Self::Person => "person",
            Self::Agent => "agent",
            Self::Script => "script",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CreatedBy {
    pub(crate) kind: CreatorKind,
    /// The creator workspace as the request named it: a public id or a key.
    pub(crate) workspace: Option<String>,
    pub(crate) session: Option<String>,
    /// The agent session's name (`ACPMUX_SESSION_NAME`), its host and what it made this for.
    pub(crate) session_name: Option<String>,
    pub(crate) host: Option<String>,
    pub(crate) purpose: Option<String>,
}

impl CreatedBy {
    /// The request's `created_by` object (its shape is checked by the
    /// catalog); None when absent or not an object.
    pub(crate) fn from_fields(fields: &Map<String, Value>) -> Option<Self> {
        Self::from_value(fields.get("created_by")?)
    }

    /// A `created_by` object; None when it is not one or names no known kind.
    pub(crate) fn from_value(value: &Value) -> Option<Self> {
        let value = value.as_object()?;
        let text = |name: &str| value.get(name).and_then(Value::as_str).map(str::to_string);
        Some(Self {
            kind: CreatorKind::from_wire(value.get("kind")?.as_str()?)?,
            workspace: text("workspace"),
            session: text("session"),
            session_name: text("session_name"),
            host: text("host"),
            purpose: text("purpose"),
        })
    }

    /// Run `body` with this creator for the workspaces it creates.
    pub(crate) fn scoped<T>(self, body: impl FnOnce() -> T) -> T {
        let previous = SCOPED.with(|cell| cell.replace(Some(self)));
        let _restore = Restore(previous);
        body()
    }

    /// The creator of the create running on this thread.
    pub(crate) fn current() -> Option<Self> {
        SCOPED.with(|cell| cell.borrow().clone())
    }

    /// An agent or script create: placed by its creator, not the selection.
    pub(crate) fn places_by_creator(&self) -> bool {
        self.kind != CreatorKind::Person
    }
}

/// Runs `body` with the creator of `fields`, if it names one.
pub(crate) fn scoped_by_fields<T>(fields: &Map<String, Value>, body: impl FnOnce() -> T) -> T {
    match CreatedBy::from_fields(fields) {
        Some(created_by) => created_by.scoped(body),
        None => body(),
    }
}

struct Restore(Option<CreatedBy>);

impl Drop for Restore {
    fn drop(&mut self) {
        let previous = self.0.take();
        SCOPED.with(|cell| *cell.borrow_mut() = previous);
    }
}

/// The detail columns `created-by-detail-v1` adds to `workspace_created_by`.
const DETAIL_COLUMNS: [&str; 3] = ["session_name", "host", "purpose"];

pub(crate) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_created_by (
           workspace_key TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           creator_key TEXT,
           session TEXT
         );
         CREATE TABLE IF NOT EXISTS resource_created_by (
           resource TEXT NOT NULL,
           id TEXT NOT NULL,
           kind TEXT NOT NULL,
           session TEXT,
           session_name TEXT,
           host TEXT,
           purpose TEXT,
           PRIMARY KEY(resource, id)
         );",
    )?;
    // Additive: a table an older build made has no detail columns. Older builds name their
    // columns, so they keep reading and writing it.
    let columns = transaction
        .prepare("PRAGMA table_info(workspace_created_by)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    for column in DETAIL_COLUMNS {
        if !columns.iter().any(|name| name == column) {
            transaction.execute_batch(&format!(
                "ALTER TABLE workspace_created_by ADD COLUMN {column} TEXT;"
            ))?;
        }
    }
    prune_gone_tabs(transaction)
}

/// The key of the live workspace `named`: a public id, or a key as stored
/// or in the UUID form a terminal's `CMUX_WORKSPACE_ID` holds.
pub(crate) fn live_workspace_key(
    connection: &Connection,
    named: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT workspace_key FROM resource_workspaces
             WHERE (public_id = ?1 OR workspace_key = ?1 OR workspace_key = ?2)
               AND deleted_revision IS NULL",
            [named, uuid_form(named).as_str()],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// A key in the stored form: lowercase, dashed 8-4-4-4-12.
fn uuid_form(named: &str) -> String {
    let hex =
        named.chars().filter(|ch| *ch != '-').flat_map(char::to_lowercase).collect::<String>();
    if hex.len() != 32 || !hex.is_ascii() {
        return named.to_lowercase();
    }
    let at = |from: usize, to: usize| hex.get(from..to).unwrap_or_default();
    [at(0, 8), at(8, 12), at(12, 16), at(16, 20), at(20, 32)].join("-")
}

/// Store `created_by` for the new workspaces `keys`, with its creator
/// workspace resolved to a live key (None when it names none).
pub(crate) fn record(
    transaction: &Transaction<'_>,
    keys: &[String],
    created_by: &CreatedBy,
    creator_key: Option<&str>,
) -> anyhow::Result<()> {
    for key in keys {
        transaction.execute(
            "INSERT INTO workspace_created_by(workspace_key, kind, creator_key, session,
               session_name, host, purpose)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(workspace_key) DO UPDATE SET kind = excluded.kind,
               creator_key = excluded.creator_key, session = excluded.session,
               session_name = excluded.session_name, host = excluded.host,
               purpose = excluded.purpose",
            params![
                key,
                created_by.kind.wire(),
                creator_key,
                created_by.session,
                created_by.session_name,
                created_by.host,
                created_by.purpose
            ],
        )?;
    }
    Ok(())
}

/// A space (`room`) or a tab that a `created_by` made: stored by its public id.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Made {
    Room,
    Tab,
}

impl Made {
    fn wire(self) -> &'static str {
        match self {
            Self::Room => "room",
            Self::Tab => "tab",
        }
    }
}

/// Store `created_by` for the new space or tab `id`.
pub(crate) fn record_made(
    connection: &Connection,
    made: Made,
    id: &str,
    created_by: &CreatedBy,
) -> anyhow::Result<()> {
    connection.execute(
        "INSERT INTO resource_created_by(resource, id, kind, session, session_name, host, purpose)
         VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(resource, id) DO UPDATE SET kind = excluded.kind,
           session = excluded.session, session_name = excluded.session_name,
           host = excluded.host, purpose = excluded.purpose",
        params![
            made.wire(),
            id,
            created_by.kind.wire(),
            created_by.session,
            created_by.session_name,
            created_by.host,
            created_by.purpose
        ],
    )?;
    Ok(())
}

/// The columns [`made_value`] reads.
const MADE_COLUMNS: &str = "kind, session, session_name, host, purpose";

/// The shown `created_by` of a row whose [`MADE_COLUMNS`] start at column `first`.
fn made_value(row: &rusqlite::Row<'_>, first: usize) -> rusqlite::Result<Value> {
    let text = |at: usize| row.get::<_, Option<String>>(first + at);
    Ok(snapshot_value(
        row.get::<_, String>(first)?,
        None,
        text(1)?,
        Detail { session_name: text(2)?, host: text(3)?, purpose: text(4)? },
    ))
}

/// The `created_by` of the space or tab `id`; None when nothing recorded one.
pub(crate) fn made_by(
    connection: &Connection,
    made: Made,
    id: &str,
) -> anyhow::Result<Option<Value>> {
    Ok(super::values::query_row_cached(
        connection,
        &format!("SELECT {MADE_COLUMNS} FROM resource_created_by WHERE resource = ?1 AND id = ?2"),
        [made.wire(), id],
        |row| made_value(row, 0),
    )
    .optional()?)
}

/// The recorded `created_by` of every live tab, by id: one statement for a whole list, whatever
/// the number of tabs; a closed tab's row is not read.
pub(crate) fn live_tabs_made_by(connection: &Connection) -> anyhow::Result<HashMap<String, Value>> {
    let mut statement = connection.prepare_cached(
        "SELECT c.id, c.kind, c.session, c.session_name, c.host, c.purpose
         FROM resource_created_by AS c
         JOIN resource_tabs AS t ON t.public_id = c.id
         WHERE c.resource = 'tab' AND t.deleted_revision IS NULL",
    )?;
    let rows =
        statement.query_map([], |row| Ok((row.get::<_, String>(0)?, made_value(row, 1)?)))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Forget the tabs that no longer exist at all (not even as a closed tab that may reopen), so
/// the table does not grow with every tab an agent ever made. Runs at the state schema's start.
fn prune_gone_tabs(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let has_tabs = transaction
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'resource_tabs'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if has_tabs {
        transaction.execute(
            "DELETE FROM resource_created_by WHERE resource = 'tab'
               AND id NOT IN (SELECT public_id FROM resource_tabs)",
            [],
        )?;
    }
    Ok(())
}

/// Forget what made the space or tab `id`, once it is deleted.
pub(crate) fn forget_made(connection: &Connection, made: Made, id: &str) -> anyhow::Result<()> {
    connection.execute(
        "DELETE FROM resource_created_by WHERE resource = ?1 AND id = ?2",
        [made.wire(), id],
    )?;
    Ok(())
}

fn creator_key_of(connection: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT creator_key FROM workspace_created_by WHERE workspace_key = ?1",
            [key],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten())
}

/// Whether `ancestor` made `key`, directly or through its children.
pub(crate) fn descends_from(
    connection: &Connection,
    key: &str,
    ancestor: &str,
) -> anyhow::Result<bool> {
    let mut current = key.to_string();
    for _ in 0..MAX_CHAIN {
        match creator_key_of(connection, &current)? {
            Some(creator) if creator == ancestor => return Ok(true),
            Some(creator) => current = creator,
            None => return Ok(false),
        }
    }
    Ok(false)
}

/// The `created-by-detail-v1` fields of a stored row.
#[derive(Default)]
pub(crate) struct Detail {
    pub(crate) session_name: Option<String>,
    pub(crate) host: Option<String>,
    pub(crate) purpose: Option<String>,
}

/// `extra.created_by` of a workspace: its kind, its creator's public id while that workspace
/// lives (`creator`), its agent session, and that session's name, host and purpose.
/// `state/workspace_extras.rs` reads the rows.
pub(crate) fn snapshot_value(
    kind: String,
    creator: Option<String>,
    session: Option<String>,
    detail: Detail,
) -> Value {
    let mut value = Map::new();
    value.insert("kind".into(), json!(kind));
    let fields = [
        ("workspace", creator),
        ("session", session),
        ("session_name", detail.session_name),
        ("host", detail.host),
        ("purpose", detail.purpose),
    ];
    for (name, field) in fields {
        if let Some(field) = field {
            value.insert(name.into(), json!(field));
        }
    }
    Value::Object(value)
}
