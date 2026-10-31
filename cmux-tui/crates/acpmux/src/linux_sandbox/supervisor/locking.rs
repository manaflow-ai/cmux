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
mod tests {
    use super::*;
    use std::{sync::mpsc, time::Duration};

    fn event() -> OwnedFd {
        let fd = unsafe { eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK) };
        assert!(fd >= 0);
        unsafe { OwnedFd::from_raw_fd(fd) }
    }

    // Files are independently opened, never dup'ed: flock tracks open descriptions.
    fn files() -> (OwnedFd, OwnedFd) {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let path = format!(
            "/tmp/acpmux-lock-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        let first = open_at(AT_FDCWD, &path, O_CREAT | O_EXCL | O_RDWR, 0o600).unwrap();
        let second = open_at(AT_FDCWD, &path, O_RDWR, 0).unwrap();
        std::fs::remove_file(path).unwrap();
        (first, second)
    }

    /// Finite channel handshakes have deadlines; stop bounds lock acquisition.
    #[test]
    fn transaction_guard_serializes_threads_and_holds_flock() {
        let (first, second) = files();
        let stop = event();
        let listener = event();
        let guard = acquire(&first, stop.as_raw_fd(), listener.as_raw_fd()).unwrap();
        assert_eq!(unsafe { flock(second.as_raw_fd(), LOCK_EX | LOCK_NB) }, -1);
        assert_eq!(error(), EWOULDBLOCK);
        let stop_worker = stop.try_clone().unwrap();
        let (tx, rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let _guard = acquire(&second, stop_worker.as_raw_fd(), listener.as_raw_fd());
            tx.send(()).unwrap();
        });
        assert!(rx.recv_timeout(Duration::from_millis(50)).is_err());
        drop(guard);
        rx.recv_timeout(Duration::from_secs(3)).unwrap();
        worker.join().unwrap();
    }

    #[test]
    fn lock_file_is_owner_write_only() {
        if unsafe { geteuid() } == 0 {
            eprintln!("skipped: lock readability test requires a non-root uid");
            return;
        }
        let path = format!("/tmp/acpmux-lock-mode-{}", std::process::id());
        let file = open_at(AT_FDCWD, &path, O_CREAT | O_EXCL | O_RDWR, 0o200).unwrap();
        let info = stat(file.as_raw_fd()).unwrap();
        assert_eq!(info.st_mode & (S_IFMT | 0o777), S_IFREG | 0o200);
        drop(file);
        assert!(matches!(open_at(AT_FDCWD, &path, O_RDONLY, 0), Err(EACCES)));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn preexisting_lock_mode_is_refused() {
        let path = format!("/tmp/acpmux-lock-preexisting-{}", std::process::id());
        let file = open_at(AT_FDCWD, &path, O_CREAT | O_EXCL | O_RDWR, 0o600).unwrap();
        let info = stat(file.as_raw_fd()).unwrap();
        assert!(!valid_lock(&info, unsafe { getuid() }));
        drop(file);
        let _ = std::fs::remove_file(path);
    }

    /// A competing daemon's flock is held until the waiting thread observes stop.
    #[test]
    fn external_flock_blocks_until_stop() {
        let (first, second) = files();
        assert_eq!(unsafe { flock(first.as_raw_fd(), LOCK_EX | LOCK_NB) }, 0);
        let stop = event();
        let listener = event();
        let stop_worker = stop.try_clone().unwrap();
        let (tx, rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let result = acquire(&second, stop_worker.as_raw_fd(), listener.as_raw_fd());
            tx.send(result.err()).unwrap();
        });
        let premature = rx.recv_timeout(Duration::from_millis(50));
        assert_eq!(unsafe { write(stop.as_raw_fd(), (&1u64 as *const u64).cast(), 8) }, 8);
        let outcome = premature
            .as_ref()
            .copied()
            .unwrap_or_else(|_| rx.recv_timeout(Duration::from_secs(3)).unwrap());
        worker.join().unwrap();
        assert!(premature.is_err(), "transaction bypassed external flock");
        assert_eq!(outcome, Some(ECANCELED));
    }
}
