//! The small records `agent-transfer-v1` keeps next to the session's registry
//! so they outlive a daemon restart (`landed.rs`, `askable.rs`).
//!
//! A file is trusted only as this daemon writes it: a regular file owned by
//! this user, within [`MAX_FILE_BYTES`], opened without following a symlink
//! (anything else reads as nothing). It is written owner-only through a fresh
//! temporary and renamed into place. A record dated in the future (beyond a
//! minute of clock skew) or older than [`STALE`] is not fresh.

use std::io::{Read as _, Write as _};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use super::STALE;

/// The largest file read back (a few dozen short records are far below it).
const MAX_FILE_BYTES: u64 = 64 * 1024;
/// Clock skew a record's time may be ahead of now by.
const MAX_SKEW_MS: u64 = 60 * 1000;

pub(super) fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// A record made at `at_ms` is fresh at `now`: not in the future, not stale.
pub(super) fn fresh(at_ms: u64, now: u64) -> bool {
    at_ms <= now.saturating_add(MAX_SKEW_MS) && now.saturating_sub(at_ms) < STALE.as_millis() as u64
}

/// Opens `path` without following a final symlink (Unix).
fn open_options() -> std::fs::OpenOptions {
    let mut options = std::fs::OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options
}

/// The file's bytes when it is a regular file of this user within the size
/// bound, read through one handle (no symlink, no swap after the check).
pub(in crate::server) fn read_trusted(path: &Path) -> Option<Vec<u8>> {
    let file = open_options().read(true).open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // SAFETY: geteuid has no preconditions.
        if meta.uid() != unsafe { libc::geteuid() } {
            return None;
        }
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= MAX_FILE_BYTES).then_some(bytes)
}

/// Writes `records` as `directory/name`, owner-only and atomically, and durably: the directory is
/// synced after the rename, so a host crash after `Ok` never brings back the file before it (an
/// acknowledged revoke undone, a spent use restored).
pub(in crate::server) fn save<T: Serialize>(
    directory: &Path,
    name: &str,
    records: &T,
) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(records)?;
    let path = directory.join(name);
    let temporary = directory.join(format!("{name}.{}.tmp", std::process::id()));
    // A leftover (or planted) temporary goes first: the new one is created
    // fresh and never through a symlink.
    let _ = std::fs::remove_file(&temporary);
    let written = (|| {
        let mut options = open_options();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_data()?;
        drop(file);
        std::fs::rename(&temporary, &path)?;
        #[cfg(unix)]
        std::fs::File::open(directory)?.sync_all()?;
        Ok(())
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    written
}
