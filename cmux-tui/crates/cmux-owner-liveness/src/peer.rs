//! The app at the other end of a connected Unix socket (a provider that
//! serves a helper), as the kernel names it.

use std::os::fd::AsRawFd;

use crate::OwnerApp;

/// The process at the other end of `socket`; unnamed where the platform has
/// no peer-pid call or the call failed.
pub fn peer_app(socket: &impl AsRawFd) -> OwnerApp {
    peer_pid(socket.as_raw_fd()).map_or_else(OwnerApp::default, OwnerApp::from_pid)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_pid(fd: std::os::fd::RawFd) -> Option<i32> {
    // SAFETY: ucred is plain data and all zero is a valid value.
    let mut credentials = unsafe { std::mem::zeroed::<libc::ucred>() };
    let mut length = libc::socklen_t::try_from(size_of::<libc::ucred>()).ok()?;
    // SAFETY: both out-pointers are valid for writes of the lengths passed.
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut credentials).cast(),
            &raw mut length,
        )
    };
    (rc == 0).then_some(credentials.pid)
}

#[cfg(target_vendor = "apple")]
fn peer_pid(fd: std::os::fd::RawFd) -> Option<i32> {
    let mut pid: libc::pid_t = 0;
    let mut length = libc::socklen_t::try_from(size_of::<libc::pid_t>()).ok()?;
    // SAFETY: both out-pointers are valid for writes of the lengths passed.
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&raw mut pid).cast(),
            &raw mut length,
        )
    };
    (rc == 0).then_some(pid)
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))))]
fn peer_pid(_fd: std::os::fd::RawFd) -> Option<i32> {
    None
}
