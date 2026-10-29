//! The handoff record: an owner's explicit, recorded transfer of its
//! terminals before it exits.
//!
//! A holder whose daemon (its owner) goes away ends its terminals, unless
//! that owner wrote a handoff record first. The record is one file beside
//! the holder's socket, `<socket>.handoff`, 0600, written atomically (a
//! temporary file, then a rename) before the owner exits. The holder reads
//! and removes it when the link ends. A record a daemon left behind is
//! removed by the next daemon that connects, so it cannot carry over to a
//! later exit.
//!
//! Format (UTF-8, first line is the magic and version):
//!
//! ```text
//! CMHO 1
//! handoff: all terminals
//! ```

use std::fs::OpenOptions;
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// The first line of a valid record.
pub const MAGIC_LINE: &str = "CMHO 1";
/// The record's second line: what the owner hands off.
pub const SCOPE_LINE: &str = "handoff: all terminals";
/// Longest record the holder reads; a valid one is far shorter.
const MAX_RECORD_BYTES: u64 = 4096;

/// Where the record of the holder serving `socket` lives.
pub fn record_path(socket: &Path) -> PathBuf {
    let mut path = socket.as_os_str().to_os_string();
    path.push(".handoff");
    PathBuf::from(path)
}

/// Write the handoff record for the holder serving `socket`. The owner
/// calls this before it exits; the holder then keeps every terminal when
/// the link ends. Returns the record's path.
pub fn write_record(socket: &Path) -> io::Result<PathBuf> {
    let path = record_path(socket);
    let mut temporary = path.as_os_str().to_os_string();
    temporary.push(format!(".tmp-{}", std::process::id()));
    let temporary = PathBuf::from(temporary);
    let _ = std::fs::remove_file(&temporary);
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary)?;
        file.write_all(format!("{MAGIC_LINE}\n{SCOPE_LINE}\n").as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&temporary, &path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result.map(|()| path)
}

/// Read and remove the handoff record of the holder serving `socket`.
/// True only for a valid record: a regular file of this user, 0600, with
/// the magic line. Any other entry is removed too and counts as no handoff.
pub fn take_record(socket: &Path) -> bool {
    let path = record_path(socket);
    let valid = read_valid(&path);
    let _ = std::fs::remove_file(&path);
    valid
}

/// Remove any record for `socket` (a new daemon's link makes an old one
/// stale).
pub fn discard_record(socket: &Path) {
    let _ = std::fs::remove_file(record_path(socket));
}

fn read_valid(path: &Path) -> bool {
    let Ok(file) =
        OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(path)
    else {
        return false;
    };
    let Ok(metadata) = file.metadata() else { return false };
    // SAFETY: geteuid has no failure mode.
    let owner = unsafe { libc::geteuid() };
    if !metadata.is_file()
        || metadata.uid() != owner
        || metadata.permissions().mode() & 0o777 != 0o600
        || metadata.len() > MAX_RECORD_BYTES
    {
        return false;
    }
    let mut text = String::new();
    if file.take(MAX_RECORD_BYTES).read_to_string(&mut text).is_err() {
        return false;
    }
    let mut lines = text.lines();
    lines.next() == Some(MAGIC_LINE) && lines.next() == Some(SCOPE_LINE)
}
