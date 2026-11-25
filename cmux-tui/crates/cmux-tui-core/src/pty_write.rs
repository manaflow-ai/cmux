//! Bounded writes shared by image paste and clear-history keyboard fallback.

use std::io::{self, Write};
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::time::{Duration, Instant};

#[derive(Debug)]
pub(crate) struct BoundedWriteFailure {
    pub error: io::Error,
    pub delivered: usize,
}

/// Writes directly to a PTY descriptor and restores its original status flags.
/// The caller must keep the descriptor alive and serialize writes for its lifetime.
/// No buffered writer flush is needed: every byte is written through the descriptor.
pub(crate) fn write_bounded(
    fd: RawFd,
    bytes: &[u8],
    timeout: Duration,
    timeout_message: &'static str,
) -> Result<(), BoundedWriteFailure> {
    let mut delivered = 0;
    let result = (|| {
        let mut nonblocking = NonblockingFdGuard::install(fd)?;
        // A timeout too large to represent never expires.
        let deadline = Instant::now().checked_add(timeout);
        while delivered < bytes.len() {
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            let Some(remaining) = bytes.get(delivered..) else { break };
            let written = unsafe { libc::write(fd, remaining.as_ptr().cast(), remaining.len()) };
            if written > 0 {
                delivered += written as usize;
                continue;
            }
            if written == 0 {
                return Err(io::Error::new(io::ErrorKind::WriteZero, "PTY write returned zero"));
            }
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if error.kind() != io::ErrorKind::WouldBlock {
                return Err(error);
            }
            let wait = deadline
                .map_or(timeout, |deadline| deadline.saturating_duration_since(Instant::now()));
            if wait.is_zero() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            let millis = wait.as_nanos().saturating_add(999_999) / 1_000_000;
            let mut poll_fd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            let ready =
                unsafe { libc::poll(&mut poll_fd, 1, millis.clamp(1, i32::MAX as u128) as i32) };
            if ready == 0 {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            } else if poll_fd.revents & libc::POLLNVAL != 0 {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "PTY fd is invalid"));
            }
        }
        nonblocking.restore()
    })();
    result.map_err(|error| BoundedWriteFailure { error, delivered })
}

struct NonblockingFdGuard {
    fd: RawFd,
    original_flags: libc::c_int,
    restored: bool,
}

impl NonblockingFdGuard {
    fn install(fd: RawFd) -> io::Result<Self> {
        let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if original_flags < 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { libc::fcntl(fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { fd, original_flags, restored: false })
    }

    fn restore(&mut self) -> io::Result<()> {
        if !self.restored {
            if unsafe { libc::fcntl(self.fd, libc::F_SETFL, self.original_flags) } < 0 {
                return Err(io::Error::last_os_error());
            }
            self.restored = true;
        }
        Ok(())
    }
}

impl Drop for NonblockingFdGuard {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

/// The input writer on a master that is read non-blocking (the holder's
/// custody master, a terminal host's PTY), and `O_NONBLOCK` belongs to the open file
/// description every dup shares, so a write the PTY's input queue (about 1
/// KiB on macOS) cannot take returns `WouldBlock`. This writer then waits
/// for room, as a write on a blocking master does: a paste or a burst of
/// mouse reports is never cut.
pub(crate) struct WaitingWriter {
    pub(crate) inner: Box<dyn Write + Send>,
    /// A dup of the master to wait on.
    pub(crate) master: OwnedFd,
}

impl Write for WaitingWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        loop {
            match self.inner.write(buffer) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait_writable(self.master.as_raw_fd())?;
                }
                result => return result,
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        loop {
            match self.inner.flush() {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait_writable(self.master.as_raw_fd())?;
                }
                result => return result,
            }
        }
    }
}

/// Block until the master takes input again. A master whose terminal ended
/// is an error rather than a wait that never ends.
fn wait_writable(master: RawFd) -> io::Result<()> {
    loop {
        let mut poll_fd = libc::pollfd { fd: master, events: libc::POLLOUT, revents: 0 };
        // SAFETY: polls one live pollfd; -1 waits like a blocking write.
        let ready = unsafe { libc::poll(&mut poll_fd, 1, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if poll_fd.revents & libc::POLLOUT == 0
            && poll_fd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
        {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "the terminal's PTY closed"));
        }
        return Ok(());
    }
}
