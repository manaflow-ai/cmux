//! `remote-terminal-tabs-v1`: the store record of a remote-terminal tab
//! (plans/cmux-next/data-model.md 1.2b): a tab in this session's layout that
//! references a terminal on another session. The home workspace store owns
//! the reference; the other session's host owns the terminal, and this
//! daemon never attaches, spawns or bootstraps anything for it.
//!
//! Like a conversation tab (state/conversation_tabs_store.rs) it reuses the
//! frontend-rendered tab plumbing: a browser surface with no CDP target and a
//! `frontend_browser_tabs` row (engine `webkit`, URL `about:blank`, title =
//! the tab's display title, so a restart restores it). The row here names the
//! session and terminal and is written in the same commit as that frontend
//! row. The stored text snapshot is a view cache of what the showing app last
//! saw; it is never journaled and never part of the tree.

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::json;

use crate::workspace_registry::presentation_store::{
    append_presentation_record, validate_frontend_browser_title,
};
use crate::workspace_registry::{JournalSubject, WorkspaceRegistry};

pub(crate) const REMOTE_TERMINAL_TABS_CAPABILITY: &str = "remote-terminal-tabs-v1";
/// The raw tab `kind` of a remote-terminal tab.
pub(crate) const REMOTE_TERMINAL_KIND: &str = "remote-terminal";
/// The frontend record of a remote-terminal tab: no page is loaded.
pub(crate) const REMOTE_TERMINAL_TAB_URL: &str = "about:blank";
pub(crate) const REMOTE_TERMINAL_TAB_ENGINE: &str = "webkit";
/// Longest accepted session name, in bytes.
pub(crate) const MAX_SESSION_NAME_BYTES: usize = 255;
/// Largest accepted text snapshot, in UTF-8 bytes.
pub(crate) const MAX_SNAPSHOT_BYTES: usize = 64 * 1024;

pub(crate) fn create_remote_terminal_tabs_schema(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS remote_terminal_tabs (
           browser_id TEXT PRIMARY KEY NOT NULL,
           session_id TEXT NOT NULL,
           terminal_id TEXT NOT NULL,
           session_name TEXT NOT NULL,
           title TEXT,
           snapshot TEXT
         );",
    )?;
    Ok(())
}

/// The reference a remote-terminal tab holds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RemoteTerminalRecord {
    /// The other session's durable id: a lowercase UUID.
    pub session_id: String,
    /// The terminal's host id on that session: 32 lowercase hex digits.
    pub terminal_id: String,
    /// The name the frontend shows for that session.
    pub session_name: String,
    pub title: Option<String>,
}

impl RemoteTerminalRecord {
    pub fn validate(&self) -> anyhow::Result<()> {
        validate_session_id(&self.session_id)?;
        anyhow::ensure!(
            self.terminal_id.len() == 32
                && self.terminal_id.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f')),
            "bad request: terminal_id must be 32 lowercase hex digits"
        );
        validate_session_name(&self.session_name)?;
        if let Some(title) = &self.title {
            validate_frontend_browser_title(title)?;
        }
        Ok(())
    }

    /// The tab title: the recorded one, else "Terminal on <session>".
    pub fn display_title(&self) -> String {
        match &self.title {
            Some(title) if !title.is_empty() => title.clone(),
            _ => format!("Terminal on {}", self.session_name),
        }
    }

    /// The tab's `remote` object on the wire.
    pub(crate) fn wire(&self) -> serde_json::Value {
        json!({
            "session_id": self.session_id,
            "terminal_id": self.terminal_id,
            "session_name": self.session_name,
        })
    }
}

fn validate_session_id(value: &str) -> anyhow::Result<()> {
    let bytes = value.as_bytes();
    let well_formed = bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => matches!(byte, b'0'..=b'9' | b'a'..=b'f'),
        });
    anyhow::ensure!(well_formed, "bad request: session_id must be a lowercase UUID");
    Ok(())
}

fn validate_session_name(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(!value.is_empty(), "bad request: session_name cannot be empty");
    anyhow::ensure!(
        value.len() <= MAX_SESSION_NAME_BYTES,
        "bad request: session_name exceeds {MAX_SESSION_NAME_BYTES} bytes"
    );
    anyhow::ensure!(
        !value.chars().any(char::is_control),
        "bad request: session_name contains a control character"
    );
    Ok(())
}

/// Changes to a remote-terminal record: `None` leaves a field unchanged;
/// `Some(None)` clears the title or the snapshot.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RemoteTerminalUpdate {
    pub title: Option<Option<String>>,
    pub session_name: Option<String>,
    pub snapshot: Option<Option<String>>,
}

/// What an update changed: the presented record (title or session name)
/// and, separately, the snapshot.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RemoteTerminalChange {
    pub presentation: bool,
    /// The tab's display title changed (a session name change under an
    /// explicit title does not change it).
    pub title: bool,
    pub snapshot: bool,
}

/// Write the reference in the transaction that registers its frontend row.
pub(crate) fn write_remote_terminal(
    transaction: &Transaction<'_>,
    browser_id: &str,
    record: &RemoteTerminalRecord,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO remote_terminal_tabs(browser_id, session_id, terminal_id, session_name, title)
         VALUES(?1, ?2, ?3, ?4, ?5)",
        params![
            browser_id,
            record.session_id,
            record.terminal_id,
            record.session_name,
            record.title
        ],
    )?;
    Ok(())
}

