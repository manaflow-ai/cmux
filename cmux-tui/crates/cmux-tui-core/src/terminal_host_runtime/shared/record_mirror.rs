//! The daemon's rewrites of a host record's workspace key, off the request
//! path (PL-daemon).
//!
//! A host record names the workspace its terminal sits in. That key is a
//! recovery mirror only: the SQLite registry is the placement authority, and
//! the mirror is read when a restarted owner finds a live host the registry
//! does not place. Every tab move, drag, screen move or respawn rewrote the
//! record with a data barrier and a directory barrier (`write_record`, two
//! syncs, about 5 ms on a fleet M4 Pro) on the request thread, once per
//! terminal moved.
//!
//! Now a move queues the new record here and returns. One writer thread
//! writes the newest queued record of each path (an older queued one is
//! replaced, so a later move always wins), keeping the record's data barrier
//! so a power cut never leaves a torn record, and syncs each directory once
//! per batch. It writes a record only while the file still holds the same
//! terminal incarnation and host process (pid and start nonce): a host that
//! was replaced meanwhile (rehost, respawn) wrote its own record, which a
//! stale mirror must not overwrite. The thread
//! starts on first use and sleeps on a condition variable when nothing is
//! queued.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex, OnceLock};

use crate::panic_free::RecoverPoison;

use super::super::TerminalHostRecord;
use super::records::write_record_deferring_dir_sync;

struct Mirror {
    /// The newest record to write, per record path.
    pending: Mutex<HashMap<PathBuf, TerminalHostRecord>>,
    changed: Condvar,
}

fn mirror() -> &'static Mirror {
    static MIRROR: OnceLock<Mirror> = OnceLock::new();
    MIRROR.get_or_init(|| {
        let spawned =
            std::thread::Builder::new().name("terminal-host-record-mirror".into()).spawn(run);
        if let Err(error) = spawned {
            eprintln!("cmux-tui: host record mirror writer did not start: {error}");
        }
        Mirror { pending: Mutex::default(), changed: Condvar::new() }
    })
}

/// Queue `record` to be written at `path` (replacing an older queued one).
pub(crate) fn queue(path: &Path, record: TerminalHostRecord) {
    let mirror = mirror();
    mirror.pending.lock().recover_poison().insert(path.to_path_buf(), record);
    mirror.changed.notify_all();
}

fn run() {
    let mirror = mirror();
    loop {
        let batch = {
            let mut pending = mirror.pending.lock().recover_poison();
            while pending.is_empty() {
                pending = mirror.changed.wait(pending).recover_poison();
            }
            std::mem::take(&mut *pending)
        };
        let mut dirs = BTreeSet::new();
        for (path, record) in batch {
            if still_this_incarnation(&path, &record)
                && write_record_deferring_dir_sync(&path, &record).is_ok()
                && let Some(parent) = path.parent()
            {
                dirs.insert(parent.to_path_buf());
            }
        }
        for dir in dirs {
            let _ = super::super::sys::barrier_sync_dir(&dir);
        }
    }
}

/// Whether the record at `path` is still `record`'s host: the same terminal
/// incarnation served by the same host process. A rehost keeps the
/// incarnation and changes the host pid and process-start nonce, so a write
/// queued for the replaced host must not land on its replacement's record.
fn still_this_incarnation(path: &Path, record: &TerminalHostRecord) -> bool {
    let Ok(bytes) = std::fs::read(path) else { return false };
    let Ok(current) = serde_json::from_slice::<TerminalHostRecord>(&bytes) else { return false };
    current.terminal_id == record.terminal_id
        && current.incarnation == record.incarnation
        && current.host_start_nonce == record.host_start_nonce
        && current.host_pid == record.host_pid
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(nonce: &str, pid: u32, workspace: &str) -> TerminalHostRecord {
        TerminalHostRecord {
            record_version: 4,
            terminal_id: "00000000000040008000000000000b01".into(),
            incarnation: "00000000000040008000000000000b02".into(),
            host_pid: pid,
            host_start_nonce: nonce.into(),
            workspace_key: workspace.into(),
            ..Default::default()
        }
    }

    /// A rehost keeps the terminal id and the incarnation (the shell is the
    /// same run) and changes the host pid and nonce. A mirror write queued
    /// for the replaced host must not overwrite the replacement's record:
    /// the next start would find the dead host's nonce, end the live
    /// terminal, and remove the replacement's endpoint.
    #[test]
    fn a_queued_write_of_a_replaced_host_keeps_the_replacements_record() {
        let dir = std::env::temp_dir()
            .join(format!("cmux-record-mirror-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("00000000000040008000000000000b01.json");
        let replacement = record("bb", 222, "workspace-one");
        std::fs::write(&path, serde_json::to_vec(&replacement).unwrap()).unwrap();
        assert!(
            !still_this_incarnation(&path, &record("aa", 111, "workspace-two")),
            "a write for the replaced host would overwrite its replacement's record"
        );
        assert!(still_this_incarnation(&path, &record("bb", 222, "workspace-two")));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
