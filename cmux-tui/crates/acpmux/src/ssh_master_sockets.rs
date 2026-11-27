//! Dead master sockets in acpmux's own `<home>/run/ssh` are removed.
//!
//! A master that ends without unlinking its socket (it was killed, the box rebooted, the
//! network dropped and ServerAlive ended it hard) leaves the file. ssh unlinks a stale socket
//! only when that same destination is dialed again, so a host the daemon no longer dials keeps
//! its file indefinitely. cosmic-gray, 2026-11-27: 132 socket files for 48 live masters (Leo,
//! lw#12615: "cosmic-gray has been bricked since 4am ... every coordinator on it times out").
//!
//! [`sweep`] removes only sockets in that directory that refuse a connect, the same test ssh uses
//! before it unlinks one. A live master accepts, so it is kept. A socket mid-bind has nothing in
//! the directory yet. The `.lock` files next to the sockets are kept: a lock another daemon holds
//! open must not change inode. The daemon sweeps at start and every [`EVERY`] (`daemon.rs`).

use std::path::Path;
use std::time::Duration;

/// How often the running daemon sweeps again.
pub(crate) const EVERY: Duration = Duration::from_secs(600);

/// What one sweep did.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Swept {
    pub(crate) removed: usize,
    pub(crate) live: usize,
}

/// Removes the sockets in `dir` (acpmux's own `run/ssh`) that no master listens on. Blocking: run
/// it off the runtime's workers.
#[cfg(unix)]
pub(crate) fn sweep(dir: &Path) -> Swept {
    use std::os::unix::fs::FileTypeExt;
    let mut swept = Swept::default();
    let Ok(entries) = std::fs::read_dir(dir) else { return swept };
    for entry in entries.flatten() {
        let Ok(kind) = entry.file_type() else { continue };
        if !kind.is_socket() {
            continue;
        }
        let path = entry.path();
        match std::os::unix::net::UnixStream::connect(&path) {
            Ok(_) => swept.live += 1,
            Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
                if std::fs::remove_file(&path).is_ok() {
                    swept.removed += 1;
                }
            }
            Err(_) => {}
        }
    }
    if swept.removed > 0 {
        tracing::info!(
            removed = swept.removed,
            live = swept.live,
            "removed dead ssh master sockets"
        );
    }
    swept
}

#[cfg(not(unix))]
pub(crate) fn sweep(_dir: &Path) -> Swept {
    Swept::default()
}

#[cfg(test)]
#[path = "ssh_master_sockets_tests.rs"]
mod tests;
