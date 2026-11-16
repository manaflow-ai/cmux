//! `workspace.create {created_by}` (ask-48544d7525): who made a workspace,
//! the person, an agent session or a script, and the workspace it ran in.
//! A place hint, never a trust claim: an agent or script workspace goes
//! below its creator, after the creator's earlier children, in its group,
//! so it never lands next to the person's selection. Stored by workspace
//! key, so it survives a restart, and shown as `extra.created_by` on the
//! workspace (the sidebar's creator tree reads it).

use std::cell::RefCell;

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
}

impl CreatedBy {
    /// The request's `created_by` object (its shape is checked by the
    /// catalog); None when absent or not an object.
    pub(crate) fn from_fields(fields: &Map<String, Value>) -> Option<Self> {
        let value = fields.get("created_by")?.as_object()?;
        let text = |name: &str| value.get(name).and_then(Value::as_str).map(str::to_string);
        Some(Self {
            kind: CreatorKind::from_wire(value.get("kind")?.as_str()?)?,
            workspace: text("workspace"),
            session: text("session"),
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

pub(crate) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_created_by (
           workspace_key TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           creator_key TEXT,
           session TEXT
         );",
    )?;
    Ok(())
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
            "INSERT INTO workspace_created_by(workspace_key, kind, creator_key, session)
             VALUES(?1, ?2, ?3, ?4)
             ON CONFLICT(workspace_key) DO UPDATE SET kind = excluded.kind,
               creator_key = excluded.creator_key, session = excluded.session",
            params![key, created_by.kind.wire(), creator_key, created_by.session],
        )?;
    }
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

/// `extra.created_by` of a workspace: its kind, its creator's public id while that workspace
/// lives (`creator`), and its agent session. `state/workspace_extras.rs` reads the rows.
pub(crate) fn snapshot_value(
    kind: String,
    creator: Option<String>,
    session: Option<String>,
) -> Value {
    let mut value = Map::new();
    value.insert("kind".into(), json!(kind));
    if let Some(creator) = creator {
        value.insert("workspace".into(), json!(creator));
    }
    if let Some(session) = session {
        value.insert("session".into(), json!(session));
    }
    Value::Object(value)
}
