//! The host's accept-loop waker (cx-ko2e `Waker` seam, Unix side): a
//! nonblocking socket pair. Moved from `mod unix` unchanged.

use std::io::{self as std_io, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;

/// A self-pipe (socket pair) that the host's accept loop polls next to
/// its listener. Writes never block: a full buffer already means a wake
/// is pending.
pub(crate) struct AcceptWaker {
    reader: UnixStream,
    writer: UnixStream,
}

impl AcceptWaker {
    pub(crate) fn new() -> std_io::Result<Self> {
        let (reader, writer) = UnixStream::pair()?;
        reader.set_nonblocking(true)?;
        writer.set_nonblocking(true)?;
        Ok(Self { reader, writer })
    }

    pub(crate) fn wake(&self) {
        let _ = (&self.writer).write(&[1]);
    }

    pub(crate) fn drain(&self) {
        let mut buffer = [0_u8; 64];
        while matches!((&self.reader).read(&mut buffer), Ok(count) if count > 0) {}
    }

    /// Wait up to `timeout` (at least 1 ms) for a wake. Ok(false) on timeout;
    /// the raw `poll` error otherwise (the caller retries `Interrupted`).
    pub(crate) fn wait_readable(&self, timeout: std::time::Duration) -> std_io::Result<bool> {
        let timeout = i32::try_from(timeout.as_millis().max(1)).unwrap_or(i32::MAX);
        let mut fds = [libc::pollfd { fd: self.fd(), events: libc::POLLIN, revents: 0 }];
        // SAFETY: the waker descriptor stays open as long as `self`.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 1, timeout) };
        if ready < 0 {
            return Err(std_io::Error::last_os_error());
        }
        Ok(ready > 0)
    }

    pub(crate) fn fd(&self) -> RawFd {
        self.reader.as_raw_fd()
    }
}
