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
    /// the host when it exits, with no thread of its own. Without a reaper
    /// (a caller outside a mux), or when it cannot watch the host, a
    /// `terminal-host-reaper` thread waits for it; failure to start that
    /// thread cannot turn a committed live Surface into an error, and
    /// dropping Child leaves the independent host running.
    pub(crate) fn commit(mut self, reaper: Option<&HostReaper>) {
        let Some(mut child) = self.child.take() else { return };
        let unwatched = match reaper {
            Some(reaper) => reaper.watch(child.id(), Box::new(drop)).err(),
            None => None,
        };
        if reaper.is_some() && unwatched.is_none() {
            return;
        }
        if let Some(unwatched) = unwatched {
            eprintln!("cmux-tui: the terminal host's exit has its own wait thread ({unwatched})");
        }
        let _ = cmux_threads::spawn(
            "terminal-host-reaper",
            cmux_threads::qos::ThreadQos::Utility,
            move || {
                let _ = child.wait();
            },
        );
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

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use super::*;

    /// Whether `pid` is gone for every wait (ECHILD): reaped. Only looks
    /// (WNOWAIT), never reaps.
    fn reaped(pid: libc::pid_t) -> bool {
        // SAFETY: a zeroed siginfo_t is valid output storage.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let flags = libc::WEXITED | libc::WNOHANG | libc::WNOWAIT;
        // SAFETY: waitid writes one siginfo_t, returns at once, reaps nothing.
        let waited = unsafe { libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, flags) };
        waited < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD)
    }

    /// p02-threads-237: a committed host is reaped by the mux's one child
    /// reaper once it exits, with no `terminal-host-reaper` thread.
    #[test]
    fn a_committed_host_is_reaped_by_the_mux_reaper_with_no_thread_of_its_own() {
        let work = cmux_threads::work::Work::new(cmux_threads::work::WorkConfig {
            label: "thrpw".to_owned(),
            ..cmux_threads::work::WorkConfig::default()
        })
        .unwrap();
        let reaper = HostReaper::new("thrp", Arc::new(work)).unwrap();
        let child = cmux_process::Command::new("/bin/sh")
            .args(["-c", "exec sleep 30"])
            .stdin(cmux_process::Stdio::null())
            .spawn()
            .unwrap();
        let pid = libc::pid_t::try_from(child.id()).unwrap();
        let (process, _, _) = SpawnedHostProcess::with_pipes(child);
        process.commit(Some(&reaper));
        let host_reapers = cmux_threads::snapshot()
            .iter()
            .filter(|thread| thread.name == "terminal-host-reaper")
            .count();
        assert_eq!(host_reapers, 0, "the committed host got a wait thread of its own");
        assert_eq!(reaper.stats().watching, 1, "the mux reaper does not watch the host");
        assert!(!reaped(pid), "the committed host was killed or reaped at commit");

        // SAFETY: kill(2) takes no pointers; `pid` is an unreaped child.
        assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0);
        let deadline = Instant::now() + Duration::from_secs(20);
        let (_never, tick) = std::sync::mpsc::channel::<()>();
        while !reaped(pid) {
            assert!(Instant::now() < deadline, "the committed host was never reaped");
            let _ = tick.recv_timeout(Duration::from_millis(10));
        }
        assert_eq!(reaper.stats().exits, 1);
    }
}
