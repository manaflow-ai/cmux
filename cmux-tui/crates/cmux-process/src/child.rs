//! A started child: `std::process::Child`'s fields and methods, plus a
//! bounded wait that needs no polling.

use std::io::{self, Read};
use std::process::{ChildStderr, ChildStdin, ChildStdout, ExitStatus, Output};
use std::time::Duration;

/// A running or ended child, as `std::process::Child`.
///
/// Dropping it neither kills nor waits for the child (as std).
#[derive(Debug)]
pub struct Child {
    /// The parent end of a piped stdin.
    pub stdin: Option<ChildStdin>,
    /// The parent end of a piped stdout.
    pub stdout: Option<ChildStdout>,
    /// The parent end of a piped stderr.
    pub stderr: Option<ChildStderr>,
    inner: Inner,
    /// Linux without `pidfd_open`: the read end of a pipe whose write end
    /// closes when the child ends ([`spawn_exit_waiter`]), made by the first
    /// bounded wait.
    #[cfg(target_os = "linux")]
    exit_waiter: Option<std::os::fd::OwnedFd>,
}

#[derive(Debug)]
enum Inner {
    /// macOS: a pid this process spawned and has not reaped, or its status.
    #[cfg(target_vendor = "apple")]
    Pid { pid: libc::pid_t, status: Option<ExitStatus> },
    /// Linux and Windows: std's child, its streams moved to the fields above.
    #[cfg(not(target_vendor = "apple"))]
    Std(std::process::Child),
}

impl Child {
    #[cfg(target_vendor = "apple")]
    pub(crate) fn from_pid(
        pid: libc::pid_t,
        stdin: Option<ChildStdin>,
        stdout: Option<ChildStdout>,
        stderr: Option<ChildStderr>,
    ) -> Self {
        Self { stdin, stdout, stderr, inner: Inner::Pid { pid, status: None } }
    }

    #[cfg(not(target_vendor = "apple"))]
    pub(crate) fn from_std(mut child: std::process::Child) -> Self {
        Self {
            stdin: child.stdin.take(),
            stdout: child.stdout.take(),
            stderr: child.stderr.take(),
            inner: Inner::Std(child),
            #[cfg(target_os = "linux")]
            exit_waiter: None,
        }
    }

    /// The child's process id.
    pub fn id(&self) -> u32 {
        match &self.inner {
            #[cfg(target_vendor = "apple")]
            Inner::Pid { pid, .. } => u32::try_from(*pid).unwrap_or(0),
            #[cfg(not(target_vendor = "apple"))]
            Inner::Std(child) => child.id(),
        }
    }

    /// Send SIGKILL (Windows: terminate). A child already reaped is no error.
    pub fn kill(&mut self) -> io::Result<()> {
        match &mut self.inner {
            #[cfg(target_vendor = "apple")]
            Inner::Pid { pid, status } => {
                if status.is_some() {
                    return Ok(());
                }
                // SAFETY: a pid this process spawned and has not reaped, so
                // it cannot have been reused.
                if unsafe { libc::kill(*pid, libc::SIGKILL) } != 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            }
            #[cfg(not(target_vendor = "apple"))]
            Inner::Std(child) => child.kill(),
        }
    }

    /// Close stdin (so a child reading it sees its end), then wait for the
    /// child to end.
    pub fn wait(&mut self) -> io::Result<ExitStatus> {
        drop(self.stdin.take());
        match &mut self.inner {
            #[cfg(target_vendor = "apple")]
            Inner::Pid { pid, status } => {
                if let Some(status) = status {
                    return Ok(*status);
                }
                let ended =
                    waitpid(*pid, 0)?.ok_or_else(|| io::Error::other("waitpid: no status"))?;
                *status = Some(ended);
                Ok(ended)
            }
            #[cfg(not(target_vendor = "apple"))]
            Inner::Std(child) => child.wait(),
        }
    }

