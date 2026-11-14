//! The PTY ownership fence of one terminal incarnation (cx-6so.49 L1).
//!
//! With PTY custody, the owner holds a copy of a host's PTY master and can
//! start a replacement host on it. Two hosts must never serve the same
//! incarnation: both would read the PTY and split its bytes. Every host
//! therefore holds an exclusive kernel lock on
//! `<root>/<terminal id>.<incarnation>.pty.lock` for its whole process
//! lifetime, taken before it touches a PTY or publishes anything. The kernel
//! releases it only when the holder process is really gone, so a stopped
//! (`SIGSTOP`) host still holds it and is never replaced.
//!
//! The file is removed only by a remover that itself holds the lock (so no
//! live host loses its fence), and an acquirer that finds its locked file
//! unlinked or replaced retries on the new file.

use super::*;

/// The lock file of `terminal_id`/`incarnation` beside `record_path` (any
/// file in the host record directory).
pub(super) fn lock_path(record_path: &Path, terminal_id: &str, incarnation: &str) -> PathBuf {
    record_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(format!("{terminal_id}.{incarnation}.pty.lock"))
}

/// A held PTY ownership lock. Dropping it (or the process ending) releases
/// the lock; the file stays until the exit is acknowledged.
#[derive(Debug)]
pub(crate) struct PtyOwnershipLock {
    _file: File,
}

fn open_lock_file(path: &Path, create: bool) -> std_io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
}

/// Take the lock without blocking. Ok(false) when another holder has it.
fn try_lock(file: &File) -> std_io::Result<bool> {
    loop {
        // SAFETY: flock only changes the advisory lock of this valid,
        // owned descriptor.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(true);
        }
        let error = std_io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(code) if code == libc::EWOULDBLOCK || code == libc::EAGAIN => return Ok(false),
            _ => return Err(error),
        }
    }
}

/// Whether `file` is still the inode named by `path`.
fn still_named(file: &File, path: &Path) -> bool {
    match (file.metadata(), fs::symlink_metadata(path)) {
        (Ok(held), Ok(named)) => held.dev() == named.dev() && held.ino() == named.ino(),
        _ => false,
    }
}

impl PtyOwnershipLock {
    /// Take the fence of `terminal_id`/`incarnation`, or fail when another
    /// host process (live or stopped) holds it.
    pub(super) fn acquire(
        record_path: &Path,
        terminal_id: &str,
        incarnation: &str,
    ) -> anyhow::Result<Self> {
        let path = lock_path(record_path, terminal_id, incarnation);
        // A concurrent remover can unlink the file between open and lock;
        // a few retries cover that, a persistent mismatch is an error.
        for _ in 0..8 {
            let file = open_lock_file(&path, true)
                .with_context(|| format!("open PTY ownership lock {}", path.display()))?;
            let metadata = file.metadata()?;
            if !metadata.file_type().is_file()
                || metadata.uid() != crate::platform::effective_uid()
                || metadata.mode() & 0o077 != 0
            {
                anyhow::bail!("PTY ownership lock {} is unsafe", path.display());
            }
            if !try_lock(&file)? {
                anyhow::bail!(
                    "another terminal host still owns the PTY of terminal {terminal_id} \
                     incarnation {incarnation}"
                );
            }
            if still_named(&file, &path) {
                return Ok(Self { _file: file });
            }
        }
        anyhow::bail!("PTY ownership lock {} kept changing", path.display())
    }
}

/// Remove the fence file of `terminal_id`/`incarnation` when no host holds
/// it (its terminal ended and was acknowledged, or its record was proven
/// dead). A held lock is left alone.
pub(crate) fn remove_released(record_path: &Path, terminal_id: &str, incarnation: &str) {
    remove_released_path(&lock_path(record_path, terminal_id, incarnation));
}

fn remove_released_path(path: &Path) {
    let Ok(file) = open_lock_file(path, false) else { return };
    remove_released_file(file, path);
}

/// [`remove_released_path`] on the fence file opened as `file`.
fn remove_released_file(file: File, path: &Path) {
    use cmux_file_lock::{FileLock, Kind};
    // Held only to remove the file; the drop unlocks before it closes, so a
    // replacement host that opened this inode first takes it and retries on
    // a new file, also while a child the server forked meanwhile has this
    // descriptor.
    let Ok(lock) = FileLock::try_take(file, Kind::Exclusive) else { return };
    if still_named(lock.file(), path) {
        let _ = fs::remove_file(path);
    }
}

/// Remove every released fence file in the host record directory `root`:
/// a host that died before it published, or a dead record removed by an
/// older build, leaves one behind. A held fence names a live host and stays.
/// Run only while this owner starts no replacement host: an acquirer that
/// meets the sweep's brief lock fails instead of waiting.
pub(crate) fn sweep_released_pty_locks(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(".pty.lock"))
        {
            remove_released_path(&path);
        }
    }
}

#[cfg(test)]
mod tests;
