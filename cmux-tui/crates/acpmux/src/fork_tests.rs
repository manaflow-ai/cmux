//! Test-only: a forked child that keeps a copy of every descriptor of this process, the way a
//! child that another daemon thread forks keeps them until it execs. A file lock that is let go
//! only by a close stays held through such a copy.

use std::os::fd::AsRawFd as _;

/// The child; dropping this kills and reaps it.
///
/// Fork safety: a test binary runs many threads, so the child of `fork` may make only
/// async-signal-safe calls. It calls `pause` in a loop and nothing else: it never returns from
/// [`Keeper::fork`], allocates, takes a lock, unwinds or calls `_exit` or `exit` itself. The
/// parent's drop ends it with SIGKILL (from outside the child) and reaps it with `waitpid`.
pub(crate) struct Keeper(libc::pid_t);

impl Keeper {
    pub(crate) fn fork() -> Keeper {
        // SAFETY: the child runs only async-signal-safe `pause` until SIGKILL ends it.
        let child = unsafe { libc::fork() };
        assert!(child >= 0, "fork failed");
        if child == 0 {
            loop {
                // SAFETY: as above.
                unsafe { libc::pause() };
            }
        }
        Keeper(child)
    }
}

impl Drop for Keeper {
    fn drop(&mut self) {
        let mut status = 0;
        // SAFETY: `self.0` is this test's own child and `status` outlives the call.
        unsafe {
            libc::kill(self.0, libc::SIGKILL);
            libc::waitpid(self.0, &mut status, 0);
        }
    }
}

/// Whether an exclusive flock on a new description of `path` is taken now; one taken is unlocked
/// before the close, so a child another test forks meanwhile keeps nothing.
pub(crate) fn free(path: &std::path::Path) -> bool {
    let file = std::fs::OpenOptions::new().read(true).open(path).unwrap();
    // SAFETY: flock on a descriptor `file` keeps open through both calls.
    unsafe {
        let taken = libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0;
        if taken {
            libc::flock(file.as_raw_fd(), libc::LOCK_UN);
        }
        taken
    }
}
