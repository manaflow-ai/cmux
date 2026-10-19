//! Launch-time ownership of a terminal-host process (cx-ko2e
//! `SpawnedHostProcess` seam, Unix side): the std child of the host the
//! daemon started, exact-killed and waited if the launch is not committed.
//! Moved from `shared/attachment.rs` unchanged.

use std::thread;
use std::time::{Duration, Instant};

pub(crate) struct SpawnedHostProcess {
    pub(crate) child: Option<std::process::Child>,
    /// A terminal slot on a shared host (`unix/shared_host.rs`) instead of
    /// a host process of its own.
    pub(crate) slot: Option<super::super::super::unix::SharedHostSlot>,
}

impl SpawnedHostProcess {
    /// False once the host is gone (killed, or crashed before use).
    pub(crate) fn is_alive(&mut self) -> bool {
        match (self.slot.as_ref(), self.child.as_mut()) {
            (Some(slot), _) => slot.is_open(),
            (None, Some(child)) => matches!(child.try_wait(), Ok(None)),
            (None, None) => false,
        }
    }

    pub(crate) fn child_mut(&mut self) -> &mut std::process::Child {
        self.child.as_mut().expect("terminal-host child is present")
    }

    pub(crate) fn into_child(mut self) -> std::process::Child {
        self.child.take().expect("terminal-host child is present")
    }

    /// The launch is committed: the host lives on its own. Reaping is
    /// housekeeping after the ownership handoff. Failure to create this
    /// helper cannot turn a committed live Surface into an error; dropping
    /// Child leaves the independent host running.
    pub(crate) fn commit(mut self) {
        if let Some(slot) = self.slot.take() {
            slot.commit();
            return;
        }
        let mut child = self.into_child();
        let _ = thread::Builder::new().name("terminal-host-reaper".into()).spawn(move || {
            let _ = child.wait();
        });
    }

    /// Unix hosts leave the daemon's session and scope, never its job.
    pub(crate) fn ends_with_daemon_job(&self) -> bool {
        false
    }

    pub(crate) fn wait_timeout(&mut self, timeout: Duration) -> bool {
        if let Some(slot) = self.slot.as_ref() {
            // A shared host ends only this terminal; it closes the slot
            // when the terminal is gone.
            return slot.closed_within(timeout);
        }
        let deadline = Instant::now() + timeout;
        loop {
            let Some(child) = self.child.as_mut() else { return true };
            match child.try_wait() {
                Ok(Some(_)) => {
                    self.child.take();
                    return true;
                }
                Ok(None) if Instant::now() < deadline => {
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
