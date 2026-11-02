//! The private parent channel inherited by a Native receiving child.
//!
//! The guest receiver gets all authority over this connected Unix socket from
//! the daemon's root bootstrap. It never accepts a path or an account token as
//! a substitute for possession of the descriptor.

use std::io;
use std::os::fd::{AsRawFd as _, FromRawFd as _};
use std::os::unix::net::UnixStream;

/// Duplicate and seal only a connected stream inherited from the parent.
///
/// The parent owns the other endpoint. A path, pid file, or claimed identity
/// can never substitute for possession of that endpoint.
pub(super) fn inherited(fd: &str) -> io::Result<UnixStream> {
    let refused = || io::Error::new(io::ErrorKind::PermissionDenied, "cloud.broker.parent_refused");
    let fd: i32 = fd.parse().map_err(|_| refused())?;
    if fd < 0 {
        return Err(refused());
    }
    // SAFETY: fcntl validates fd and returns a new owned descriptor, or -1.
    let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
    if copy < 0 {
        return Err(refused());
    }
    // SAFETY: copy is the fresh descriptor returned by F_DUPFD_CLOEXEC.
    let stream = unsafe { UnixStream::from_raw_fd(copy) };
    let mut kind = 0_i32;
    let mut size = size_of_val(&kind) as libc::socklen_t;
    // SAFETY: kind is writable for size bytes; getsockopt validates the socket.
    if unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_TYPE,
            std::ptr::from_mut(&mut kind).cast(),
            &mut size,
        )
    } != 0
        || kind != libc::SOCK_STREAM
    {
        return Err(refused());
    }
    cmux_link::caller::verify_inherited_parent(stream.as_raw_fd()).map_err(|_| refused())?;
    // SAFETY: seal the original descriptor too, before any later exec.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
        return Err(refused());
    }
    Ok(stream)
}
