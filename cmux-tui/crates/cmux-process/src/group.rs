//! Children that die with this process: a process group led by a watchdog
//! that kills the whole group the moment this process is gone.
//!
//! The watchdog is a `/bin/sh` that ignores SIGHUP, SIGINT and SIGTERM and
//! blocks reading a pipe whose only write end this process holds
//! (close-on-exec, and on macOS every spawn of this crate passes no
//! descriptor by accident). However this process ends (an exit, a panic,
//! SIGKILL, a crash), the kernel closes that end, the read returns at end of
//! file, and the watchdog sends SIGKILL to its group: every child and
//! grandchild that stayed in it. The watchdog starts before the child and
//! leads the group, so there is no moment when the child runs and nothing
//! would end it: a parent that dies before the child's spawn leaves no child,
//! one that dies after leaves a child in a group the watchdog kills.
//!
//! Why not `PR_SET_PDEATHSIG` (Linux only): it signals the direct child
//! alone, never a grandchild, and it fires when the *thread* that spawned
//! the child exits, not the process (a tokio blocking-pool thread exits
//! after ten idle seconds, which would kill a healthy child). macOS has no
//! parent-death signal at all, and a kqueue `NOTE_EXIT` watcher would have
//! to live in another process anyway; the watchdog is that process, the
//! same on both systems.
//!
//! Limits: a child that leaves the group (`setsid`, `setpgid`, a daemon
//! that double-forks into a new session) is not followed; the leftover
//! reaper covers those after the fact. A child spawned on macOS by code that
//! does not use this crate, in the instant between this crate's `pipe` and
//! its `fcntl(FD_CLOEXEC)`, can inherit the write end and delay the
//! watchdog until that child exits. Each group costs one idle `sh` process.
//! Windows has no process groups here: [`Command::spawn_owned`] gives a
//! child killed and reaped with its handle, not one that dies with this
//! process (that needs a job object).

use std::io;
use std::time::Duration;

use crate::child::Child;
use crate::command::Command;
#[cfg(unix)]
use crate::stdio::Stdio;

/// How long [`OwnedChild`]'s drop waits after SIGTERM before SIGKILL.
pub const GRACE: Duration = Duration::from_secs(2);

/// The watchdog: ignore the signals a group or a terminal sends, wait for
/// end of file on stdin (this process gone), then kill the group (`0`: the
/// caller's own group, which it leads).
#[cfg(unix)]
const WATCHDOG: &str = "trap '' HUP INT TERM; read -r line; kill -9 0";

/// A process group that dies with this process (the module docs say how).
///
/// Put children in it with `process_group(group.id())`: this crate's
/// [`Command`], `std::process::Command` or `tokio::process::Command` (with
/// `kill_on_drop(true)`, so the child itself is killed and reaped with its
/// handle). [`Command::spawn_owned`] does it for one child and adds a
/// graceful drop.
///
/// Dropping the group sends SIGKILL to every process still in it and reaps
/// the watchdog. The group id stays reserved until then (the watchdog leads
/// it and is reaped last), so [`ChildGroup::signal`] never reaches a stranger.
#[derive(Debug)]
pub struct ChildGroup {
    #[cfg(unix)]
    watchdog: Child,
    /// The write end the watchdog waits on; closed only when this process ends
    /// (the drop kills the group itself first).
    #[cfg(unix)]
    _trigger: io::PipeWriter,
}

impl ChildGroup {
    /// Start the watchdog in a new process group.
    ///
    /// # Errors
    ///
    /// When the pipe or the watchdog cannot be made (Windows: unsupported).
    pub fn new() -> io::Result<Self> {
        #[cfg(unix)]
        {
            let (read, trigger) = io::pipe()?;
            let watchdog = Command::new("/bin/sh")
                .args(["-c", WATCHDOG])
                .env_clear()
                .stdin(Stdio::from(std::os::fd::OwnedFd::from(read)))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .process_group(0)
                .spawn()?;
            Ok(Self { watchdog, _trigger: trigger })
        }
        #[cfg(not(unix))]
        {
            Err(io::Error::new(io::ErrorKind::Unsupported, "child groups need a Unix host"))
        }
    }

