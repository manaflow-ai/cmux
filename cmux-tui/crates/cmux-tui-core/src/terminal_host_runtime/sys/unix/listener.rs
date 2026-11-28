//! The host's endpoint listener (cx-ko2e `HostListener` seam, Unix side):
//! a private (0600), nonblocking Unix socket listener, and the accept loop's
//! wait on that listener or the accept waker. Moved from
//! `serve_terminal_host_stdio` unchanged.

use std::fs;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::time::Duration;

use super::{AcceptWaker, HostStream};

pub(crate) struct HostListener(UnixListener);

impl HostListener {
    /// Bind `endpoint`, make it owner-only, and make accepts nonblocking.
    pub(crate) fn bind(endpoint: &Path) -> anyhow::Result<Self> {
        let listener = UnixListener::bind(endpoint)?;
        fs::set_permissions(endpoint, fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        Ok(Self(listener))
    }

    pub(crate) fn accept(&self) -> io::Result<HostStream> {
        self.0.accept().map(|(stream, _)| stream)
    }

    /// Block until a client is waiting, the waker fires, or `timeout`
    /// passes (`None`: no timeout). Ok(true) when the waker fired; the raw
    /// `poll` error otherwise (the caller retries `Interrupted`).
    pub(crate) fn wait(&self, waker: &AcceptWaker, timeout: Option<Duration>) -> io::Result<bool> {
        let timeout = match timeout {
            None => -1,
            Some(remaining) => {
                i32::try_from(remaining.as_millis().saturating_add(1)).unwrap_or(i32::MAX)
            }
        };
        let mut fds = [
            libc::pollfd { fd: self.0.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: waker.fd(), events: libc::POLLIN, revents: 0 },
        ];
        // SAFETY: both descriptors stay open for this call: the listener
        // with `self` and the waker with its owner.
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(fds[1].revents != 0)
    }
}
