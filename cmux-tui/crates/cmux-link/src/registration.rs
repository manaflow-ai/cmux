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
//! returns the registration only while that pid is alive AND the socket
//! accepts a connection; otherwise `None`, never a dead socket. The daemon
//! answers `cmux.host.link.get`'s `hub_socket` with `read_live(..).socket`.

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
    let text = std::fs::read(path(state_dir)).ok()?;
    let registration: Registration = serde_json::from_slice(&text).ok()?;
    (registration.version == VERSION && registration.socket.is_absolute()).then_some(registration)
}

/// The registration only while its link is running: the pid is alive and
/// the socket accepts a connection.
pub fn read_live(state_dir: &Path) -> Option<Registration> {
    let registration = read(state_dir)?;
    (process_alive(registration.pid) && socket_accepts(&registration.socket))
        .then_some(registration)
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

#[cfg(not(unix))]
fn process_alive(_pid: u32) -> bool {
    false
}

#[cfg(unix)]
fn socket_accepts(socket: &Path) -> bool {
    std::os::unix::net::UnixStream::connect(socket).is_ok()
}

#[cfg(not(unix))]
fn socket_accepts(_socket: &Path) -> bool {
    false
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
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
