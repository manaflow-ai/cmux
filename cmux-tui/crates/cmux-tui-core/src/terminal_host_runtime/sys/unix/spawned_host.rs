//! Launch-time ownership of a terminal-host process (cx-ko2e
//! `SpawnedHostProcess` seam, Unix side): the child of the host the daemon
//! started (`cmux_process`), exact-killed and waited if the launch is not
//! committed.

use std::time::Duration;

/// What reaps a committed host: the mux's one child reaper.
pub(crate) type HostReaper = cmux_threads::reaper::Reaper;

pub(crate) struct SpawnedHostProcess {
    pub(crate) child: Option<cmux_process::Child>,
}

impl SpawnedHostProcess {
    /// Wrap a just-spawned host, taking its bootstrap pipes first. Missing
    /// pipes are an error after the wrap, so the host is killed and waited.
    pub(crate) fn with_pipes(
        mut child: cmux_process::Child,
    ) -> (Self, Option<std::process::ChildStdin>, Option<std::process::ChildStdout>) {
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        (Self { child: Some(child) }, stdin, stdout)
    }

    /// False once the process has exited (killed, or crashed before use).
    pub(crate) fn is_alive(&mut self) -> bool {
        self.child.as_mut().is_some_and(|child| matches!(child.try_wait(), Ok(None)))
    }

    /// The launch is committed: the host lives on its own. Reaping is
    /// housekeeping after the ownership handoff: the mux's `reaper` reaps
    /// the host when it exits, with no thread of its own. Dropping Child
    /// leaves the independent host running; with no reaper (the mux is gone,
    /// or a caller outside a mux) its exit stays unreaped until this process
    /// ends.
    pub(crate) fn commit(mut self, reaper: Option<&HostReaper>) {
        let Some(child) = self.child.take() else { return };
        if let Some(reaper) = reaper {
            reaper.watch(child.id(), Box::new(drop));
        }
    }

    /// Unix hosts leave the daemon's session and scope, never its job.
    pub(crate) fn ends_with_daemon_job(&self) -> bool {
        false
    }

    /// Whether the host ended within `timeout` (an exit event, not a poll).
    pub(crate) fn wait_timeout(&mut self, timeout: Duration) -> bool {
        let Some(child) = self.child.as_mut() else { return true };
        // wakeup-allow: deadline the caller's one bound on the host's exit; the exit ends the wait first
        match child.wait_timeout(timeout) {
            Ok(Some(_)) => {
                self.child.take();
                true
            }
            Ok(None) | Err(_) => false,
        }
    }
}

impl Drop for SpawnedHostProcess {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
