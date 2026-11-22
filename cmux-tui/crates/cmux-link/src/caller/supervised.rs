//! Admission tied to a child handle and its kernel process-start identity.

use cmux_process::Child;
use std::io;
use std::os::fd::AsRawFd as _;
use std::os::unix::net::UnixStream;
use std::process::ExitStatus;
use std::sync::Mutex;

/// A process spawned by the daemon, retained until its remote entry stops.
///
/// Its pid and exact kernel start identity are captured from the owned child,
/// never from a registration file, environment variable, or connection claim.
pub struct SupervisedChild {
    child: Mutex<Child>,
    pid: u32,
    started: ProcessStart,
}

impl SupervisedChild {
    /// Capture `child` before releasing its private bootstrap channel.
    /// A child whose identity cannot be read is stopped and reaped.
    pub fn capture(mut child: Child) -> io::Result<Self> {
        let pid = child.id();
        let captured = (|| {
            if child.try_wait()?.is_some() {
                return Err(refused());
            }
            let started = process_start(pid)?;
            if child.try_wait()?.is_some() {
                return Err(refused());
            }
            Ok(started)
        })();
        match captured {
            Ok(started) => Ok(Self { child: Mutex::new(child), pid, started }),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                Err(error)
            }
        }
    }

    /// The pid captured from this child handle, for startup acknowledgements.
    pub fn id(&self) -> u32 {
        self.pid
    }

    /// Reap this owned process if it has exited, retaining its exit status.
    pub fn try_wait(&self) -> io::Result<Option<ExitStatus>> {
        self.child.lock().map_err(|_| refused())?.try_wait()
    }

    /// Stop and reap only this owned child, even when an entry retains another
    /// reference to its admission identity. Never signals an unowned pid.
    pub fn kill_and_wait(&self) -> io::Result<ExitStatus> {
        let mut child = self.child.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        let killed = child.kill();
        match child.wait() {
            Ok(status) => Ok(status),
            Err(error) => {
                killed?;
                Err(error)
            }
        }
    }

    /// Accept only this live process, in addition to the ordinary caller check.
    /// An exited child, poisoned handle, unreadable identity, or reused pid fails closed.
    pub fn verify(&self, stream: &UnixStream) -> io::Result<()> {
        super::verify(stream).map_err(io::Error::from)?;
        let mut child = self.child.lock().map_err(|_| refused())?;
        if child.try_wait()?.is_some()
            || super::peer_pid(stream.as_raw_fd())? != Some(self.pid)
            || process_start(self.pid)? != self.started
            || child.try_wait()?.is_some()
        {
            return Err(refused());
        }
        Ok(())
    }
}

impl Drop for SupervisedChild {
    fn drop(&mut self) {
        let child = self.child.get_mut().unwrap_or_else(std::sync::PoisonError::into_inner);
        // A live Child is retained throughout admission. Never signal a pid
        // from disk; Child::kill does not kill a replacement after try_wait.
        let _ = child.kill();
        let _ = child.wait();
    }
}

fn refused() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "link.supervised.caller_refused")
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct ProcessStart(u64, u64);

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(super) fn process_start(pid: u32) -> io::Result<ProcessStart> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))?;
    linux_start(&stat).ok_or_else(refused)
}

#[cfg(any(target_os = "linux", target_os = "android", test))]
fn linux_start(stat: &str) -> Option<ProcessStart> {
    // comm can contain spaces and ')'; starttime is field 22, index 19
    // after the final ')' delimiter. Retain raw ticks, without rounding.
    let (_, fields) = stat.rsplit_once(')')?;
    Some(ProcessStart(fields.split_whitespace().nth(19)?.parse().ok()?, 0))
}

#[cfg(target_os = "macos")]
fn process_start(pid: u32) -> io::Result<ProcessStart> {
    let pid = libc::c_int::try_from(pid).map_err(|_| refused())?;
    // SAFETY: proc_bsdinfo is plain C data and the out-buffer has its exact size.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).map_err(|_| refused())?;
    // SAFETY: info is writable for `size` bytes, as required by this flavor.
    let written =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    if written != size {
        return Err(refused());
    }
    Ok(ProcessStart(info.pbi_start_tvsec, info.pbi_start_tvusec))
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos")))]
fn process_start(_pid: u32) -> io::Result<ProcessStart> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "link.supervised.identity_unsupported"))
}

#[cfg(test)]
mod tests;