    /// The process group id, for `process_group(id)`.
    pub fn id(&self) -> i32 {
        #[cfg(unix)]
        {
            self.watchdog.id() as i32
        }
        #[cfg(not(unix))]
        {
            0
        }
    }

    /// Send `signal` to every process in the group. The watchdog ignores
    /// SIGHUP, SIGINT and SIGTERM; SIGKILL ends it too (the drop still reaps it).
    pub fn signal(&self, signal: i32) -> io::Result<()> {
        #[cfg(unix)]
        {
            // SAFETY: a negative pid signals the group this value leads; its
            // leader is not reaped before the drop, so the id is still ours.
            if unsafe { libc::kill(-self.id(), signal) } != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }
        #[cfg(not(unix))]
        {
            let _ = signal;
            Err(io::Error::new(io::ErrorKind::Unsupported, "child groups need a Unix host"))
        }
    }
}

impl Drop for ChildGroup {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            let _ = self.signal(libc::SIGKILL);
            let _ = self.watchdog.wait();
        }
    }
}

/// A child in its own [`ChildGroup`]: it and every process it starts in its
/// group die with this process, and with this value.
///
/// Dropping it sends SIGTERM to the group, waits up to [`GRACE`] for the
/// child to end (an event, not a poll), then sends SIGKILL to whatever is
/// left and reaps the child and the watchdog: nothing outlives the drop and
/// no zombie stays. Derefs to [`Child`] for its streams, id and waits.
#[derive(Debug)]
pub struct OwnedChild {
    child: Child,
    /// `None` on Windows (no groups).
    group: Option<ChildGroup>,
}

impl OwnedChild {
    /// The child's process group id (not its pid: the watchdog leads it).
    pub fn group_id(&self) -> i32 {
        self.group.as_ref().map_or(0, ChildGroup::id)
    }

    /// Send `signal` to the child's whole group.
    pub fn signal_group(&self, signal: i32) -> io::Result<()> {
        match &self.group {
            Some(group) => group.signal(signal),
            None => Err(io::Error::new(io::ErrorKind::Unsupported, "no process group")),
        }
    }

    /// SIGTERM to the group, at most `grace` for the child to end, SIGKILL
    /// to the group, then reap the child. The drop runs it with [`GRACE`].
    pub fn shutdown(&mut self, grace: Duration) {
        #[cfg(unix)]
        if let Some(group) = &self.group {
            if matches!(self.child.try_wait(), Ok(None)) {
                let _ = group.signal(libc::SIGTERM);
                let _ = self.child.wait_timeout(grace);
            }
            let _ = group.signal(libc::SIGKILL);
        }
        #[cfg(not(unix))]
        let _ = (grace, self.child.kill());
        let _ = self.child.wait();
    }
}

impl std::ops::Deref for OwnedChild {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.child
    }
}

impl std::ops::DerefMut for OwnedChild {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.child
    }
}

impl Drop for OwnedChild {
    fn drop(&mut self) {
        self.shutdown(GRACE);
    }
}

impl Command {
    /// Start the child in a new [`ChildGroup`], so it and its descendants
    /// die with this process (even by SIGKILL) and with the returned value
    /// (Windows: with the returned value only).
    /// Replaces an earlier [`Command::process_group`].
    ///
    /// # Errors
    ///
    /// The spawn's, the watchdog's, or `InvalidInput` with
    /// [`Command::new_session`] (a new session leaves the group).
    pub fn spawn_owned(&mut self) -> io::Result<OwnedChild> {
        if self.new_session {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "spawn_owned: a new session would leave the child's group",
            ));
        }
        #[cfg(unix)]
        {
            let group = ChildGroup::new()?;
            self.process_group = Some(group.id());
            let child = self.spawn()?;
            Ok(OwnedChild { child, group: Some(group) })
        }
        #[cfg(not(unix))]
        {
            Ok(OwnedChild { child: self.spawn()?, group: None })
        }
    }
}
