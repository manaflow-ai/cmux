//! Windows AF_UNIX (uds_windows) with the same-user rules. Not implemented
//! yet: every call reports `Unsupported` (the red tests come first).

use std::io;
use std::path::Path;
use std::time::Duration;

use crate::PeerIdentity;

/// A connected local socket.
pub type Stream = uds_windows::UnixStream;

fn unsupported<T>() -> io::Result<T> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "cmux-local-socket: not implemented on Windows yet"))
}

/// A listening local socket that refuses foreign and sandboxed peers.
pub struct Listener {
    inner: uds_windows::UnixListener,
}

impl Listener {
    pub fn accept(&self) -> io::Result<Stream> {
        let _ = &self.inner;
        unsupported()
    }

    pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()> {
        self.inner.set_nonblocking(nonblocking)
    }

    pub fn raw_socket(&self) -> u64 {
        std::os::windows::io::AsRawSocket::as_raw_socket(&self.inner)
    }
}

pub fn listen(path: &Path) -> io::Result<Listener> {
    let _ = path;
    unsupported()
}

pub fn connect(path: &Path) -> io::Result<Stream> {
    uds_windows::UnixStream::connect(path)
}

pub fn connect_same_user(path: &Path) -> io::Result<Stream> {
    let _ = path;
    unsupported()
}

pub fn connect_with_deadline(
    path: &Path,
    timeout: Duration,
    poll_interval: Duration,
    check: impl FnMut() -> io::Result<()>,
) -> io::Result<Stream> {
    let _ = (path, timeout, poll_interval, check);
    unsupported()
}

pub fn peer_pid(stream: &Stream) -> io::Result<u32> {
    let _ = stream;
    unsupported()
}

pub fn current_identity() -> io::Result<PeerIdentity> {
    unsupported()
}

pub fn process_identity(pid: u32) -> io::Result<PeerIdentity> {
    let _ = pid;
    unsupported()
}

pub fn owner_of(path: &Path) -> io::Result<String> {
    let _ = path;
    unsupported()
}

pub fn directory_is_owner_only(path: &Path, our_user_sid: &str) -> io::Result<bool> {
    let _ = (path, our_user_sid);
    unsupported()
}