    /// The child's status if it ended, without waiting.
    pub fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        match &mut self.inner {
            #[cfg(target_vendor = "apple")]
            Inner::Pid { pid, status } => {
                if status.is_none() {
                    *status = waitpid(*pid, libc::WNOHANG)?;
                }
                Ok(*status)
            }
            #[cfg(not(target_vendor = "apple"))]
            Inner::Std(child) => child.try_wait(),
        }
    }

    /// Close stdin, read stdout and stderr to their ends (concurrently, so a
    /// child that fills one pipe cannot block on it), then wait.
    pub fn wait_with_output(mut self) -> io::Result<Output> {
        drop(self.stdin.take());
        let stderr = self.stderr.take().map(|mut stderr| {
            std::thread::spawn(move || {
                let mut bytes = Vec::new();
                stderr.read_to_end(&mut bytes).map(|_| bytes)
            })
        });
        let mut stdout = Vec::new();
        if let Some(mut pipe) = self.stdout.take() {
            pipe.read_to_end(&mut stdout)?;
        }
        let stderr = match stderr {
            Some(reader) => {
                reader.join().map_err(|_| io::Error::other("the stderr reader panicked"))??
            }
            None => Vec::new(),
        };
        let status = self.wait()?;
        Ok(Output { status, stdout, stderr })
    }

    /// Wait at most `limit` for the child to end: its status, or `None` when
    /// it still runs. The wait is an event (macOS: kqueue `EVFILT_PROC`
    /// `NOTE_EXIT`; Linux: a pidfd, or where `pidfd_open` is missing or
    /// denied a thread blocked in `waitid`), not a poll; `limit` only bounds
    /// it.
    pub fn wait_timeout(&mut self, limit: Duration) -> io::Result<Option<ExitStatus>> {
        drop(self.stdin.take());
        if let Some(status) = self.try_wait()? {
            return Ok(Some(status));
        }
        match &mut self.inner {
            #[cfg(target_vendor = "apple")]
            Inner::Pid { pid, .. } => {
                exit_event_within(*pid, limit)?;
            }
            #[cfg(target_os = "linux")]
            Inner::Std(child) => match exit_event_within(child.id(), limit) {
                Ok(()) => {}
                Err(error) if pidfd_unavailable(&error) => {
                    let waiter = match self.exit_waiter.take() {
                        Some(waiter) => waiter,
                        None => spawn_exit_waiter(child.id())?,
                    };
                    readable_within(&waiter, limit)?;
                    self.exit_waiter = Some(waiter);
                }
                Err(error) => return Err(error),
            },
            #[cfg(windows)]
            Inner::Std(child) => {
                return wait_timeout::ChildExt::wait_timeout(child, limit);
            }
            #[cfg(all(not(target_vendor = "apple"), not(target_os = "linux"), not(windows)))]
            Inner::Std(_) => {
                let _ = limit;
                return Err(io::Error::new(io::ErrorKind::Unsupported, "wait_timeout"));
            }
        }
        self.try_wait()
    }
}

/// A descriptor that turns readable once a child of this process has ended,
/// without reaping it: an exit event a reactor (tokio's `AsyncFd`) waits on
/// with no timer and no wakeup until then. macOS: a kqueue holding an
/// `EVFILT_PROC` `NOTE_EXIT` registration; Linux: a pidfd, or where
/// `pidfd_open` is missing or denied the pipe of a thread blocked in
/// `waitid(WNOWAIT)`. A child that had already ended gives a pipe at its end
/// (readable at once). Chromium watches a child's exit the same way
/// (`base/process/kill_mac.cc`, kqueue `NOTE_EXIT`).
#[cfg(unix)]
#[derive(Debug)]
pub struct ExitEvent(std::os::fd::OwnedFd);

