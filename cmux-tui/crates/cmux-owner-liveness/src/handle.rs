//! One kernel handle on a process that is not this one's child, opened when
//! the app is named (so a pid recycled later is never followed), and a
//! blocking wait for its exit. Linux: a pidfd, readable once the process
//! exited. macOS: a kqueue with an `EVFILT_PROC` `NOTE_EXIT` registration.

use std::io;

#[cfg(any(target_os = "linux", target_os = "macos"))]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

/// The open handle.
pub(crate) struct Handle {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    fd: OwnedFd,
}

#[cfg(target_os = "linux")]
impl Handle {
    /// The handle on `pid`; `None` when it has exited already.
    pub(crate) fn open(pid: i32) -> io::Result<Option<Self>> {
        // SAFETY: pidfd_open(pid, 0) returns a new descriptor or -1.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if fd < 0 {
            let error = io::Error::last_os_error();
            return if error.raw_os_error() == Some(libc::ESRCH) { Ok(None) } else { Err(error) };
        }
        let fd = libc::c_int::try_from(fd).map_err(io::Error::other)?;
        // SAFETY: pidfd_open returned this descriptor; nothing else owns it.
        Ok(Some(Self { fd: unsafe { OwnedFd::from_raw_fd(fd) } }))
    }

    /// Blocks until the process exits.
    pub(crate) fn wait(self) -> io::Result<()> {
        let mut poll = libc::pollfd { fd: self.fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        loop {
            // SAFETY: one pollfd, a local that outlives the call; -1 blocks until it is ready.
            let n = unsafe { libc::poll(&mut poll, 1, -1) };
            if n > 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if n < 0 && error.raw_os_error() != Some(libc::EINTR) {
                return Err(error);
            }
        }
    }
}

#[cfg(target_os = "macos")]
impl Handle {
    /// The handle on `pid`; `None` when it has exited already.
    pub(crate) fn open(pid: i32) -> io::Result<Option<Self>> {
        // SAFETY: kqueue takes no arguments and returns a new descriptor or -1.
        let queue = unsafe { libc::kqueue() };
        if queue < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: kqueue returned this descriptor; nothing else owns it.
        let fd = unsafe { OwnedFd::from_raw_fd(queue) };
        let ident = libc::uintptr_t::try_from(pid).map_err(io::Error::other)?;
        // SAFETY: kevent is a plain C struct; all zero is a valid value of it.
        let mut change: libc::kevent = unsafe { std::mem::zeroed() };
        change.ident = ident;
        change.filter = libc::EVFILT_PROC;
        change.flags = libc::EV_ADD | libc::EV_ONESHOT;
        change.fflags = libc::NOTE_EXIT;
        loop {
            // SAFETY: one change, a local that outlives the call, and no event
            // slot: a failed registration returns -1 with errno.
            let n = unsafe {
                libc::kevent(fd.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
            };
            if n >= 0 {
                return Ok(Some(Self { fd }));
            }
            let error = io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => {}
                Some(libc::ESRCH) => return Ok(None),
                _ => return Err(error),
            }
        }
    }

    /// Blocks until the process exits.
    pub(crate) fn wait(self) -> io::Result<()> {
        loop {
            // SAFETY: kevent is a plain C struct; all zero is a valid value of it.
            let mut event: libc::kevent = unsafe { std::mem::zeroed() };
            // SAFETY: no change and one event slot, a local that outlives the
            // call; a null timeout blocks until the event.
            let n = unsafe {
                libc::kevent(
                    self.fd.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    &mut event,
                    1,
                    std::ptr::null(),
                )
            };
            if n > 0 {
                // An error event (other than "already gone") is no exit: the
                // caller falls back to checking the app.
                if event.flags & libc::EV_ERROR != 0 {
                    return if i64::try_from(event.data).ok() == Some(i64::from(libc::ESRCH)) {
                        Ok(())
                    } else {
                        Err(io::Error::from_raw_os_error(
                            i32::try_from(event.data).unwrap_or(libc::EINVAL),
                        ))
                    };
                }
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if n < 0 && error.raw_os_error() != Some(libc::EINTR) {
                return Err(error);
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
impl Handle {
    pub(crate) fn open(_pid: i32) -> io::Result<Option<Self>> {
        Err(io::Error::from(io::ErrorKind::Unsupported))
    }

    pub(crate) fn wait(self) -> io::Result<()> {
        Err(io::Error::from(io::ErrorKind::Unsupported))
    }
}
