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

    pub(crate) fn fd(&self) -> RawFd {
        self.reader.as_raw_fd()
    }
}