#[cfg(unix)]
impl ExitEvent {
    /// The exit event of `pid`, which must be a child of this process that
    /// is not reaped yet (so the pid cannot name a reused process). Open it
    /// right after the spawn, before anything can wait on the child.
    pub fn open(pid: u32) -> io::Result<Self> {
        open_exit_event(pid).map(Self)
    }
}

#[cfg(unix)]
impl std::os::fd::AsRawFd for ExitEvent {
    fn as_raw_fd(&self) -> std::os::fd::RawFd {
        self.0.as_raw_fd()
    }
}

#[cfg(unix)]
impl std::os::fd::AsFd for ExitEvent {
    fn as_fd(&self) -> std::os::fd::BorrowedFd<'_> {
        self.0.as_fd()
    }
}

/// A descriptor that is readable at once: the read end of a pipe whose write
/// end is closed.
#[cfg(target_vendor = "apple")]
fn already_ended() -> io::Result<std::os::fd::OwnedFd> {
    let (reader, _writer) = io::pipe()?;
    Ok(reader.into())
}

/// macOS: a kqueue with `NOTE_EXIT` of `pid` registered; it turns readable
/// when the event is pending. A child that already exited (a zombie: the
/// registration fails with ESRCH) gives [`already_ended`].
#[cfg(target_vendor = "apple")]
fn open_exit_event(pid: u32) -> io::Result<std::os::fd::OwnedFd> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    let pid = libc::pid_t::try_from(pid).map_err(|_| io::Error::from_raw_os_error(libc::ESRCH))?;
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
        // SAFETY: one change in and no event slots: kevent only registers,
        // and reports a failed registration as its own error.
        let n = unsafe {
            libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
        };
        if n >= 0 {
            return Ok(queue);
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::ESRCH) => return already_ended(),
            Some(libc::EINTR) => {}
            _ => return Err(error),
        }
    }
}

/// Linux: a pidfd (readable once the process ended), or where `pidfd_open`
/// is missing (before 5.3) or denied (seccomp) the [`spawn_exit_waiter`] pipe.
#[cfg(target_os = "linux")]
fn open_exit_event(pid: u32) -> io::Result<std::os::fd::OwnedFd> {
    match open_pidfd(pid) {
        Ok(pidfd) => Ok(pidfd),
        Err(error) if pidfd_unavailable(&error) => spawn_exit_waiter(pid),
        Err(error) => Err(error),
    }
}

#[cfg(all(unix, not(target_vendor = "apple"), not(target_os = "linux")))]
fn open_exit_event(_pid: u32) -> io::Result<std::os::fd::OwnedFd> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "exit event"))
}

/// `pidfd_open` failed because the kernel lacks it (before Linux 5.3) or a
/// seccomp profile denies it: the `waitid` thread stands in.
#[cfg(target_os = "linux")]
fn pidfd_unavailable(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ENOSYS) | Some(libc::EPERM) | Some(libc::EACCES))
}

