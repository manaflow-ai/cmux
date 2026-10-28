//! The cloud browser's CDP endpoint: the API skeleton the tests in cdp_socket_tests.rs
//! drive. This commit keeps the base's behavior (CDP on a TCP port, a plain bind, no peer
//! check, no forwarding), so those tests fail; the next commit implements the endpoint.

use std::fs::File;
use std::io;
use std::os::fd::RawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

/// The host's effective uid.
pub fn host_uid() -> u32 {
    // SAFETY: geteuid takes no arguments and cannot fail.
    unsafe { libc::geteuid() }
}

/// The base has no peer check.
pub fn peer_allowed(_peer: u32, _host: u32) -> bool {
    true
}

/// Not implemented in the base.
pub fn peer_uid(_stream: &UnixStream) -> io::Result<u32> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

/// A plain bind: the socket has the umask's mode and any parent is accepted.
pub fn bind_owner_only(path: &Path) -> io::Result<UnixListener> {
    UnixListener::bind(path)
}

/// The host's ends of one browser's CDP pipe.
pub struct BrowserPipe {
    pub to_browser: File,
    pub from_browser: File,
}

/// The browser's ends of its CDP pipe.
pub struct ChildEnds;

impl ChildEnds {
    pub fn raw(&self) -> (RawFd, RawFd) {
        (-1, -1)
    }
}

/// Not implemented in the base.
pub fn browser_pipes() -> io::Result<(BrowserPipe, ChildEnds)> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

/// Not implemented in the base.
pub fn install_child_fds(_read: RawFd, _write: RawFd) -> io::Result<()> {
    Ok(())
}

/// Binds the socket and serves nothing.
pub struct CdpBridge {
    _listener: UnixListener,
    _path: PathBuf,
}

impl CdpBridge {
    pub fn serve(path: &Path) -> io::Result<Self> {
        Self::serve_for_uid(path, host_uid())
    }

    pub fn serve_for_uid(path: &Path, _uid: u32) -> io::Result<Self> {
        Ok(Self { _listener: bind_owner_only(path)?, _path: path.to_path_buf() })
    }

    pub fn attach(&self, _pipe: BrowserPipe) {}
}

#[cfg(test)]
#[path = "cdp_socket_tests.rs"]
mod tests;
