//! A move `place_set` owes a chat, kept on disk from the pick until the move ends
//! (`ACPMUX_HOME/place-moves/<chat>.json`), so a daemon that dies meanwhile (power off, the app
//! killed) finds it on its next start and ends it (`place_set::resume`): a move that was waiting
//! for the turn goes on, one cut mid-start or mid-move says why in the chat, and its fresh Cloud
//! machine is paused. In memory alone it was lost: no line, the machine left running.
//!
//! Kept in this machine's home, not in the chat's metadata where its pin lives: the metadata
//! travels with the chat, and a copy that arrived on the target must never start a move there.

use crate::place_mode::PlaceMode;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const DIR: &str = "place-moves";

/// Where the move stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Stage {
    /// Its fresh Cloud machine is starting; its id is not known yet.
    Starting,
    /// Waiting for the chat's turn to end (its Cloud machine, if any, is up).
    Waiting,
    /// The move line is written and the move runs.
    Moving,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Pending {
    pub session_id: String,
    /// Where it goes: `Cloud` (a fresh Cloud machine) or a machine.
    pub to: PlaceMode,
    /// The fresh Cloud machine, once it is up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    /// The chat's pin before the pick (None: it had none): a failed move puts it back.
    #[serde(default)]
    pub before: Option<PlaceMode>,
    /// The chat's mode before the pick, as it read: the move line's `undo.mode`, so an Undo puts
    /// it back exactly.
    pub was: PlaceMode,
    /// The pin stored as the move starts, so it travels with the chat: the pick, or for an Undo
    /// the mode the chat had before the move it undoes.
    pub pin: PlaceMode,
    pub why: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Ties the move line and its failure line together (`moveId` on both).
    pub move_id: String,
    pub stage: Stage,
}

fn dir() -> PathBuf {
    crate::config::home().join(DIR)
}

fn path(id: &str) -> Option<PathBuf> {
    let plain = !id.is_empty()
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        && !id.starts_with('.');
    plain.then(|| dir().join(format!("{id}.json")))
}

/// Saves `p`, synced, before the step it names runs.
pub(super) fn save(p: &Pending) -> Result<(), String> {
    let path = path(&p.session_id).ok_or("the chat's id is not a plain name")?;
    let bytes = serde_json::to_vec(p).map_err(|e| e.to_string())?;
    crate::home_fs::create_dir_all(dir(), 0o700).map_err(|e| e.to_string())?;
    crate::home_fs::write_durable(&path, bytes).map_err(|e| e.to_string())
}

/// Whether the chat has a move a previous daemon left (not yet taken up again).
pub(super) fn exists(id: &str) -> bool {
    path(id).is_some_and(|p| std::fs::metadata(p).is_ok())
}

/// Drops the chat's record once its move ended (moved, or its failure line written).
pub(super) fn clear(id: &str) {
    let Some(path) = path(id) else { return };
    match crate::home_fs::remove_file(&path) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            tracing::warn!(session = %id, error = %e, "place_set: a finished move's record stayed");
        }
        _ => {}
    }
}

/// Every move a previous daemon left unfinished.
pub(super) fn all() -> Vec<Pending> {
    let Ok(names) = crate::home_fs::read_dir_names(dir(), 100_000) else { return Vec::new() };
    let mut out = Vec::new();
    for name in names {
        let name = name.to_string_lossy();
        let Some(id) = name.strip_suffix(".json") else { continue };
        let Some(path) = path(id) else { continue };
        match std::fs::read(&path)
            .map_err(|e| e.to_string())
            .and_then(|b| serde_json::from_slice::<Pending>(&b).map_err(|e| e.to_string()))
        {
            Ok(p) if p.session_id == id => out.push(p),
            Ok(_) => tracing::warn!(file = %name, "place_set: a move record names another chat"),
            Err(e) => tracing::warn!(file = %name, error = %e, "place_set: a move record unread"),
        }
    }
    out
}

#[cfg(test)]
#[path = "place_pending_tests.rs"]
mod tests;
