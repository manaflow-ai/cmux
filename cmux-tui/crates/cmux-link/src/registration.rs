//! Where this machine's link listens: `<daemon state dir>/link.json`, for
//! example `~/Library/Application Support/cmux-tui/sessions/link.json` on
//! macOS (the daemon state dir is `cmux_tui_core::platform::
//! workspace_state_dir()`, which `CMUX_TUI_STATE_DIR` overrides).
//!
//! Format (mode 0600, replaced atomically by a temp file and a rename):
//! `{"version":1,"socket":"/abs/path/link.sock","pid":1234}`.
//!
//! The link writes it once its socket listens and removes it on a clean
//! exit. A crash leaves the file behind, so readers use [`read_live`]: it
//! returns the registration only while that pid serves the socket (see
//! [`read_live`] for every check); otherwise `None`, never a dead socket or
//! one another process serves. The daemon answers `cmux.host.link.get`'s
//! `hub_socket` with `read_live(..).socket`.

use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The file name inside the daemon state dir.
pub const FILE_NAME: &str = "link.json";

/// The only format version.
pub const VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registration {
    pub version: u32,
    /// The link's local socket (absolute).
    pub socket: PathBuf,
    /// The link process.
    pub pid: u32,
}

impl Registration {
    pub fn new(socket: PathBuf, pid: u32) -> Self {
        Self { version: VERSION, socket, pid }
    }
}

/// `<state_dir>/link.json`.
pub fn path(state_dir: &Path) -> PathBuf {
    state_dir.join(FILE_NAME)
}

/// Write `registration` to `<state_dir>/link.json`: mode 0600, through a
/// temp file in the same directory and a rename, so a reader sees the old
/// file or the new one, never a partial one.
pub fn write(state_dir: &Path, registration: &Registration) -> io::Result<()> {
    let text = serde_json::to_vec(registration)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    std::fs::create_dir_all(state_dir)?;
    let temporary = state_dir.join(format!(".{FILE_NAME}.{}.tmp", std::process::id()));
    let result = write_private(&temporary, &text)
        .and_then(|()| std::fs::rename(&temporary, path(state_dir)));
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

/// Remove the file when it still names `pid` (a clean exit of that link).
pub fn remove_if_owned(state_dir: &Path, pid: u32) {
    if read(state_dir).is_some_and(|registration| registration.pid == pid) {
        let _ = std::fs::remove_file(path(state_dir));
    }
}

/// The registration as written, live or not.
pub fn read(state_dir: &Path) -> Option<Registration> {
    parse(&std::fs::read(path(state_dir)).ok()?)
}

fn parse(text: &[u8]) -> Option<Registration> {
    let registration: Registration = serde_json::from_slice(text).ok()?;
    (registration.version == VERSION && registration.socket.is_absolute()).then_some(registration)
}

/// The registration only while its link is running and is this user's
/// link. Every check must pass, else `None`:
///
/// 1. `link.json` is a regular file (not a symlink) owned by this
///    process's effective uid and not group- or world-writable.
/// 2. Its pid is alive.
/// 3. Its socket path is a socket file (not a symlink) owned by this
///    effective uid, and it accepts a connection.
/// 4. The peer of that connection runs as this effective uid and, where
///    the system names the peer pid (Linux `SO_PEERCRED`, macOS
///    `LOCAL_PEERPID`), is the registered pid: the process that listens on
///    the socket is the one `link.json` names. The other BSDs have no
///    peer-pid API and check the uid only.
///
/// Limit: this is the same-user trust boundary, the accepted cmux model.
/// A process of this user that listens on its own socket and writes its
/// own pid into `link.json` still passes. A stronger check (for example
/// the code signature of the peer executable on macOS, as
/// [`crate::caller`] does for incoming callers) is a follow-up.
///
/// Windows has no link socket: always `None`.
#[cfg(unix)]
pub fn read_live(state_dir: &Path) -> Option<Registration> {
    let registration = read_owned(state_dir)?;
    if !process_alive(registration.pid) {
        return None;
    }
    let stream = connect_owned(&registration.socket)?;
    served_by(&stream, registration.pid).then_some(registration)
}

/// See the Unix [`read_live`].
#[cfg(not(unix))]
pub fn read_live(_state_dir: &Path) -> Option<Registration> {
    None
}

/// The most bytes `link.json` may hold; a real one is under 200.
#[cfg(unix)]
const MAX_FILE_BYTES: u64 = 64 * 1024;

/// [`read`] for [`read_live`]: opened without following a symlink, and the
/// opened file (not the path) must be a regular file of this effective uid
/// that no group or other user may write.
#[cfg(unix)]
fn read_owned(state_dir: &Path) -> Option<Registration> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path(state_dir))
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.uid() != effective_uid() || metadata.mode() & 0o022 != 0 {
        return None;
    }
    let mut text = Vec::new();
    file.take(MAX_FILE_BYTES).read_to_end(&mut text).ok()?;
    parse(&text)
}

/// Connect to `socket` only when the path itself (not a symlink target) is
/// a socket file owned by this effective uid.
#[cfg(unix)]
fn connect_owned(socket: &Path) -> Option<std::os::unix::net::UnixStream> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    let metadata = std::fs::symlink_metadata(socket).ok()?;
    if !metadata.file_type().is_socket() || metadata.uid() != effective_uid() {
        return None;
    }
    std::os::unix::net::UnixStream::connect(socket).ok()
}

/// The connected peer runs as this effective uid and, where the system
/// names it, is `pid`. The path checks in [`connect_owned`] can race a
/// rename; these credentials belong to the connection itself.
#[cfg(unix)]
fn served_by(stream: &std::os::unix::net::UnixStream, pid: u32) -> bool {
    use std::os::fd::AsRawFd;
    let fd = stream.as_raw_fd();
    if crate::caller::peer_uid(fd).ok() != Some(effective_uid()) {
        return false;
    }
    match crate::caller::peer_pid(fd) {
        Ok(Some(peer)) => peer == pid,
        Ok(None) => true,
        Err(_) => false,
    }
}

#[cfg(unix)]
fn effective_uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 only checks that the process exists.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file =
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    std::fs::write(path, bytes)
}

#[cfg(all(test, unix))]
#[path = "registration_tests.rs"]
mod tests;
