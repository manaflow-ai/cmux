//! A spawned child's exit as an event, so the reaper waits for it instead of
//! re-checking on a period: kqueue `EVFILT_PROC` `NOTE_EXIT` on macOS and a
//! pidfd on Linux, both registered with the tokio reactor. Chromium waits for
//! a process the same way (base/process/kill_mac.cc `WaitForChildToDie`, a
//! kqueue `NOTE_EXIT`; base/process/process_posix.cc
//! `WaitForSingleNonChildProcess`).
//!
//! The SIGCHLD stream the caller made before the spawn stays as the second
//! source: it is the only one where no per-child event can be opened (a
//! Linux without `pidfd_open`, or a seccomp profile that denies it), and it
//! stays armed once the exit event has fired. Either one only says "check
//! now"; the caller reaps with a non-blocking wait after it.

use std::io;
use std::os::fd::{FromRawFd, OwnedFd};

use tokio::io::unix::AsyncFd;
use tokio::signal::unix::Signal;

pub(super) struct ChildExit {
    event: ExitEvent,
    sigchld: Signal,
}

enum ExitEvent {
    /// Readable once the child has exited (a pidfd, or a kqueue that holds
    /// the child's `NOTE_EXIT`).
    Armed(AsyncFd<OwnedFd>),
    /// The registration found the child already exited: the next wait
    /// returns at once.
    Exited,
    /// Fired once, or none could be opened: SIGCHLD alone.
    None,
}

impl ChildExit {
    /// Watch `pid`, a child of this process that has not been reaped.
    /// `sigchld` must have been made before the spawn, so no SIGCHLD of the
    /// child is lost.
    pub(super) fn watch(pid: Option<u32>, sigchld: Signal) -> Self {
        let event = match pid.and_then(|pid| libc::pid_t::try_from(pid).ok()) {
            Some(pid) => match open_exit_event(pid) {
                Ok(Some(fd)) => AsyncFd::new(fd).map_or(ExitEvent::None, ExitEvent::Armed),
                Ok(None) => ExitEvent::Exited,
                Err(_) => ExitEvent::None,
            },
            None => ExitEvent::None,
        };
        Self { event, sigchld }
    }

    #[cfg(test)]
    pub(super) fn sigchld_only(sigchld: Signal) -> Self {
        Self { event: ExitEvent::None, sigchld }
    }

    #[cfg(test)]
    pub(super) fn has_exit_event(&self) -> bool {
        !matches!(self.event, ExitEvent::None)
    }

    /// Returns when the child may have exited: its exit event, or any
    /// SIGCHLD. Both are events; nothing here is timed.
    pub(super) async fn wait(&mut self) -> io::Result<()> {
        let fired = match &self.event {
            ExitEvent::Exited => true,
            ExitEvent::Armed(fd) => tokio::select! {
                ready = fd.readable() => {
                    drop(ready?);
                    true
                }
                signal = self.sigchld.recv() => {
                    signal.ok_or_else(sigchld_closed)?;
                    false
                }
            },
            ExitEvent::None => {
                self.sigchld.recv().await.ok_or_else(sigchld_closed)?;
                false
            }
        };
        if fired {
            // The exit is level-triggered: once seen, waiting on it again
            // would return at once forever.
            self.event = ExitEvent::None;
        }
        Ok(())
    }
}

fn sigchld_closed() -> io::Error {
    io::Error::other("SIGCHLD listener closed before the child exited")
}

/// A pidfd: readable once the process has exited (zombies included).
/// `Ok(None)` is never returned on Linux: `pidfd_open` succeeds for a zombie.
#[cfg(target_os = "linux")]
fn open_exit_event(pid: libc::pid_t) -> io::Result<Option<OwnedFd>> {
    // SAFETY: pidfd_open returns a new descriptor or -1.
    let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let raw = libc::c_int::try_from(raw).map_err(|_| io::Error::other("pidfd out of range"))?;
    // SAFETY: a new descriptor this function owns.
    Ok(Some(unsafe { OwnedFd::from_raw_fd(raw) }))
}

