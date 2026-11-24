//! The update hold: which terminals an app update holds, and until when.
//!
//! An app update quits the app, so every attach stream the app held ends.
//! A terminal with no tab placement and no `keep` mark that only such a
//! stream held is then the reaper's to end (`terminal-reap-v1`): at once
//! past its cap, the rest one grace later. A daemon that is already running
//! cannot be changed by the update, so the hold uses only what every daemon
//! with `terminal-reap-v1` has: the durable `keep` mark.
//!
//! Before the app quits, the incoming build's `server hold-terminals` reads
//! this registry beside the running owner (read-only, as
//! `premigrate-registry` does), finds the terminals with no placement and no
//! `keep` mark, writes their ids to the hold file beside the registry, and
//! marks each `keep` over the owner's socket. The mark is a registry row, so
//! it holds in the old owner after the quit, across the handoff, and in the
//! next owner. The next owner lifts the mark of each held terminal once a
//! client streams it or a tab shows it again, and of the rest when the hold
//! expires (`mux/update_hold.rs`).
//!
//! The file lists only terminals that had no `keep` mark, so lifting the
//! hold never unmarks a terminal that was kept on purpose. It is written
//! before the first mark is set: a hold that stops halfway leaves no mark
//! that the file does not name.

use std::path::{Path, PathBuf};

use anyhow::Context as _;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use super::{
    WORKSPACE_REGISTRY_FILE, WorkspaceRegistry, open_registry_database_read_only,
    persistent_session_state_dir,
};
use crate::platform;

/// The hold file's name, beside the session's registry.
pub const UPDATE_HOLD_FILE: &str = "update-terminal-hold.json";

/// The terminals one update holds.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateHold {
    /// Wall-clock time of the newest hold, in Unix milliseconds.
    pub held_ms: u64,
    /// Host ids of the held terminals: each had no placement and no `keep`
    /// mark when it was held.
    pub terminals: Vec<String>,
}

impl UpdateHold {
    /// The hold file of the session `session_name` under `state_root`.
    pub fn path(state_root: &Path, session_name: &str) -> PathBuf {
        platform::normalize_filesystem_path(
            persistent_session_state_dir(state_root, session_name).join(UPDATE_HOLD_FILE),
        )
    }

    /// The hold in `path`, or none when no update holds a terminal.
    pub fn read(path: &Path) -> anyhow::Result<Option<Self>> {
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error).with_context(|| format!("read update hold {}", path.display()));
            }
        };
        let hold: Self = serde_json::from_slice(&bytes)
            .with_context(|| format!("parse update hold {}", path.display()))?;
        Ok(Some(hold))
    }

    /// Replace the hold in `path` (written beside it, then renamed), or
    /// remove the file when no terminal is held.
    pub fn write(&self, path: &Path) -> anyhow::Result<()> {
        if self.terminals.is_empty() {
            return match std::fs::remove_file(path) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => {
                    Err(error).with_context(|| format!("remove update hold {}", path.display()))
                }
            };
        }
        let mut staged = path.as_os_str().to_owned();
        staged.push(".new");
        let staged = PathBuf::from(staged);
        std::fs::write(&staged, serde_json::to_vec(self)?)
            .with_context(|| format!("write update hold {}", staged.display()))?;
        let _ = platform::restrict_file(&staged);
        std::fs::rename(&staged, path)
            .with_context(|| format!("replace update hold {}", path.display()))?;
        Ok(())
    }

    /// Add `terminals` to the hold in `path` and restart its clock at
    /// `now_ms`. Terminals an earlier hold still names stay held.
    pub fn extend(path: &Path, terminals: &[String], now_ms: u64) -> anyhow::Result<Self> {
        let mut hold = Self::read(path).ok().flatten().unwrap_or_default();
        hold.held_ms = now_ms;
        for terminal_id in terminals {
            if !hold.terminals.contains(terminal_id) {
                hold.terminals.push(terminal_id.clone());
            }
        }
        hold.write(path)?;
        Ok(hold)
    }
}

/// Host ids of the live terminals with no live tab placement and no `keep`
/// mark, oldest id first: what a quit of the app leaves to the reaper.
fn unplaced_unkept_terminals(connection: &Connection) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT host.terminal_id FROM terminal_hosts AS host
         WHERE host.lifecycle != 'tombstoned'
           AND NOT EXISTS (
             SELECT 1 FROM terminal_keep AS kept WHERE kept.terminal_id = host.terminal_id
           )
           AND NOT EXISTS (
             SELECT 1 FROM resource_terminals AS terminal
             JOIN resource_tabs AS tab ON tab.content_id = terminal.public_id
             JOIN resource_panes AS pane ON pane.public_id = tab.pane_id
             WHERE terminal.terminal_id = host.terminal_id
               AND terminal.deleted_revision IS NULL
               AND tab.deleted_revision IS NULL
               AND pane.deleted_revision IS NULL
           )
         ORDER BY host.terminal_id",
    )?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    let mut terminals = Vec::new();
    for row in rows {
        terminals.push(row?);
    }
    Ok(terminals)
}

/// The terminals an update must hold in the session `session_name` under
/// `state_root`, read beside its running owner: read-only, no session lock.
/// Empty when the session has no saved registry.
pub fn update_hold_candidates(
    state_root: &Path,
    session_name: &str,
) -> anyhow::Result<Vec<String>> {
    let root = platform::normalize_filesystem_path(state_root.to_path_buf());
    let db_path = platform::normalize_filesystem_path(
        persistent_session_state_dir(&root, session_name).join(WORKSPACE_REGISTRY_FILE),
    );
    if !db_path.is_file() {
        return Ok(Vec::new());
    }
    let connection = open_registry_database_read_only(&db_path)
        .with_context(|| format!("open workspace registry {}", db_path.display()))?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    connection.execute_batch("PRAGMA query_only=1;")?;
    unplaced_unkept_terminals(&connection)
}

impl WorkspaceRegistry {
    /// [`update_hold_candidates`] on this owner's own connection.
    pub(crate) fn update_hold_candidates(&self) -> anyhow::Result<Vec<String>> {
        unplaced_unkept_terminals(&self.connection.get())
    }
}
