//! The session processes' records, `share-host/sessions/<session id>.json` (0600 in a 0700
//! folder): written by the session process when it starts serving and removed when it ends, so
//! a daemon that starts while one runs (a handoff, an upgrade) adopts it. A record names its
//! process by pid and start time: a pid alone may be another process by now, and a process is
//! only ever signalled when both match.

use cmux_hub_host::identity;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// One session process.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Record {
    pub pid: u32,
    /// When the process started, ms since the epoch (`process_identity::started_ms`).
    pub started_ms: u64,
    pub session_id: String,
    /// `view` or `full`.
    pub scope: String,
    pub viewer_id: String,
    pub viewer_name: String,
}

/// The records' folder.
pub(crate) fn dir(home: &Path) -> PathBuf {
    super::dir(home).join("sessions")
}

/// The record file of session `id`; None for an id that is not one path segment of a hub id.
fn path(dir: &Path, id: &str) -> Option<PathBuf> {
    let plain = !id.is_empty()
        && id.len() <= 100
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    plain.then(|| dir.join(format!("{id}.json")))
}

/// When `pid` started, or None once it is gone.
pub(crate) fn started_ms(pid: u32) -> Option<u64> {
    cmux_tui_platform::process_identity::started_ms(pid)
}

impl Record {
    /// The record of this process serving `ticket`.
    pub(crate) fn of_self(ticket: &cmux_hub_host::session::Ticket) -> Option<Self> {
        let pid = std::process::id();
        Some(Self {
            pid,
            started_ms: started_ms(pid)?,
            session_id: ticket.session_id.clone(),
            scope: ticket.scope.clone(),
            viewer_id: ticket.peer_id.clone(),
            viewer_name: ticket.peer_name.clone(),
        })
    }

    /// Whether its process still runs: the same pid, started at the same time.
    pub(crate) fn alive(&self) -> bool {
        started_ms(self.pid) == Some(self.started_ms)
    }

    /// Asks its process to stop (SIGTERM: it ends its share and tells the hub), only while it
    /// is the same process. Whether a signal was sent.
    pub(crate) fn stop(&self) -> bool {
        let Ok(pid) = libc::pid_t::try_from(self.pid) else { return false };
        if pid <= 1 || !self.alive() {
            return false;
        }
        // SAFETY: a signal to the process this record names, checked by its start time.
        unsafe { libc::kill(pid, libc::SIGTERM) == 0 }
    }
}

pub(crate) fn write(dir: &Path, record: &Record) -> cmux_hub_host::Res<()> {
    let path = path(dir, &record.session_id).ok_or("not a session id")?;
    identity::private_dir(dir)?;
    identity::write_private(&path, &serde_json::to_vec(record)?)
}

pub(crate) fn read(dir: &Path, id: &str) -> Option<Record> {
    let bytes = identity::read_private(&path(dir, id)?).ok()??;
    serde_json::from_slice(&bytes).ok()
}

/// Removes session `id`'s record while it is still `pid`'s (a newer process serving the same
/// session again keeps its own).
pub(crate) fn remove_if(dir: &Path, id: &str, pid: u32) {
    let Some(file) = path(dir, id) else { return };
    if read(dir, id).is_none_or(|record| record.pid == pid) {
        let _ = crate::home_fs::remove_file(file);
    }
}

/// The pid of every readable record, alive or not; nothing is removed.
pub(crate) fn pids(dir: &Path) -> Vec<u32> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            read(dir, name.strip_suffix(".json")?).map(|record| record.pid)
        })
        .collect()
}

/// Every record whose process runs (`alive`); the others are removed.
pub(crate) fn live(dir: &Path, alive: impl Fn(&Record) -> bool) -> Vec<Record> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut found = Vec::new();
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(id) = name.strip_suffix(".json") else { continue };
        match read(dir, id) {
            Some(record) if record.session_id == id && alive(&record) => found.push(record),
            // Dead, unreadable, or naming another session: never adopted.
            _ => {
                let _ = crate::home_fs::remove_file(entry.path());
            }
        }
    }
    found.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    found
}