/// Every remote-terminal record whose placeholder browser is not
/// tombstoned, keyed by that browser's content id.
pub(crate) fn read_remote_terminals(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, RemoteTerminalRecord>> {
    let mut statement = connection.prepare(
        "SELECT r.browser_id, r.session_id, r.terminal_id, r.session_name, r.title
         FROM remote_terminal_tabs AS r
         WHERE NOT EXISTS (
           SELECT 1 FROM resource_browsers AS b
           WHERE b.public_id = r.browser_id AND b.lifecycle = 'tombstoned'
         )",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            RemoteTerminalRecord {
                session_id: row.get(1)?,
                terminal_id: row.get(2)?,
                session_name: row.get(3)?,
                title: row.get(4)?,
            },
        ))
    })?;
    rows.collect::<Result<HashMap<_, _>, _>>().map_err(Into::into)
}

fn browser_subject(browser_id: &str) -> JournalSubject {
    JournalSubject { kind: "browser".into(), id: browser_id.to_string() }
}

/// Apply `update` to the record of `browser_id`. A title or session name
/// change also rewrites the frontend row's title (what a restart restores)
/// and appends one presentation record; the snapshot is stored silently.
pub(crate) fn update_remote_terminal(
    registry: &mut WorkspaceRegistry,
    browser_id: &str,
    update: &RemoteTerminalUpdate,
) -> anyhow::Result<(RemoteTerminalRecord, RemoteTerminalChange)> {
    if let Some(Some(snapshot)) = &update.snapshot {
        anyhow::ensure!(
            snapshot.len() <= MAX_SNAPSHOT_BYTES,
            "bad request: snapshot exceeds {MAX_SNAPSHOT_BYTES} bytes"
        );
    }
    let db = registry.connection.get();
    let tx = db.unchecked_transaction()?;
    let (before, snapshot_before) = tx
        .query_row(
            "SELECT session_id, terminal_id, session_name, title, snapshot
             FROM remote_terminal_tabs WHERE browser_id = ?1",
            [browser_id],
            |row| {
                Ok((
                    RemoteTerminalRecord {
                        session_id: row.get(0)?,
                        terminal_id: row.get(1)?,
                        session_name: row.get(2)?,
                        title: row.get(3)?,
                    },
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .optional()?
        .ok_or_else(|| anyhow::anyhow!("browser {browser_id} is not a remote-terminal tab"))?;
    let mut record = before.clone();
    if let Some(title) = &update.title {
        record.title = title.clone();
    }
    if let Some(session_name) = &update.session_name {
        record.session_name = session_name.clone();
    }
    record.validate()?;
    let snapshot = update.snapshot.clone().unwrap_or_else(|| snapshot_before.clone());
    let change = RemoteTerminalChange {
        presentation: record != before,
        title: record.display_title() != before.display_title(),
        snapshot: snapshot != snapshot_before,
    };
    if change.presentation {
        tx.execute(
            "UPDATE remote_terminal_tabs SET session_name = ?2, title = ?3 WHERE browser_id = ?1",
            params![browser_id, record.session_name, record.title],
        )?;
        tx.execute(
            "UPDATE frontend_browser_tabs SET title = ?2 WHERE browser_id = ?1",
            params![browser_id, record.display_title()],
        )?;
        append_presentation_record(
            &tx,
            "remote_terminal.updated",
            vec![browser_subject(browser_id)],
            &json!({"browser_id": browser_id, "remote_terminal": record}),
        )?;
    }
    if change.snapshot {
        tx.execute(
            "UPDATE remote_terminal_tabs SET snapshot = ?2 WHERE browser_id = ?1",
            params![browser_id, snapshot],
        )?;
    }
    tx.commit()?;
    Ok((record, change))
}

/// The stored text snapshot of the remote-terminal tab `browser_id`.
pub(crate) fn read_snapshot(
    connection: &Connection,
    browser_id: &str,
) -> anyhow::Result<Option<String>> {
    connection
        .query_row(
            "SELECT snapshot FROM remote_terminal_tabs WHERE browser_id = ?1",
            [browser_id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()?
        .ok_or_else(|| anyhow::anyhow!("browser {browser_id} is not a remote-terminal tab"))
}

/// The reference of the remote-terminal tab `tab_id` as a closed-history
/// record (`remote` plus `title`), so Reopen Closed Tab brings it back as a
/// remote-terminal tab; `None` when it is no remote-terminal tab.
pub(crate) fn tab_remote_wire(
    connection: &Connection,
    tab_id: &str,
) -> anyhow::Result<Option<serde_json::Value>> {
    let record = connection
        .query_row(
            "SELECT r.session_id, r.terminal_id, r.session_name, r.title
             FROM resource_tabs AS t
             JOIN remote_terminal_tabs AS r ON r.browser_id = t.content_id
             WHERE t.public_id = ?1",
            [tab_id],
            |row| {
                Ok(RemoteTerminalRecord {
                    session_id: row.get(0)?,
                    terminal_id: row.get(1)?,
                    session_name: row.get(2)?,
                    title: row.get(3)?,
                })
            },
        )
        .optional()?;
    Ok(record.map(|record| {
        let mut wire = record.wire();
        wire["title"] = json!(record.title);
        wire
    }))
}

impl RemoteTerminalRecord {
    /// The record [`tab_remote_wire`] stored for a closed tab.
    pub(crate) fn from_wire(value: &serde_json::Value) -> Option<Self> {
        Some(Self {
            session_id: value["session_id"].as_str()?.to_string(),
            terminal_id: value["terminal_id"].as_str()?.to_string(),
            session_name: value["session_name"].as_str()?.to_string(),
            title: value["title"].as_str().map(str::to_string),
        })
    }
}