/// `waitpid(pid, flags)`, retried on EINTR: `None` when `WNOHANG` found the
/// child still running.
#[cfg(target_vendor = "apple")]
fn waitpid(pid: libc::pid_t, flags: libc::c_int) -> io::Result<Option<ExitStatus>> {
    use std::os::unix::process::ExitStatusExt;
    loop {
        let mut raw = 0;
        // SAFETY: waitpid writes one int for a child of this process.
        let reaped = unsafe { libc::waitpid(pid, &mut raw, flags) };
        if reaped == pid {
            return Ok(Some(ExitStatus::from_raw(raw)));
        }
        if reaped == 0 {
            return Ok(None);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

/// Block until `pid` exits or `limit` passes (kqueue `NOTE_EXIT`). A child
/// that exited before the registration (a zombie: `EV_ADD` fails with
/// ESRCH, as an `EV_ERROR` event or as `kevent`'s own error) returns at once;
/// the caller reaps it. The registration is sent with every `kevent` call,
/// so one interrupted before it took effect is not lost (`EV_ADD` of a
/// registered event only updates it).
#[cfg(target_vendor = "apple")]
pub(crate) fn exit_event_within(pid: libc::pid_t, limit: Duration) -> io::Result<()> {
    use std::os::fd::{FromRawFd, OwnedFd};
    // SAFETY: kqueue returns a new descriptor or -1.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a new descriptor this function owns.
    let queue = unsafe { OwnedFd::from_raw_fd(queue) };
    let queue_fd = std::os::fd::AsRawFd::as_raw_fd(&queue);
    let change = libc::kevent {
        ident: pid as libc::uintptr_t,
        filter: libc::EVFILT_PROC,
        flags: libc::EV_ADD | libc::EV_ONESHOT,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    let deadline = std::time::Instant::now() + limit;
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        let timeout = libc::timespec {
            tv_sec: left.as_secs() as libc::time_t,
            tv_nsec: left.subsec_nanos() as libc::c_long,
        };
        // SAFETY: zeroed kevent is valid output storage.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: one change in, at most one event out, a live timeout.
        let n = unsafe { libc::kevent(queue_fd, &change, 1, &mut event, 1, &timeout) };
        if n >= 0 {
            if n == 1 && event.flags & libc::EV_ERROR != 0 && event.data as i32 != libc::ESRCH {
                return Err(io::Error::from_raw_os_error(event.data as i32));
            }
            return Ok(());
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            // Exited before the registration: its status waits to be reaped.
            Some(libc::ESRCH) => return Ok(()),
            Some(libc::EINTR) => {}
            _ => return Err(error),
        }
    }
}

/// A thread that blocks in `waitid(WEXITED | WNOWAIT)` until `pid` ends
/// (without reaping it), then closes the write end of a pipe: the returned
/// read end turns readable (end of file) when the child has ended. The
/// bounded wait where no pidfd can be opened. The thread ends with the
/// child, also when the [`Child`] is dropped first.
#[cfg(target_os = "linux")]
fn spawn_exit_waiter(pid: u32) -> io::Result<std::os::fd::OwnedFd> {
    let (reader, writer) = io::pipe()?;
    std::thread::Builder::new().name("cmux-process-exit".into()).spawn(move || {
        loop {
            // SAFETY: zeroed siginfo_t is valid output storage.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            // SAFETY: waitid writes one siginfo_t; WNOWAIT leaves the child
            // to the caller's own wait.
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid as libc::id_t,
                    &mut info,
                    libc::WEXITED | libc::WNOWAIT,
                )
            };
            if result == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                break;
            }
        }
        drop(writer);
    })?;
    Ok(reader.into())
}

/// Block until `pid` exits or `limit` passes (a pidfd, `poll`).
#[cfg(target_os = "linux")]
fn exit_event_within(pid: u32, limit: Duration) -> io::Result<()> {
    readable_within(&open_pidfd(pid)?, limit)
}

