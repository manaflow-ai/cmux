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
//! terminal incarnation: a host that was replaced meanwhile (rehost, respawn)
//! wrote its own record, which a stale mirror must not overwrite. The thread
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

/// Whether the record at `path` is still `record`'s terminal incarnation.
fn still_this_incarnation(path: &Path, record: &TerminalHostRecord) -> bool {
    let Ok(bytes) = std::fs::read(path) else { return false };
    let Ok(current) = serde_json::from_slice::<TerminalHostRecord>(&bytes) else { return false };
    current.terminal_id == record.terminal_id && current.incarnation == record.incarnation
}
