//! Exits of the children a holder did not start: the shells it adopted
//! from a holder that died. Their parent is gone (launchd or init reaps
//! them), so no SIGCHLD reaches this holder. The kernel reports their exit
//! on a kqueue (`EVFILT_PROC`, `NOTE_EXIT`) whose descriptor sits in the
//! holder's poll set, so an adopted terminal ends when its child does, as a
//! started one does (terminal-host-model-DESIGN.md section 4).
//!
//! Linux has nothing to watch: a terminal there ends at the master's end of
//! file only, started or adopted (`holder::ENDS_ON_CHILD_EXIT`).

#[cfg(not(target_os = "linux"))]
use std::io;
use std::os::fd::RawFd;
#[cfg(not(target_os = "linux"))]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

/// What [`ExitWatch::watch`] found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Watch {
    /// [`ExitWatch::exited`] reports the child's exit, or (Linux) its end
    /// needs no report.
    Watching,
    /// The child is gone already: its terminal ends now.
    Exited,
}

/// The kqueue of adopted children's exits.
#[cfg(not(target_os = "linux"))]
pub(crate) struct ExitWatch {
    queue: OwnedFd,
}

#[cfg(not(target_os = "linux"))]
impl ExitWatch {
    pub(crate) fn new() -> io::Result<Self> {
        // SAFETY: kqueue takes no arguments and returns a new descriptor or -1.
        let fd = unsafe { libc::kqueue() };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        crate::pty::set_cloexec(fd);
        // SAFETY: kqueue returned a fresh descriptor this value owns.
        Ok(Self { queue: unsafe { OwnedFd::from_raw_fd(fd) } })
    }

    /// The descriptor to poll for `POLLIN`: readable while an exit waits.
    pub(crate) fn fd(&self) -> Option<RawFd> {
        Some(self.queue.as_raw_fd())
    }

    /// Report `pid`'s exit through [`Self::exited`]. A kqueue that cannot
    /// take the watch (out of kernel memory, the only other failure for a
    /// process of this user) leaves the terminal to end at its master's
    /// end of file, as before the watch existed.
    pub(crate) fn watch(&self, pid: libc::pid_t) -> Watch {
        if pid <= 0 {
            return Watch::Watching;
        }
        // SAFETY: a zeroed kevent is a valid change record; the fields set
        // below are the ones the kernel reads for EVFILT_PROC.
        let mut change: libc::kevent = unsafe { std::mem::zeroed() };
        change.ident = pid as libc::uintptr_t;
        change.filter = libc::EVFILT_PROC;
        change.flags = libc::EV_ADD | libc::EV_ONESHOT;
        change.fflags = libc::NOTE_EXIT;
        loop {
            // SAFETY: one live change record, no event list, no timeout.
            let added = unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    &change,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                )
            };
            if added >= 0 {
                return Watch::Watching;
            }
            match io::Error::last_os_error().raw_os_error() {
                Some(libc::EINTR) => {}
                Some(libc::ESRCH) => return Watch::Exited,
                _ => return Watch::Watching,
            }
        }
    }

    /// The pids whose exit the kernel reported since the last call. Never
    /// waits.
    pub(crate) fn exited(&self) -> Vec<libc::pid_t> {
        const BATCH: usize = 16;
        // SAFETY: zeroed kevents are valid out-records.
        let mut events: [libc::kevent; BATCH] = unsafe { std::mem::zeroed() };
        let now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        let mut pids = Vec::new();
        loop {
            // SAFETY: no changes; `events` is a live array of BATCH records;
            // a zero timeout returns at once.
            let n = unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    events.as_mut_ptr(),
                    BATCH as libc::c_int,
                    &now,
                )
            };
            if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            let n = usize::try_from(n).unwrap_or(0);
            pids.extend(
                events[..n]
                    .iter()
                    .filter(|event| {
                        event.filter == libc::EVFILT_PROC && event.fflags & libc::NOTE_EXIT != 0
                    })
                    .map(|event| event.ident as libc::pid_t),
            );
            if n < BATCH {
                return pids;
            }
        }
    }
}

/// Linux: nothing to watch ([module docs](self)).
#[cfg(target_os = "linux")]
pub(crate) struct ExitWatch;

#[cfg(target_os = "linux")]
impl ExitWatch {
    pub(crate) fn new() -> std::io::Result<Self> {
        Ok(Self)
    }

    pub(crate) fn fd(&self) -> Option<RawFd> {
        None
    }

    pub(crate) fn watch(&self, _pid: libc::pid_t) -> Watch {
        Watch::Watching
    }

    pub(crate) fn exited(&self) -> Vec<libc::pid_t> {
        Vec::new()
    }
}
