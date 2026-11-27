//! The advisory lock every cmux writer of a codex config.toml takes for its read-modify-rename:
//! the hook installer (cmux-tui-hooks `codex_trust.rs`), `acpmux desktop link` (acpmux
//! `desktop_link.rs`) and the Cloud devbox shell-start merge
//! (web/services/vms/images/devbox/agent-config.sh, which flocks the same file name in the same
//! directory). Without it, two writers that each re-read before their rename can still drop the
//! other's keys (the provider block, the hook trust state or the MCP server entry) in the window
//! between read and rename.

use std::fs;
use std::path::Path;
#[cfg(unix)]
use std::time::{Duration, Instant};

/// The lock file, beside the unresolved config.toml (in the codex home, not where a symlinked
/// config.toml points).
pub const LOCK_FILE: &str = "config.toml.cmux-lock";

/// How long a writer waits for another writer's lock. The shell-start holders keep it for one
/// bounded read and rename and give up after 5 s, but a stopped or hung holder must not stall a
/// write forever.
#[cfg(unix)]
const LOCK_WAIT: Duration = Duration::from_secs(15);

/// Returns once this process holds `lock_path` exclusively, or `None` when it cannot: a
/// directory that refuses the lock file, a filesystem without flock, or a holder that keeps it
/// past [`LOCK_WAIT`]. The caller then goes ahead unlocked, as before the lock existed, instead of
/// failing or hanging; its own re-read before the rename still guards that case. Released when the
/// file drops.
#[cfg(unix)]
pub fn lock(lock_path: &Path) -> Option<fs::File> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC)
        .open(lock_path)
        .ok()?;
    let deadline = Instant::now().checked_add(LOCK_WAIT);
    loop {
        match file.try_lock() {
            Ok(()) => return Some(file),
            Err(fs::TryLockError::WouldBlock) if deadline.is_some_and(|d| Instant::now() < d) => {
                // Lock contention, not synchronization: flock has no
                // wait-with-timeout, so poll at a short interval to a deadline.
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(_) => return None,
        }
    }
}

#[cfg(not(unix))]
pub fn lock(_lock_path: &Path) -> Option<fs::File> {
    None
}