/// `pidfd_open(pid, 0)`: a descriptor that turns readable when `pid` ends.
#[cfg(target_os = "linux")]
fn open_pidfd(pid: u32) -> io::Result<std::os::fd::OwnedFd> {
    use std::os::fd::{FromRawFd, OwnedFd};
    let pid = libc::pid_t::try_from(pid).map_err(|_| io::Error::from_raw_os_error(libc::ESRCH))?;
    // SAFETY: pidfd_open returns a new descriptor or -1.
    let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let raw = libc::c_int::try_from(raw).map_err(|_| io::Error::from_raw_os_error(libc::EBADF))?;
    // SAFETY: a new descriptor this function owns.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

/// Block until `fd` is readable (or hung up) or `limit` passes (`poll`).
#[cfg(target_os = "linux")]
fn readable_within(fd: &std::os::fd::OwnedFd, limit: Duration) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let deadline = std::time::Instant::now() + limit;
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        let mut poll = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let millis = left.as_millis().min(libc::c_int::MAX as u128) as libc::c_int
            + libc::c_int::from(!left.subsec_nanos().is_multiple_of(1_000_000));
        // SAFETY: one live pollfd.
        let n = unsafe { libc::poll(&mut poll, 1, millis) };
        if n >= 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod exit_wait_fallback {
    use std::time::{Duration, Instant};

    use crate::Command;

    /// The path a kernel without `pidfd_open` takes: a running child is
    /// waited on until the limit and not reaped, and its exit (here a kill)
    /// ends the next wait on the same waiter at once.
    #[test]
    fn the_waitid_thread_waits_for_the_limit_then_sees_the_exit() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let waiter = super::spawn_exit_waiter(child.id()).unwrap();
        let started = Instant::now();
        super::readable_within(&waiter, Duration::from_millis(200)).unwrap();
        assert!(started.elapsed() >= Duration::from_millis(200), "returned before the limit");
        assert!(child.try_wait().unwrap().is_none(), "the child still runs");
        child.kill().unwrap();
        let started = Instant::now();
        super::readable_within(&waiter, Duration::from_secs(30)).unwrap();
        assert!(started.elapsed() < Duration::from_secs(5), "missed the exit");
        assert!(child.try_wait().unwrap().is_some(), "reaped after the event");
    }

    /// A child that exited before the wait started is seen at once.
    #[test]
    fn the_waitid_thread_sees_a_child_that_already_exited() {
        let mut child = Command::new("/bin/true").spawn().unwrap();
        let waiter = super::spawn_exit_waiter(child.id()).unwrap();
        let started = Instant::now();
        super::readable_within(&waiter, Duration::from_secs(30)).unwrap();
        assert!(started.elapsed() < Duration::from_secs(5), "waited for an exited child");
        assert!(child.try_wait().unwrap().expect("exited").success());
    }
}

#[cfg(all(test, any(target_vendor = "apple", target_os = "linux")))]
mod exit_event {
    use std::io::Read;
    use std::os::fd::AsRawFd;
    use std::time::{Duration, Instant};

    use super::ExitEvent;
    use crate::{Command, Stdio};

    /// Whether `event` turns readable within `limit` (`poll`).
    fn readable(event: &ExitEvent, limit: Duration) -> bool {
        let mut poll = libc::pollfd { fd: event.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let millis = libc::c_int::try_from(limit.as_millis()).unwrap();
        // SAFETY: one live pollfd.
        let n = unsafe { libc::poll(&mut poll, 1, millis) };
        assert!(n >= 0, "poll: {}", std::io::Error::last_os_error());
        n == 1
    }

    /// A running child's event stays quiet; its exit makes it readable at
    /// once, and the child is still the caller's to reap.
    #[test]
    fn turns_readable_at_the_exit_and_leaves_the_child_unreaped() {
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let event = ExitEvent::open(child.id()).unwrap();
        assert!(!readable(&event, Duration::from_millis(200)), "readable while the child runs");
        child.kill().unwrap();
        let started = Instant::now();
        assert!(readable(&event, Duration::from_secs(30)), "missed the exit");
        assert!(started.elapsed() < Duration::from_secs(5), "late exit event");
        assert!(child.try_wait().unwrap().is_some(), "the child was not left to reap");
    }

    /// A child that ended before its event was opened (a zombie) is seen at once.
    #[test]
    fn a_child_that_already_ended_is_readable_at_once() {
        let mut child =
            Command::new("/bin/sh").args(["-c", "exit 3"]).stdout(Stdio::piped()).spawn().unwrap();
        // Its stdout reaches its end as it exits.
        let mut rest = Vec::new();
        child.stdout.take().unwrap().read_to_end(&mut rest).unwrap();
        std::thread::sleep(Duration::from_millis(100));
        let event = ExitEvent::open(child.id()).unwrap();
        assert!(readable(&event, Duration::from_secs(5)), "an ended child's event is quiet");
        assert_eq!(child.try_wait().unwrap().and_then(|s| s.code()), Some(3));
    }
}
