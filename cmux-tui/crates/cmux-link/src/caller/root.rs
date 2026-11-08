//! The root host's actual session-daemon child, including a dropped work uid.
use std::io;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::process::{Child, ExitStatus};
use std::sync::Mutex;

use super::CallerRefused;
use super::supervised::{ProcessStart, process_start};

fn check_stream(fd: RawFd) -> io::Result<()> {
    let mut kind = 0_i32;
    let mut size = size_of_val(&kind) as libc::socklen_t;
    // SAFETY: both output pointers are live and correctly sized. The kernel
    // validates fd; this function never takes ownership of it.
    if unsafe {
        libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_TYPE, (&raw mut kind).cast(), &raw mut size)
    } != 0
        || size as usize != size_of_val(&kind)
        || kind != libc::SOCK_STREAM
    {
        return Err(refused());
    }
    Ok(())
}

pub(super) fn verify_parent(fd: RawFd) -> Result<(), CallerRefused> {
    check_stream(fd).map_err(CallerRefused::Io)?;
    let uid = super::peer_uid(fd).map_err(CallerRefused::Io)?;
    if uid != 0 {
        return Err(CallerRefused::OtherUser { uid });
    }
    // SAFETY: getppid has no preconditions. The parent identity comes from
    // the kernel, never a bootstrap field, environment or registration file.
    let parent = unsafe { libc::getppid() } as u32;
    if super::peer_pid(fd).map_err(CallerRefused::Io)? != Some(parent) {
        return Err(CallerRefused::Io(refused()));
    }
    Ok(())
}

/// Retains the real child handle. Unreadable identity disables bootstrap but
/// never kills the session daemon. Dropping this owner preserves the daemon,
/// which a replacement host supervisor may adopt; it grants no bootstrap to
/// an adopted pid or a connection's identity claim.
pub struct RootOwnedDaemon {
    child: Mutex<Child>,
    pid: u32,
    uid: u32,
    started: Option<ProcessStart>,
}

impl RootOwnedDaemon {
    /// `uid` is the work identity selected by the root spawner, not a hello.
    /// Capture before releasing any private bootstrap to this child.
    pub fn capture(mut child: Child, uid: u32) -> Self {
        let pid = child.id();
        // SAFETY: geteuid has no preconditions.
        let started = (unsafe { libc::geteuid() } == 0)
            .then(|| {
                if child.try_wait().ok()?.is_some() {
                    return None;
                }
                let started = process_start(pid).ok()?;
                child.try_wait().ok()?.is_none().then_some(started)
            })
            .flatten();
        Self { child: Mutex::new(child), pid, uid, started }
    }

    pub fn id(&self) -> u32 {
        self.pid
    }

    pub fn try_wait(&self) -> io::Result<Option<ExitStatus>> {
        self.child.lock().map_err(|_| refused())?.try_wait()
    }

    /// Wait for this owned child's exit; never resolve a pid from external state.
    pub fn wait(&self) -> io::Result<ExitStatus> {
        self.child.lock().map_err(|_| refused())?.wait()
    }

    /// Only a root owner may authorize its exact live work-user child.
    /// The endpoint must be created by that child after its uid transition;
    /// an inherited pair still names its creator and cannot substitute.
    pub fn verify(&self, stream: &UnixStream) -> io::Result<()> {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } != 0 {
            return Err(refused());
        }
        check_stream(stream.as_raw_fd())?;
        let mut child = self.child.lock().map_err(|_| refused())?;
        if self.started.is_none()
            || child.try_wait()?.is_some()
            || super::peer_uid(stream.as_raw_fd())? != self.uid
            || super::peer_pid(stream.as_raw_fd())? != Some(self.pid)
            || Some(&process_start(self.pid)?) != self.started.as_ref()
            || child.try_wait()?.is_some()
        {
            return Err(refused());
        }
        Ok(())
    }
}

fn refused() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "cloud.bootstrap.owned_daemon_refused")
}
