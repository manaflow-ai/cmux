//! Waiting for another process to exit, by an exit event (kqueue
//! `NOTE_EXIT` on macOS, a pidfd on Linux), never by polling. `cmux link
//! stop` uses it so a stopped link is really gone before `ensure` starts
//! the next one.

use std::io;
use std::time::Duration;

/// Waits until `pid` exits, at most `budget`: true when it exited (or was
/// already gone), false when it still runs after `budget`.
pub(super) fn wait_exit(pid: libc::pid_t, budget: Duration) -> io::Result<bool> {
    imp::wait_exit(pid, budget)
}

fn gone(error: &io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESRCH)
}

#[cfg(target_os = "macos")]
mod imp {
    use std::io;
    use std::os::fd::{FromRawFd as _, OwnedFd};
    use std::time::{Duration, Instant};

    pub(super) fn wait_exit(pid: libc::pid_t, budget: Duration) -> io::Result<bool> {
        // SAFETY: kqueue has no preconditions.
        let raw = unsafe { libc::kqueue() };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `raw` is a new descriptor this function owns.
        let queue = unsafe { OwnedFd::from_raw_fd(raw) };
        // SAFETY: kevent is plain data; all-zero is a valid value.
        let mut change: libc::kevent = unsafe { std::mem::zeroed() };
        change.ident = pid as usize;
        change.filter = libc::EVFILT_PROC;
        change.flags = libc::EV_ADD | libc::EV_ONESHOT;
        change.fflags = libc::NOTE_EXIT;
        // SAFETY: as above.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        let deadline = Instant::now() + budget;
        loop {
            // A signal (EINTR) restarts the wait with what is left of the budget.
            let left = deadline.saturating_duration_since(Instant::now());
            let timeout = libc::timespec {
                tv_sec: left.as_secs() as libc::time_t,
                tv_nsec: left.subsec_nanos() as libc::c_long,
            };
            // wakeup-allow: deadline the caller's one budget; the NOTE_EXIT event ends it first
            // SAFETY: one change and one event slot, both valid for the call.
            let n = unsafe {
                libc::kevent(
                    std::os::fd::AsRawFd::as_raw_fd(&queue),
                    &change,
                    1,
                    &mut event,
                    1,
                    &timeout,
                )
            };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                // ESRCH: the process was gone before the watch was added.
                return if super::gone(&error) { Ok(true) } else { Err(error) };
            }
            if n > 0 && event.flags & libc::EV_ERROR != 0 {
                let error = io::Error::from_raw_os_error(event.data as i32);
                return if super::gone(&error) { Ok(true) } else { Err(error) };
            }
            return Ok(n > 0);
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod imp {
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
    use std::time::{Duration, Instant};

    pub(super) fn wait_exit(pid: libc::pid_t, budget: Duration) -> io::Result<bool> {
        // SAFETY: pidfd_open takes a pid and flags 0.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if raw < 0 {
            let error = io::Error::last_os_error();
            return if super::gone(&error) { Ok(true) } else { Err(error) };
        }
        // SAFETY: `raw` is a new descriptor this function owns.
        let fd = unsafe { OwnedFd::from_raw_fd(raw as i32) };
        let mut poll = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let deadline = Instant::now() + budget;
        loop {
            // A signal (EINTR) restarts the wait with what is left of the budget,
            // rounded up so the wait never ends before it.
            let left = deadline.saturating_duration_since(Instant::now());
            let millis = i32::try_from(left.as_nanos().div_ceil(1_000_000)).unwrap_or(i32::MAX);
            // wakeup-allow: deadline the caller's one budget; the pidfd's exit readiness ends it first
            // SAFETY: one pollfd, valid for the call.
            let n = unsafe { libc::poll(&mut poll, 1, millis) };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            // The pidfd is readable once the process has exited.
            return Ok(n > 0);
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "android")))]
mod imp {
    use std::io;
    use std::time::Duration;

    /// No exit event here: the process is gone only when signal 0 says so.
    pub(super) fn wait_exit(pid: libc::pid_t, _budget: Duration) -> io::Result<bool> {
        // SAFETY: signal 0 only checks that the process exists.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return Ok(false);
        }
        let error = io::Error::last_os_error();
        if super::gone(&error) { Ok(true) } else { Err(error) }
    }
}
