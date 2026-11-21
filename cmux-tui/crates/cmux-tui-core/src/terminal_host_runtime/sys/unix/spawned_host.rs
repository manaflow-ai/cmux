//! Launch-time ownership of a terminal-host process (cx-ko2e
//! `SpawnedHostProcess` seam, Unix side): the std child of the host the
//! daemon started, exact-killed and waited if the launch is not committed.
//! Moved from `shared/attachment.rs` unchanged.

use std::thread;
use std::time::{Duration, Instant};

pub(crate) struct SpawnedHostProcess {
    pub(crate) child: Option<std::process::Child>,
}

impl SpawnedHostProcess {
    /// Wrap a just-spawned host, taking its bootstrap pipes first. Missing
    /// pipes are an error after the wrap, so the host is killed and waited.
    pub(crate) fn with_pipes(
        mut child: std::process::Child,
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
    /// housekeeping after the ownership handoff, done by the shared reaper
    /// (`host_reaper.rs`), not a thread per host. A failure there cannot
    /// turn a committed live Surface into an error; dropping Child leaves
    /// the independent host running.
    pub(crate) fn commit(mut self) {
        let Some(child) = self.child.take() else { return };
        super::host_reaper::reap_when_exited(child);
    }

    /// Unix hosts leave the daemon's session and scope, never its job.
    pub(crate) fn ends_with_daemon_job(&self) -> bool {
        false
    }

    pub(crate) fn wait_timeout(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now().checked_add(timeout);
        loop {
            let Some(child) = self.child.as_mut() else { return true };
            match child.try_wait() {
                Ok(Some(_)) => {
                    self.child.take();
                    return true;
                }
                Ok(None) if deadline.is_none_or(|deadline| Instant::now() < deadline) => {
                    thread::sleep(Duration::from_millis(10));
                }
                Ok(None) | Err(_) => return false,
            }
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
