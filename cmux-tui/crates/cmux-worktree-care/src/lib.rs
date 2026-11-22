//! Machines that clean up after their agents. Every agent session leaves a
//! git worktree behind, with its build output (`node_modules`, `target/`,
//! DerivedData), and a machine that runs many fills its disk with them. This
//! crate is the one place that decides what may go and makes it go without
//! losing anything:
//!
//! - [`inventory`]: every linked worktree of the repositories under the
//!   given folders, and its facts (branch, HEAD, changes, unpushed commits,
//!   last activity, bytes, ignored build output).
//! - [`policy`]: a verdict per worktree from those facts, the sessions that
//!   use it, the programs registered as working in it and how full its disk is: kept (in use,
//!   recent, or unsafe to archive) or reclaimed (finished, idle and pushed,
//!   idle with work to archive).
//! - [`archive`]: the worktree's work kept inside git before it goes: one
//!   commit of its index and one of its files (tracked changes, untracked
//!   files and the ignored files that are not build output), published as
//!   `refs/cmux/archive/<id>`, copied into a bundle, and described by a
//!   manifest in the archive store. Then the folder goes.
//! - [`restore`]: the worktree back from its manifest, files, index and
//!   sparse patterns as they were.
//!
//! Nothing here runs on its own: a caller (the `acpmux worktree` command,
//! the acpmux daemon on its events) gathers the sessions and runs a pass.
//! Every git run is bounded and confined by `cmux-git`: no hook, filter,
//! fsmonitor or transport from the repository runs.

pub mod archive;
pub mod disk;
mod finished_memo;
mod git;
pub mod inventory;
pub mod pass;
pub mod policy;
pub mod procs;
pub mod restore;
pub mod schedule;
pub mod store;

pub use inventory::{Facts, Repo, Worktree};
pub use policy::{Action, Pressure, Verdict};
pub use store::{Manifest, Store};

/// Test-only: a forked child that keeps a copy of every descriptor of this process, the way a
/// child another daemon thread forks keeps them until it execs. A file lock that is let go only
/// by a close stays held through such a copy.
#[cfg(all(test, unix))]
pub(crate) mod test_fork {
    /// The child; dropping this kills and reaps it.
    ///
    /// Fork safety: a test binary runs many threads, so the child of `fork` may make only
    /// async-signal-safe calls. It calls `pause` in a loop and nothing else: it never returns from
    /// [`Keeper::fork`], allocates, takes a lock, unwinds or calls `_exit` or `exit` itself. The
    /// parent's drop ends it with SIGKILL (from outside the child) and reaps it with `waitpid`.
    pub(crate) struct Keeper(libc::pid_t);

    impl Keeper {
        pub(crate) fn fork() -> Keeper {
            // SAFETY: the child calls only pause, which is async-signal-safe, until SIGKILL ends it.
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
}
