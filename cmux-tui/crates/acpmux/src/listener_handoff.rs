//! `listener.json` in the acpmux home: where this daemon's WebSocket listener is bound, for the
//! cmux link, which carries a paired peer's `acpmux` stream to it (`cmux-tui`
//! `link/acpmux.rs`).
//!
//! `websocket.listen` in config.json is not enough: a DEV build listens on `127.0.0.1:0` and
//! never saves the port it got, and a daemon whose saved port was taken moves to a free one.
//! The daemon writes this file once its listener is bound and removes it on a clean exit; a
//! reader takes it only while its pid runs, else falls back to config.json.
//!
//! Format (mode 0600, replaced through a temp file and a rename):
//! `{"version":1,"listen":"127.0.0.1:52341","pid":1234}`.

use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::Path;

/// The file name in the acpmux home.
pub const FILE_NAME: &str = "listener.json";
const VERSION: u32 = 1;
const MAX_BYTES: u64 = 4096;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Handoff {
    version: u32,
    listen: SocketAddr,
    pid: u32,
}

/// Record `listen` as this process's listener in `home`.
pub fn write(home: &Path, listen: SocketAddr) -> std::io::Result<()> {
    write_for(home, listen, std::process::id())
}

fn write_for(home: &Path, listen: SocketAddr, pid: u32) -> std::io::Result<()> {
    use std::io::Write as _;
    let text = serde_json::to_vec(&Handoff { version: VERSION, listen, pid })
        .map_err(std::io::Error::other)?;
    let temp = home.join(format!(".{FILE_NAME}.{}.tmp", std::process::id()));
    let written = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&temp)?;
        file.write_all(&text)?;
        file.sync_all()?;
        std::fs::rename(&temp, home.join(FILE_NAME))
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

/// Remove the file when it is this process's (a clean exit).
pub fn remove_if_owned(home: &Path) {
    if read(home).is_some_and(|handoff| handoff.pid == std::process::id()) {
        let _ = std::fs::remove_file(home.join(FILE_NAME));
    }
}

fn read(home: &Path) -> Option<Handoff> {
    let path = home.join(FILE_NAME);
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return None;
    }
    let handoff: Handoff = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (handoff.version == VERSION).then_some(handoff)
}

/// The listener the daemon of `home` recorded, while that daemon runs.
pub fn read_live(home: &Path) -> Option<SocketAddr> {
    let handoff = read(home)?;
    alive(handoff.pid).then_some(handoff.listen)
}

#[cfg(unix)]
fn alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 only checks that the process exists; nothing is sent.
    let sent = unsafe { libc::kill(pid, 0) };
    sent == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn alive(_pid: u32) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bound_port_is_handed_to_the_link_while_the_daemon_runs() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(read_live(home.path()), None, "no file: the link reads config.json");
        let bound: SocketAddr = "127.0.0.1:52341".parse().unwrap();
        write(home.path(), bound).unwrap();
        assert_eq!(read_live(home.path()), Some(bound));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(home.path().join(FILE_NAME)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        remove_if_owned(home.path());
        assert_eq!(read_live(home.path()), None, "a clean exit removes it");
    }

    #[cfg(unix)]
    #[test]
    fn a_file_left_by_a_dead_daemon_is_not_read() {
        let home = tempfile::tempdir().unwrap();
        // A pid that ran and ended: a child we waited for.
        let mut child = std::process::Command::new("true").spawn().unwrap();
        let pid = child.id();
        child.wait().unwrap();
        write_for(home.path(), "127.0.0.1:52341".parse().unwrap(), pid).unwrap();
        assert_eq!(read_live(home.path()), None);
        // Not this process's: a clean exit leaves another daemon's file alone.
        remove_if_owned(home.path());
        assert!(home.path().join(FILE_NAME).exists());
    }
}
