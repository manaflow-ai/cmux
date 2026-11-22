//! Test-only: a child process that keeps a copy of a lock's open file description, the way a
//! child that another thread starts keeps the parent's descriptors until it execs or exits. A
//! file lock that is let go only by a close stays held through such a copy.

use std::os::fd::BorrowedFd;

/// The child; dropping this ends and reaps it.
pub(crate) struct Keeper(std::process::Child);

impl Keeper {
    /// A child whose stdin is a copy of `fd` (the same open file description).
    pub(crate) fn keep(fd: BorrowedFd<'_>) -> Keeper {
        let copy = fd.try_clone_to_owned().unwrap();
        Keeper(std::process::Command::new("sleep").arg("60").stdin(copy).spawn().unwrap())
    }
}

impl Drop for Keeper {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Whether an exclusive lock on a new open of `path` is taken now (and let go at once).
pub(crate) fn free(path: &std::path::Path) -> bool {
    let file = std::fs::File::open(path).unwrap();
    let taken = file.try_lock().is_ok();
    if taken {
        let _ = file.unlock();
    }
    taken
}

/// A new empty folder under the system temp folder.
pub(crate) fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-remote-lock-{name}-{}-{:?}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
