//! A started child: `std::process::Child`'s fields and methods, plus a
//! bounded wait that needs no polling and a hand-off of its reaping to the
//! process's `child-exit` thread ([`crate::ExitWatcher`]).

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
    /// The read end of a pipe the `child-exit` thread writes a byte to when
    /// the child ends, registered by the first bounded wait.
    #[cfg(unix)]
    exit: Option<std::sync::Arc<std::os::fd::OwnedFd>>,
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
        Self { stdin, stdout, stderr, inner: Inner::Pid { pid, status: None }, exit: None }
    }

    #[cfg(not(target_vendor = "apple"))]
    pub(crate) fn from_std(mut child: std::process::Child) -> Self {
        Self {
            stdin: child.stdin.take(),
            stdout: child.stdout.take(),
            stderr: child.stderr.take(),
            inner: Inner::Std(child),
            #[cfg(unix)]
            exit: None,
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
    /// it still runs. The wait is an event (the process's `child-exit`
    /// thread, [`crate::ExitWatcher`]), not a poll; `limit` only bounds it.
    pub fn wait_timeout(&mut self, limit: Duration) -> io::Result<Option<ExitStatus>> {
        drop(self.stdin.take());
        if let Some(status) = self.try_wait()? {
            return Ok(Some(status));
        }
        #[cfg(unix)]
        {
            let exit = match self.exit.take() {
                Some(exit) => exit,
                None => exit_signal(self.id())?,
            };
            let ended = exit_within(&exit, limit);
            self.exit = Some(exit);
            // Ended: the status waits to be reaped, so the wait returns at once.
            if ended? { self.wait().map(Some) } else { self.try_wait() }
        }
        #[cfg(windows)]
        match &mut self.inner {
            Inner::Std(child) => wait_timeout::ChildExt::wait_timeout(child, limit),
        }
        #[cfg(all(not(unix), not(windows)))]
        {
            let _ = limit;
            Err(io::Error::new(io::ErrorKind::Unsupported, "wait_timeout"))
        }
    }

    /// Hand the child to the process's `child-exit` thread, which reaps it
    /// when it ends: no thread of the caller's waits for it. Windows has no
    /// zombies; there the handle just closes.
    pub fn reap_on_exit(self) -> io::Result<()> {
        #[cfg(unix)]
        {
            let pid = self.id();
            let mut child = self;
            crate::ExitWatcher::process()?.register(pid, move || {
                // Ended: this wait returns at once.
                let _ = child.wait();
            })
        }
        #[cfg(not(unix))]
        {
            drop(self);
            Ok(())
        }
    }
}

/// A pipe's read end that turns readable when child `pid` ends: the
/// `child-exit` thread writes one byte to it. A byte, not the write end's
/// close, so a copy of the write end that a concurrent `std` spawn leaked
/// cannot hide the exit. The callback keeps the read end open too, so its
/// write never meets a closed pipe (no SIGPIPE) when the [`Child`] is gone.
#[cfg(unix)]
fn exit_signal(pid: u32) -> io::Result<std::sync::Arc<std::os::fd::OwnedFd>> {
    use std::io::Write;
    let (reader, mut writer) = io::pipe()?;
    let reader = std::sync::Arc::new(std::os::fd::OwnedFd::from(reader));
    let open = std::sync::Arc::clone(&reader);
    crate::ExitWatcher::process()?.register(pid, move || {
        let _ = writer.write_all(&[1]);
        drop(open);
    })?;
    Ok(reader)
}

/// Whether the child ended within `limit`: the exit byte arrived. End of
/// file without it (the watcher dropped the callback) is an error, never an
/// exit, so the caller does not block in `waitpid` for a running child.
#[cfg(unix)]
fn exit_within(exit: &std::os::fd::OwnedFd, limit: Duration) -> io::Result<bool> {
    use std::os::fd::AsRawFd;
    if !readable_within(exit, limit)? {
        return Ok(false);
    }
    let mut byte = [0_u8; 1];
    loop {
        // SAFETY: one byte into a live buffer from a live descriptor.
        let n = unsafe { libc::read(exit.as_raw_fd(), byte.as_mut_ptr().cast(), 1) };
        match n {
            1 => return Ok(true),
            0 => return Err(io::Error::other("the child-exit watcher dropped this child's wait")),
            _ => {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }
    }
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

/// Whether `fd` turned readable (or hung up) within `limit` (`poll`).
#[cfg(unix)]
fn readable_within(fd: &std::os::fd::OwnedFd, limit: Duration) -> io::Result<bool> {
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
            return Ok(n > 0);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}
