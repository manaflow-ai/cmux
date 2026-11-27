//! `kill` and `sigstop`: signals to a process by its recorded pid, never by name or pattern.
//!
//! A [`Recorded`] is made only from a child the scenario spawned itself (or a pid that child
//! wrote, through [`Recorded::from_pid_file`]), so the harness never signals a process it did not
//! start. A frozen process is thawed when its `Recorded` drops, so a failing run never leaves a
//! stopped process behind.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::trace::Trace;

pub struct Recorded {
    pid: libc::pid_t,
    what: String,
    stopped: AtomicBool,
    trace: Trace,
}

impl Recorded {
    /// The child this scenario spawned.
    pub fn child(child: &std::process::Child, what: impl Into<String>, trace: &Trace) -> Self {
        Self::new(child.id() as libc::pid_t, what.into(), trace)
    }

    /// A pid a process this scenario started wrote to `path` (a daemon's pid file in the
    /// scenario's own temp home).
    pub fn from_pid_file(path: &Path, what: impl Into<String>, trace: &Trace) -> Option<Self> {
        let pid: libc::pid_t = std::fs::read_to_string(path).ok()?.trim().parse().ok()?;
        Some(Self::new(pid, what.into(), trace))
    }

    fn new(pid: libc::pid_t, what: String, trace: &Trace) -> Self {
        assert!(pid > 1, "refusing to record pid {pid} for {what}");
        Self { pid, what, stopped: AtomicBool::new(false), trace: trace.clone() }
    }

    pub fn pid(&self) -> libc::pid_t {
        self.pid
    }

    /// Whether the process still exists (a zombie the scenario has not reaped counts).
    pub fn alive(&self) -> bool {
        // SAFETY: signal 0 only checks that the recorded pid exists.
        unsafe { libc::kill(self.pid, 0) == 0 }
    }

    fn signal(&self, signal: libc::c_int, name: &str) -> bool {
        self.trace.note(format!("fault {name} {} (pid {})", self.what, self.pid));
        // SAFETY: a pid this scenario started (see the constructors).
        unsafe { libc::kill(self.pid, signal) == 0 }
    }

    /// `kill`: SIGKILL.
    pub fn kill(&self) -> bool {
        self.signal(libc::SIGKILL, "kill")
    }

    /// `sigstop`: frozen until [`Self::resume`] or drop.
    pub fn freeze(&self) -> bool {
        self.stopped.store(true, Ordering::SeqCst);
        self.signal(libc::SIGSTOP, "sigstop")
    }

    pub fn resume(&self) -> bool {
        self.stopped.store(false, Ordering::SeqCst);
        self.signal(libc::SIGCONT, "sigcont")
    }
}

impl Drop for Recorded {
    fn drop(&mut self) {
        if self.stopped.load(Ordering::SeqCst) {
            // SAFETY: as in `signal`.
            unsafe { libc::kill(self.pid, libc::SIGCONT) };
        }
    }
}

#[cfg(test)]
#[path = "process_tests.rs"]
mod tests;
