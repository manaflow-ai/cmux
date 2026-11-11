//! A started child: `std::process::Child`'s fields and methods, plus a
//! bounded wait that needs no polling, and an owner: dropping a child that
//! still runs ends it (and its process group, when it leads one) and reaps
//! it, unless [`Child::detach`] said why it must outlive its handle.

use std::io::{self, Read};
use std::process::{ChildStderr, ChildStdin, ChildStdout, ExitStatus, Output};
use std::time::Duration;

/// A running or ended child, as `std::process::Child`, except at drop.
///
/// Dropping a child whose status was never read ends it: its pipes close,
/// it gets SIGTERM (its whole process group, when it leads one: see
/// [`crate::Command::spawn`]), then SIGKILL after [`DROP_GRACE`] if it still
/// runs, and it is reaped. The drop itself only sends the first signal; the
/// grace and the reap run on a short-lived thread, so a drop never blocks its
/// caller. A child that must outlive its handle (a daemon, a hold that
/// outlives the command that took it) says why with [`Child::detach`], and
/// is then dropped as std drops one: neither signalled nor reaped.
#[derive(Debug)]
pub struct Child {
    /// The parent end of a piped stdin.
    pub stdin: Option<ChildStdin>,
    /// The parent end of a piped stdout.
    pub stdout: Option<ChildStdout>,
    /// The parent end of a piped stderr.
    pub stderr: Option<ChildStderr>,
    inner: Inner,
    /// It leads its own process group (a new group or session): a drop
    /// signals the group, so what it started ends with it.
    leads_group: bool,
    /// Its status was read (so it was reaped and its pid may name another
    /// process now): a drop signals nothing.
    ended: bool,
    /// Why it outlives this handle ([`Child::detach`]).
    detached: Option<&'static str>,
}

/// How long a dropped child has between SIGTERM and SIGKILL.
pub const DROP_GRACE: Duration = Duration::from_millis(500);

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
        Self {
            stdin,
            stdout,
            stderr,
            inner: Inner::Pid { pid, status: None },
            leads_group: false,
            ended: false,
            detached: None,
        }
    }

    #[cfg(not(target_vendor = "apple"))]
    pub(crate) fn from_std(mut child: std::process::Child) -> Self {
        Self {
            stdin: child.stdin.take(),
            stdout: child.stdout.take(),
            stderr: child.stderr.take(),
            inner: Inner::Std(child),
            leads_group: false,
            ended: false,
            detached: None,
        }
    }

    /// [`crate::Command::spawn`] started it as the leader of its own process
    /// group or session.
    pub(crate) fn set_leads_group(&mut self, leads_group: bool) {
        self.leads_group = leads_group;
    }

    /// Let the child outlive this handle: dropping it then neither signals
    /// nor reaps the child, as std. `reason` says why it must outlive its
    /// owner (the daemon it is, the lock it holds for a caller that exits);
    /// [`Child::detached`] and `Debug` show it. Waiting on a detached child
    /// still works.
    pub fn detach(&mut self, reason: &'static str) -> &mut Self {
        self.detached = Some(reason);
        self
    }

    /// Why the child outlives this handle, when [`Child::detach`] said so.
    pub fn detached(&self) -> Option<&'static str> {
        self.detached
    }

    /// Whether the child leads its own process group (a drop ends the group).
    pub fn leads_group(&self) -> bool {
        self.leads_group
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
        let status = self.wait_inner()?;
        self.ended = true;
        Ok(status)
    }

    fn wait_inner(&mut self) -> io::Result<ExitStatus> {
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
        let status = self.try_wait_inner()?;
        self.ended |= status.is_some();
        Ok(status)
    }

    fn try_wait_inner(&mut self) -> io::Result<Option<ExitStatus>> {
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
    /// `NOTE_EXIT`; Linux: a pidfd), not a poll; `limit` only bounds it.
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
            Inner::Std(child) => {
                exit_event_within(child.id(), limit)?;
            }
            #[cfg(windows)]
            Inner::Std(child) => {
                let status = wait_timeout::ChildExt::wait_timeout(child, limit)?;
                self.ended |= status.is_some();
                return Ok(status);
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

impl Drop for Child {
    /// A child whose status was never read and that was not detached ends
    /// here (the type's docs say how); one already reaped or detached is
    /// left as std leaves it.
    fn drop(&mut self) {
        if self.ended || self.detached.is_some() {
            return;
        }
        // Its pipes close first: a child that reads stdin to its end, or
        // writes to a reader that is gone, may end on that alone.
        drop((self.stdin.take(), self.stdout.take(), self.stderr.take()));
        #[cfg(unix)]
        {
            let Ok(pid) = libc::pid_t::try_from(self.id()) else { return };
            if pid > 0 {
                end_and_reap(pid, self.leads_group);
            }
        }
        #[cfg(windows)]
        {
            // No groups and no zombies: terminating it is the whole end.
            let Inner::Std(child) = &mut self.inner;
            let _ = child.kill();
        }
    }
}

/// SIGTERM to `pid` (its group when `group`), then, on a thread of its own,
/// SIGKILL once [`DROP_GRACE`] passes or the child exits, whichever is
/// first, and the reap. The pid is unreaped until that last step, so
/// neither it nor its group id can name another process before it.
#[cfg(unix)]
fn end_and_reap(pid: libc::pid_t, group: bool) {
    let target = if group { -pid } else { pid };
    // SAFETY: an unreaped child of this process (or the group it leads).
    unsafe { libc::kill(target, libc::SIGTERM) };
    let reap = move || {
        let _ = exit_within(pid, DROP_GRACE);
        // The group's members that ignored SIGTERM, or outlived their
        // leader, end here too.
        // SAFETY: still unreaped: the ids are still this child's.
        unsafe { libc::kill(target, libc::SIGKILL) };
        let _ = waitpid(pid, 0);
    };
    if std::thread::Builder::new().name("cmux-process-reap".into()).spawn(reap).is_err() {
        // No thread to wait on: SIGKILL now and reap what already ended. A
        // child that has not ended by the next line stays a zombie until
        // this process exits, which is no worse than std.
        // SAFETY: as above.
        unsafe { libc::kill(target, libc::SIGKILL) };
        let _ = waitpid(pid, libc::WNOHANG);
    }
}

/// Block until `pid` exits or `limit` passes, without reaping it.
#[cfg(unix)]
fn exit_within(pid: libc::pid_t, limit: Duration) -> io::Result<()> {
    #[cfg(target_vendor = "apple")]
    {
        exit_event_within(pid, limit)
    }
    #[cfg(target_os = "linux")]
    {
        exit_event_within(u32::try_from(pid).unwrap_or(0), limit)
    }
    #[cfg(all(not(target_vendor = "apple"), not(target_os = "linux")))]
    {
        // No exit event here: the whole grace, then the SIGKILL.
        let _ = pid;
        std::thread::sleep(limit);
        Ok(())
    }
}

/// `waitpid(pid, flags)`, retried on EINTR: `None` when `WNOHANG` found the
/// child still running.
#[cfg(unix)]
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

/// Block until `pid` exits or `limit` passes (a pidfd, `poll`).
#[cfg(target_os = "linux")]
fn exit_event_within(pid: u32, limit: Duration) -> io::Result<()> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    // SAFETY: pidfd_open returns a new descriptor or -1.
    let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a new descriptor this function owns.
    let pidfd = unsafe { OwnedFd::from_raw_fd(raw as libc::c_int) };
    let deadline = std::time::Instant::now() + limit;
    loop {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        let mut poll = libc::pollfd { fd: pidfd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
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
