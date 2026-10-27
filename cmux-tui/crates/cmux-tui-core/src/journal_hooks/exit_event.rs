//! The hook leader's exit as a descriptor, so writing the hook's stdin waits
//! for room in the pipe and for the exit together: a descendant that keeps
//! the pipe open after the hook exited never reads it, and shutdown ends a
//! hook by ending its group. Linux: a pidfd (readable at exit). macOS: a
//! kqueue holding `EVFILT_PROC` `NOTE_EXIT`, as Chrome waits for a child in
//! `base/process/kill_mac.cc`.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::Instant;

/// The exit of one hook leader.
pub(super) enum HookExit {
    /// Readable once the leader exited.
    Descriptor(OwnedFd),
    /// The leader had exited before kqueue could observe it (macOS ESRCH).
    #[cfg(target_os = "macos")]
    Exited,
    /// No exit descriptor on this platform: the write waits for room, its
    /// reader's end or the deadline.
    Unobserved,
}

impl HookExit {
    /// Observe the exit of `pid`, an unreaped child of this process.
    pub(super) fn observe(pid: u32) -> io::Result<Self> {
        let pid = libc::pid_t::try_from(pid)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "hook pid out of range"))?;
        observe_pid(pid)
    }
}

#[cfg(target_os = "linux")]
fn observe_pid(pid: libc::pid_t) -> io::Result<HookExit> {
    // SAFETY: pidfd_open takes plain values and returns a new descriptor or -1.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let fd = RawFd::try_from(fd).map_err(|_| io::Error::other("pidfd out of range"))?;
    // SAFETY: the kernel just returned `fd`; nothing else owns it.
    Ok(HookExit::Descriptor(unsafe { OwnedFd::from_raw_fd(fd) }))
}

#[cfg(target_os = "macos")]
fn observe_pid(pid: libc::pid_t) -> io::Result<HookExit> {
    // SAFETY: kqueue takes no arguments and returns a new descriptor or -1.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the kernel just returned `queue`; nothing else owns it.
    let queue = unsafe { OwnedFd::from_raw_fd(queue) };
    let change = libc::kevent {
        ident: pid as libc::uintptr_t,
        filter: libc::EVFILT_PROC,
        flags: libc::EV_ADD | libc::EV_ONESHOT,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    // A registration only: no event list, so the call does not wait.
    // SAFETY: one valid change, no event buffer, a null timeout.
    let registered = unsafe {
        libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
    };
    if registered < 0 {
        let error = io::Error::last_os_error();
        return match error.raw_os_error() {
            Some(libc::ESRCH) => Ok(HookExit::Exited),
            _ => Err(error),
        };
    }
    Ok(HookExit::Descriptor(queue))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn observe_pid(_pid: libc::pid_t) -> io::Result<HookExit> {
    Ok(HookExit::Unobserved)
}

/// What ended a [`wait_stdin_or_exit`].
#[derive(Debug, PartialEq, Eq)]
pub(super) enum StdinWait {
    /// The pipe has room, its reader is gone, or the deadline passed.
    Ready,
    LeaderExited,
}

/// Waits until `stdin` has room or lost its reader, the leader exits, or
/// `deadline`.
pub(super) fn wait_stdin_or_exit(
    stdin: RawFd,
    exit: &HookExit,
    deadline: Instant,
) -> io::Result<StdinWait> {
    let exit_fd = match exit {
        #[cfg(target_os = "macos")]
        HookExit::Exited => return Ok(StdinWait::LeaderExited),
        HookExit::Descriptor(fd) => fd.as_raw_fd(),
        HookExit::Unobserved => -1,
    };
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        // Rounded up so the wait does not end before the deadline.
        let poll_ms = i32::try_from(remaining.as_nanos().div_ceil(1_000_000)).unwrap_or(i32::MAX);
        // A negative fd is skipped by poll.
        let mut fds = [
            libc::pollfd { fd: stdin, events: libc::POLLOUT, revents: 0 },
            libc::pollfd { fd: exit_fd, events: libc::POLLIN, revents: 0 },
        ];
        // wakeup-allow: deadline the hook's one execution deadline; room in the pipe, its reader's
        // end or the leader's exit (also how shutdown ends a hook) ends the poll first
        // SAFETY: `fds` is a valid, exclusively borrowed array of two pollfds.
        let result = unsafe { libc::poll(fds.as_mut_ptr(), 2, poll_ms) };
        if result >= 0 {
            return Ok(if fds[1].revents != 0 {
                StdinWait::LeaderExited
            } else {
                StdinWait::Ready
            });
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests {
    use std::time::Duration;

    use cmux_process::Stdio;

    use super::*;

    /// A full pipe whose reader stays open (a lingering descendant's, here
    /// the test's) never gets room: the leader's exit, not the deadline,
    /// ends the one wait.
    #[test]
    fn the_leader_exit_ends_a_wait_on_a_full_pipe() {
        let mut ends = [0; 2];
        // SAFETY: `ends` is a valid array of two descriptors for pipe to fill.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: pipe just returned both descriptors; each has one owner.
        let (reader, writer) =
            unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
        // SAFETY: `writer` is live; F_SETFL sets O_NONBLOCK on it only.
        assert_eq!(unsafe { libc::fcntl(writer.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) }, 0);
        let chunk = [0_u8; 4096];
        // SAFETY: `chunk` outlives each call and its length is passed.
        while unsafe { libc::write(writer.as_raw_fd(), chunk.as_ptr().cast(), chunk.len()) } > 0 {}
        let mut child = cmux_process::Command::new("/bin/sleep")
            .arg("0.2")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let exit = HookExit::observe(child.id()).unwrap();
        let started = Instant::now();

        let wait = wait_stdin_or_exit(writer.as_raw_fd(), &exit, started + Duration::from_secs(20));

        assert_eq!(wait.unwrap(), StdinWait::LeaderExited);
        assert!(started.elapsed() < Duration::from_secs(10));
        let _ = child.wait();
        drop(reader);
    }
}
