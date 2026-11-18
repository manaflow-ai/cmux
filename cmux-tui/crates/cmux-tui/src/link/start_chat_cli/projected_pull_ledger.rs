//! A mount's ledger on disk, and the lock that makes its pulls one at a time.
//!
//! The ledger is `pulled.json` (written whole, renamed into place) and `pulled.journal` beside
//! it: one line for each path a pull settles, appended the moment it is settled, before the next
//! item. Loading folds the journal into the snapshot. A pull starts by writing the snapshot with
//! any journal an earlier pull left folded in and emptying the journal, and ends the same way. A
//! pull stopped at any point (a kill, a crash, the App quitting) leaves every path it settled in
//! one or the other; a line it was cut off writing is not a path it settled. Each settled path
//! costs one appended line, so a pull's writes stay in proportion to its edits; the whole
//! snapshot is written once at each end, as before.

use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::Path;

use cmux_file_lock::{FileLock, Kind, LockError};
use serde::{Deserialize, Serialize};

use super::super::super::super::sync_cli::back::{Ledger, Pulled};
use super::super::write_private;
use super::PULLED;

/// The journal beside `pulled.json`.
pub(super) const JOURNAL: &str = "pulled.journal";
/// The file a pull holds locked from start to end.
pub(super) const LOCK: &str = "pull.lock";

#[derive(Serialize)]
struct Line<'a> {
    path: &'a str,
    pulled: &'a Pulled,
}

#[derive(Deserialize)]
struct Read {
    path: String,
    pulled: Pulled,
}

fn private(options: &mut OpenOptions) -> &mut OpenOptions {
    options.mode(0o600).custom_flags(libc::O_NOFOLLOW)
}

/// Why no pull may run now.
pub(super) enum Busy {
    /// Another pull of this mount holds the lock.
    Held,
    Io(std::io::Error),
}

/// Takes the mount's pull lock in `dir` now, or [`Busy::Held`] while another pull holds it.
pub(super) fn lock(dir: &Path) -> Result<FileLock, Busy> {
    let file = private(OpenOptions::new().read(true).write(true).create(true))
        .open(dir.join(LOCK))
        .map_err(Busy::Io)?;
    match FileLock::try_take(file, Kind::Exclusive) {
        Ok(held) => Ok(held),
        Err(LockError::Busy(_)) => Err(Busy::Held),
        Err(LockError::Io(error)) => Err(Busy::Io(error)),
    }
}

/// The ledger kept in `dir`: the snapshot with the journal folded in. Err: why it is unreadable.
pub(super) fn load(dir: &Path) -> Result<Ledger, String> {
    let mut ledger = match std::fs::read(dir.join(PULLED)) {
        Ok(bytes) => serde_json::from_slice::<Ledger>(&bytes)
            .map_err(|error| format!("{PULLED}: {error}"))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ledger::default(),
        Err(error) => return Err(format!("{PULLED}: {error}")),
    };
    let journal = match std::fs::read(dir.join(JOURNAL)) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(format!("{JOURNAL}: {error}")),
    };
    let mut lines = journal.split(|byte| *byte == b'\n').peekable();
    while let Some(line) = lines.next() {
        let last = lines.peek().is_none();
        if line.is_empty() {
            continue;
        }
        match serde_json::from_slice::<Read>(line) {
            Ok(read) => {
                ledger.paths.insert(read.path, read.pulled);
            }
            // A line with no end is one a stopped pull was cut off writing.
            Err(_) if last => {}
            Err(error) => return Err(format!("{JOURNAL}: {error}")),
        }
    }
    Ok(ledger)
}

/// Writes `ledger` as the snapshot, then empties the journal (whose lines it holds).
pub(super) fn save(dir: &Path, ledger: &Ledger) -> std::io::Result<()> {
    let mut whole = ledger.clone();
    whole.version = 1;
    let bytes = serde_json::to_vec(&whole).map_err(std::io::Error::other)?;
    write_private(&dir.join(PULLED), &bytes)?;
    match private(OpenOptions::new().write(true)).open(dir.join(JOURNAL)) {
        Ok(journal) => journal.set_len(0),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// Whether `dir` holds journal lines not yet in the snapshot.
pub(super) fn has_journal(dir: &Path) -> bool {
    std::fs::symlink_metadata(dir.join(JOURNAL)).is_ok_and(|meta| meta.len() > 0)
}

/// The journal, open to append.
pub(super) struct Journal {
    file: File,
}

impl Journal {
    pub(super) fn open(dir: &Path) -> std::io::Result<Journal> {
        let file = private(OpenOptions::new().append(true).create(true)).open(dir.join(JOURNAL))?;
        Ok(Journal { file })
    }

    /// Appends `path` settled at `pulled`, as one write.
    pub(super) fn add(&mut self, path: &str, pulled: &Pulled) -> std::io::Result<()> {
        let mut line = serde_json::to_vec(&Line { path, pulled }).map_err(std::io::Error::other)?;
        line.push(b'\n');
        self.file.write_all(&line)
    }
}
