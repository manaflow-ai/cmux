//! Remote-terminal tab references (`remote-terminal-tabs-v1`,
//! plans/cmux-next/data-model.md 1.2): a tab in this session's layout that
//! names a terminal on another session. The home workspace store owns the
//! reference; the remote session host owns the terminal. The stored screen
//! snapshot is a per-client view cache of what the showing app last saw,
//! never terminal output (plans/cmux-next/OWNERSHIP-PRINCIPLES.md).

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::json;

use super::presentation_store::{
    append_presentation_record, browser_subject, validate_browser_public_id,
    validate_frontend_browser_title,
};
use super::{FrontendBrowserRecord, WorkspaceRegistry};

pub(super) fn create_remote_terminal_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
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

/// Every frontend browser record whose browser is not tombstoned, keyed by
/// its content id.
pub(super) fn read_frontend_browsers(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, FrontendBrowserRecord>> {
    let mut frontend_browsers = HashMap::new();
    let mut statement = connection.prepare(
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
    Ok(frontend_browsers)
}

/// Every remote-terminal record whose placeholder browser is not
/// tombstoned, keyed by that browser's content id.
pub(super) fn read_remote_terminals(
    connection: &Connection,
) -> anyhow::Result<HashMap<String, RemoteTerminalRecord>> {
    let mut remote_terminals = HashMap::new();
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
    for row in rows {
        let (browser_id, record) = row?;
        remote_terminals.insert(browser_id, record);
    }
    Ok(remote_terminals)
}

/// Longest accepted remote-terminal session name, in bytes.
pub const MAX_REMOTE_TERMINAL_SESSION_NAME_BYTES: usize = 255;
/// Largest accepted remote-terminal text snapshot, in UTF-8 bytes.
pub const MAX_REMOTE_TERMINAL_SNAPSHOT_BYTES: usize = 64 * 1024;

/// A tab in this session's layout that references a terminal on another
/// session (`remote-terminal-tabs-v1`, plans/cmux-next/data-model.md 1.2).
/// The frontend attaches to that session itself; this daemon only stores
/// the reference, like a frontend browser record, and never attaches,
/// spawns or bootstraps anything for it.
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
        validate_remote_session_id(&self.session_id)?;
        anyhow::ensure!(
            self.terminal_id.len() == 32
                && self.terminal_id.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f')),
            "bad request: terminal_id must be 32 lowercase hex digits"
        );
        validate_remote_session_name(&self.session_name)?;
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
}

fn validate_remote_session_id(value: &str) -> anyhow::Result<()> {
    let bytes = value.as_bytes();
    let well_formed = bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => matches!(byte, b'0'..=b'9' | b'a'..=b'f'),
        });
    anyhow::ensure!(well_formed, "bad request: session_id must be a lowercase UUID");
    Ok(())
}

pub fn validate_remote_session_name(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(!value.is_empty(), "bad request: session_name cannot be empty");
    anyhow::ensure!(
        value.len() <= MAX_REMOTE_TERMINAL_SESSION_NAME_BYTES,
        "bad request: session_name exceeds {MAX_REMOTE_TERMINAL_SESSION_NAME_BYTES} bytes"
    );
    anyhow::ensure!(
        !value.chars().any(char::is_control),
        "bad request: session_name contains a control character"
    );
    Ok(())
}

pub fn validate_remote_terminal_snapshot(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        value.len() <= MAX_REMOTE_TERMINAL_SNAPSHOT_BYTES,
        "bad request: snapshot exceeds {MAX_REMOTE_TERMINAL_SNAPSHOT_BYTES} bytes"
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
    pub snapshot: bool,
}

impl WorkspaceRegistry {
    /// Register a remote-terminal reference before its placeholder tab
    /// commits, under the content id the creation then uses. The id must be
    /// fresh.
    pub fn put_remote_terminal(
        &mut self,
        browser_id: &str,
        record: &RemoteTerminalRecord,
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
        append_presentation_record(
            &tx,
            "remote_terminal.registered",
            vec![browser_subject(browser_id)],
            &json!({"browser_id": browser_id, "remote_terminal": record}),
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Apply `update` to a remote-terminal record. The snapshot is stored
    /// but never journaled (it is screen text).
    pub fn update_remote_terminal(
        &mut self,
        browser_id: &str,
        update: &RemoteTerminalUpdate,
    ) -> anyhow::Result<(RemoteTerminalRecord, RemoteTerminalChange)> {
        validate_browser_public_id(browser_id)?;
        if let Some(Some(snapshot)) = &update.snapshot {
            validate_remote_terminal_snapshot(snapshot)?;
        }
        let tx = self.connection.transaction()?;
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
            snapshot: snapshot != snapshot_before,
        };
        if change.presentation {
            tx.execute(
                "UPDATE remote_terminal_tabs SET session_name = ?2, title = ?3 WHERE browser_id = ?1",
                params![browser_id, record.session_name, record.title],
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

    /// The stored text snapshot of a remote-terminal tab.
    pub fn remote_terminal_snapshot(&self, browser_id: &str) -> anyhow::Result<Option<String>> {
        validate_browser_public_id(browser_id)?;
        self.connection
            .query_row(
                "SELECT snapshot FROM remote_terminal_tabs WHERE browser_id = ?1",
                [browser_id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .ok_or_else(|| anyhow::anyhow!("browser {browser_id} is not a remote-terminal tab"))
    }

    /// Forget a remote-terminal reference whose tab creation failed or
    /// whose tab closed.
    pub fn delete_remote_terminal(&mut self, browser_id: &str) -> anyhow::Result<()> {
        self.connection
            .execute("DELETE FROM remote_terminal_tabs WHERE browser_id = ?1", [browser_id])?;
        Ok(())
    }
}
