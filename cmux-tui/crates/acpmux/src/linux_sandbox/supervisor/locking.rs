//! Coordination for all sandbox filesystem transactions in this daemon and uid.
//!
//! The lock inode is owner-write-only (0200), so a capability-free sandbox
//! cannot open it for reading or writing through bwrap's read-only root. The
//! G1 precondition is that this private lock directory is never under a
//! writable root; G1 also keeps `--cap-drop ALL`, so the sandbox cannot use
//! DAC override. Real tools may still use flock(2) on their own descriptors.
use super::*;

use std::sync::{Mutex, MutexGuard, TryLockError};

static TRANSACTION: Mutex<()> = Mutex::new(());

pub(super) struct Guard<'a> {
    file: &'a OwnedFd,
    _local: MutexGuard<'static, ()>,
}
impl Drop for Guard<'_> {
    fn drop(&mut self) {
        unsafe {
            flock(self.file.as_raw_fd(), LOCK_UN);
        }
    }
}

// The directory must be private and outside the policy's writable roots, so a
// sandbox cannot unlink/replace the coordination inode while another holds it.
fn valid_lock(info: &stat, uid: uid_t) -> bool {
    info.st_uid == uid && info.st_mode & (S_IFMT | 0o777) == S_IFREG | 0o200 && info.st_nlink == 1
}
pub(super) fn open(policy: &WritePolicy) -> Result<OwnedFd> {
    use std::os::unix::fs::DirBuilderExt;
    let uid = unsafe { getuid() };
    let directory = match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(path) => std::path::PathBuf::from(path),
        None => {
            let path = std::path::PathBuf::from(format!("/tmp/acpmux-{uid}"));
            match std::fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err(EACCES),
            }
            path
        }
    };
    if !directory.is_absolute() {
        return Err(EACCES);
    }
    let task = open_at(AT_FDCWD, "/proc/self", O_PATH | O_DIRECTORY, 0)?;
    let walked = resolve(task.as_raw_fd(), AT_FDCWD, directory.to_str().ok_or(EACCES)?, 0, "self")?;
    if policy.check(Path::new(&walked.logical)).is_ok() {
        return Err(EACCES);
    }
    let dir = open_at(walked.parent.as_raw_fd(), &walked.name, O_DIRECTORY | O_NOFOLLOW, 0)?;
    let info = stat(dir.as_raw_fd())?;
    if info.st_uid != uid || info.st_mode & 0o077 != 0 {
        return Err(EACCES);
    }
    let file = open_at(
        dir.as_raw_fd(),
        "acpmux-linux-sandbox.lock",
        O_CREAT | O_WRONLY | O_NOFOLLOW | O_NONBLOCK,
        0o200,
    )?;
    let info = stat(file.as_raw_fd())?;
    if !valid_lock(&info, uid) {
        return Err(EACCES);
    }
    Ok(file)
}

/// Acquisition retries end on success, stop readability, listener HUP, or error.
/// Nonblocking mutex/flock plus a 10ms poll keep cancellation responsive. Hold
/// both locks through resolve/check/perform; no per-parent recheck is relied on.
pub(super) fn acquire(file: &OwnedFd, stop: RawFd, listener: RawFd) -> Result<Guard<'_>> {
    loop {
        let local = match TRANSACTION.try_lock() {
            Ok(guard) => Some(guard),
            Err(TryLockError::WouldBlock) => None,
            Err(TryLockError::Poisoned(_)) => return Err(EACCES),
        };
        if let Some(local) = local {
            if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } == 0 {
                return Ok(Guard { file, _local: local });
            }
            if !matches!(error(), EWOULDBLOCK | EINTR) {
                return Err(error());
            }
        }
        let mut polls = [
            pollfd { fd: stop, events: POLLIN, revents: 0 },
            pollfd { fd: listener, events: 0, revents: 0 },
        ];
        if unsafe { poll(polls.as_mut_ptr(), 2, 10) } < 0 && error() != EINTR {
            return Err(error());
        }
        if polls[0].revents & POLLIN != 0 || polls[1].revents & POLLHUP != 0 {
            return Err(ECANCELED);
        }
        if polls.iter().any(|p| p.revents & (POLLERR | POLLNVAL) != 0) {
            return Err(EACCES);
        }
    }
}

#[cfg(test)]
mod tests;