/// A kqueue holding the child's `NOTE_EXIT`; the kqueue descriptor turns
/// readable when the event is pending. A child that exited before the
/// registration (a zombie) makes `EV_ADD` fail with ESRCH: `Ok(None)`.
#[cfg(target_vendor = "apple")]
fn open_exit_event(pid: libc::pid_t) -> io::Result<Option<OwnedFd>> {
    // SAFETY: kqueue returns a new descriptor or -1.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a new descriptor this function owns.
    let queue = unsafe { OwnedFd::from_raw_fd(queue) };
    let change = libc::kevent {
        ident: pid as libc::uintptr_t,
        filter: libc::EVFILT_PROC,
        flags: libc::EV_ADD | libc::EV_ONESHOT,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    loop {
        // SAFETY: one change in, no event out; with no event out the call
        // only registers and does not wait.
        let registered = unsafe {
            libc::kevent(
                std::os::fd::AsRawFd::as_raw_fd(&queue),
                &raw const change,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        };
        if registered >= 0 {
            return Ok(Some(queue));
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::ESRCH) => return Ok(None),
            Some(libc::EINTR) => {}
            _ => return Err(error),
        }
    }
}

#[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
fn open_exit_event(_pid: libc::pid_t) -> io::Result<Option<OwnedFd>> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "no per-child exit event"))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use tokio::signal::unix::{SignalKind, signal};

    use super::ChildExit;

    fn sigchld() -> tokio::signal::unix::Signal {
        signal(SignalKind::child()).unwrap()
    }

    /// A stream nothing sends in these tests: the exit event alone can end
    /// the wait (other tests' children raise SIGCHLD in this process).
    fn silent() -> tokio::signal::unix::Signal {
        signal(SignalKind::user_defined2()).unwrap()
    }

    /// A running child: the wait does not return (no period wakes it); its
    /// exit ends the wait at once and the reap finds the status.
    #[tokio::test]
    async fn the_exit_event_ends_the_wait_and_nothing_before_it() {
        let events = silent();
        let mut child = tokio::process::Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let mut exit = ChildExit::watch(child.id(), events);
        assert!(exit.has_exit_event(), "a per-child exit event is open");
        let early = tokio::time::timeout(Duration::from_millis(300), exit.wait()).await;
        assert!(early.is_err(), "the wait returned while the child ran");
        assert!(child.try_wait().unwrap().is_none());
        child.start_kill().unwrap();
        tokio::time::timeout(Duration::from_secs(10), exit.wait())
            .await
            .expect("the exit did not end the wait")
            .unwrap();
        assert!(child.try_wait().unwrap().is_some(), "the exit event fired before the status");
    }

    /// A child that exited before the watch: the first wait returns at once.
    #[tokio::test]
    async fn a_child_that_already_exited_is_seen_at_once() {
        let events = silent();
        let mut child =
            tokio::process::Command::new("/bin/sh").args(["-c", "exit 3"]).spawn().unwrap();
        let pid = child.id();
        // Make it a zombie without reaping it: waitid(WNOWAIT).
        let raw_pid = libc::id_t::try_from(pid.unwrap()).unwrap();
        tokio::task::spawn_blocking(move || {
            // SAFETY: zeroed siginfo_t is valid output storage; WNOWAIT
            // leaves the child to the reap below.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            let waited = unsafe {
                libc::waitid(libc::P_PID, raw_pid, &mut info, libc::WEXITED | libc::WNOWAIT)
            };
            assert_eq!(waited, 0);
        })
        .await
        .unwrap();
        let mut exit = ChildExit::watch(pid, events);
        tokio::time::timeout(Duration::from_secs(5), exit.wait())
            .await
            .expect("an exited child's wait did not return")
            .unwrap();
        assert_eq!(child.try_wait().unwrap().and_then(|status| status.code()), Some(3));
    }

    /// No per-child event: SIGCHLD alone ends the wait.
    #[tokio::test]
    async fn sigchld_alone_ends_the_wait_where_no_exit_event_opens() {
        let mut exit = ChildExit::sigchld_only(sigchld());
        let mut child =
            tokio::process::Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
        tokio::time::timeout(Duration::from_secs(10), exit.wait())
            .await
            .expect("SIGCHLD did not end the wait")
            .unwrap();
        let mut status = child.try_wait().unwrap();
        while status.is_none() {
            exit.wait().await.unwrap();
            status = child.try_wait().unwrap();
        }
    }
}
