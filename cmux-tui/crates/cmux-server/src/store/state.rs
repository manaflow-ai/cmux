//! The updater's persistent record and its apply lock.
//!
//! `<state>/updater.json` holds the last applied `(sequence, sha256)`; it
//! lives in the state directory, so an uninstall keeps it and a reinstall
//! still refuses a replayed older manifest. `<root>/.lock` is held with an
//! exclusive `flock` for the whole apply, flip or GC, so one runs at a time.

use std::fs::{OpenOptions, TryLockError};
use std::path::Path;
use std::time::Duration;

use cmux_server_core::manifest::Applied;
use cmux_tui_util::retry::{Attempt, Patience};
use serde::{Deserialize, Serialize};

use crate::error::{Error, IoContext, Result};
use crate::fsx;
use crate::host::{hex, unhex32};

#[derive(Debug, Default, Serialize, Deserialize)]
struct Record {
    schema: u32,
    last_sequence: Option<u64>,
    last_sha256: Option<String>,
}

/// Reads the last applied manifest; a missing file means none.
pub fn load_applied(path: &Path) -> Result<Option<Applied>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Error::io(path.display(), e)),
    };
    let record: Record = serde_json::from_slice(&bytes)
        .map_err(|e| Error::internal(format!("{}: {e}", path.display())))?;
    match (record.last_sequence, record.last_sha256) {
        (Some(sequence), Some(sha)) => {
            let sha256 = unhex32(&sha).ok_or_else(|| {
                Error::internal(format!("{}: last_sha256 is not 64 hex", path.display()))
            })?;
            Ok(Some(Applied { sequence, sha256 }))
        }
        _ => Ok(None),
    }
}

/// Writes the record atomically (0600).
pub fn save_applied(path: &Path, applied: Applied) -> Result<()> {
    let record = Record {
        schema: 1,
        last_sequence: Some(applied.sequence),
        last_sha256: Some(hex(&applied.sha256)),
    };
    let mut bytes =
        serde_json::to_vec_pretty(&record).map_err(|e| Error::internal(e.to_string()))?;
    bytes.push(b'\n');
    if let Some(dir) = path.parent() {
        fsx::ensure_dir(dir, 0o700)?;
    }
    fsx::atomic_write(path, &bytes, 0o600)
}

/// How long a verb waits for another apply's store lock before it reports
/// that apply as still running.
pub const APPLY_LOCK_WAIT: Duration = Duration::from_secs(30);

/// An exclusive lock on the store root, released on drop.
#[derive(Debug)]
pub struct StoreLock {
    _file: fsx::FileLock,
}

impl StoreLock {
    /// Takes the lock, waiting up to [`APPLY_LOCK_WAIT`] for another apply
    /// to end. A holder still there then is `ExitKind::Unreachable`
    /// ("another apply is running").
    ///
    /// It never changes the mode of `root`: the root's owner and mode come
    /// from `cmux_server_core::access` (`/opt/cmux` stays root 0755 in
    /// system mode). A missing root is created with the default mode only.
    pub fn acquire(root: &Path) -> Result<StoreLock> {
        StoreLock::acquire_within(root, APPLY_LOCK_WAIT)
    }

    /// [`StoreLock::acquire`] with its own wait for another holder.
    pub(crate) fn acquire_within(root: &Path, wait: Duration) -> Result<StoreLock> {
        std::fs::create_dir_all(root).ctx(root.display())?;
        StoreLock::acquire_existing_within(root, wait)
    }

    /// Like [`StoreLock::acquire`] for verbs that need an install
    /// (rollback, switch, GC): a missing root is "nothing is installed"
    /// and is not created.
    pub fn acquire_existing(root: &Path) -> Result<StoreLock> {
        StoreLock::acquire_existing_within(root, APPLY_LOCK_WAIT)
    }

    fn acquire_existing_within(root: &Path, wait: Duration) -> Result<StoreLock> {
        if !root.is_dir() {
            return Err(Error::not_found(format!("nothing is installed at {}", root.display())));
        }
        let path = root.join(".lock");
        // Another apply holding the lock ends on its own, so wait for it
        // (bounded) instead of asking the person to run the command again.
        Patience::new("another cmux server apply to finish", wait).run(|| {
            let file = OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(&path)
                .ctx(path.display())
                .map_err(Attempt::Fail)?;
            match fsx::FileLock::try_acquire(file) {
                Ok(lock) => Ok(StoreLock { _file: lock }),
                Err(TryLockError::WouldBlock) => Err(Attempt::Retry(Error::unreachable(format!(
                    "another cmux server apply still holds {} after {} s; let it finish, or stop that cmux server process",
                    path.display(),
                    wait.as_secs()
                )))),
                Err(TryLockError::Error(e)) => Err(Attempt::Fail(Error::io(path.display(), e))),
            }
        })
    }
}

#[cfg(test)]
#[path = "state_tests.rs"]
mod tests;
