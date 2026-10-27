//! Reaping a child nobody waits for.
//!
//! A child that ends before its parent stays a zombie until the parent
//! waits for it; dropping a `Child` does not wait. A caller that starts a
//! process and has no use for its exit status (an opener such as `open` or
//! `xdg-open`, a detached daemon) hands the `Child` to [`reap_in_background`],
//! which waits for it on a thread of its own. This is Chromium's
//! `base::EnsureProcessGetsReaped` (base/process/kill_posix.cc): a
//! non-joinable `BackgroundReaper` thread per child that blocks in `waitpid`.

use std::io;
use std::process::ExitStatus;

use cmux_threads::ThreadQos;

/// The name of the thread that waits for one child (15 bytes at most: the
/// Linux thread-name limit).
pub const REAPER_THREAD_NAME: &str = "child-reaper";

/// A started child a reaper can wait for.
pub trait Wait: Send + 'static {
    /// Blocks until the child ends and collects its status.
    fn wait(&mut self) -> io::Result<ExitStatus>;
}

impl Wait for std::process::Child {
    fn wait(&mut self) -> io::Result<ExitStatus> {
        std::process::Child::wait(self)
    }
}

impl Wait for crate::Child {
    fn wait(&mut self) -> io::Result<ExitStatus> {
        crate::Child::wait(self)
    }
}

/// Waits for `child` on a new thread, so it never stays a zombie, and
/// returns at once. Its stdio handles stay with the `Child` until it ends;
/// take the ones you need before handing it over.
///
/// Fails only when the thread cannot start; the child then stays unreaped
/// until this process exits.
pub fn reap_in_background(mut child: impl Wait) -> io::Result<()> {
    // supervise-allow: the reaper only blocks in waitpid for one child and ends with it; there is nothing to restart or stop (Chromium's BackgroundReaper is non-joinable too).
    cmux_threads::spawn(REAPER_THREAD_NAME, ThreadQos::Utility, move || {
        // The status is not wanted: the wait is what removes the zombie.
        let _ = child.wait();
    })
    .map(drop)
}

#[cfg(all(test, unix))]
#[path = "reap_tests.rs"]
mod tests;
