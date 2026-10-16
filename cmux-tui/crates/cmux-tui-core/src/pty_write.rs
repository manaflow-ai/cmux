//! Bounded writes shared by image paste and clear-history keyboard fallback.

use std::io;
use std::os::fd::RawFd;
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
        let deadline = Instant::now() + timeout;
        while delivered < bytes.len() {
            if Instant::now() >= deadline {
                return Err(io::Error::new(io::ErrorKind::TimedOut, timeout_message));
            }
            let remaining = &bytes[delivered..];
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
            let wait = deadline.saturating_duration_since(Instant::now());
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixStream;

    #[test]
    fn cloud_image_paste_pty_write_delivers_exact_bytes_and_restores_blocking_mode() {
        for initially_nonblocking in [false, true] {
            let (sender, mut receiver) = UnixStream::pair().unwrap();
            sender.set_nonblocking(initially_nonblocking).unwrap();
            let fd = sender.as_raw_fd();
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            let payload = b"\x1b[200~/private/clipboard.png\x1b[201~";
            write_bounded(fd, payload, Duration::from_secs(1), "test timeout").unwrap();
            let mut received = vec![0; payload.len()];
            receiver.read_exact(&mut received).unwrap();
            assert_eq!(received, payload);
            // Darwin adds the kernel-owned FWASWRITTEN status bit after I/O.
            // Assert the descriptor mode this operation actually changes.
            assert_eq!(
                unsafe { libc::fcntl(fd, libc::F_GETFL) } & libc::O_NONBLOCK,
                flags & libc::O_NONBLOCK
            );
        }
    }

    #[test]
    fn cloud_image_paste_pty_write_backpressure_times_out_and_records_partial_delivery() {
        let (sender, _receiver) = UnixStream::pair().unwrap();
        let fd = sender.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        let bytes = vec![7; 8 * 1024 * 1024];
        let start = Instant::now();
        let error =
            write_bounded(fd, &bytes, Duration::from_millis(25), "test timeout").unwrap_err();
        assert_eq!(error.error.kind(), io::ErrorKind::TimedOut);
        assert!(error.delivered > 0 && error.delivered < bytes.len());
        assert!(start.elapsed() < Duration::from_secs(2));
        // Darwin adds the kernel-owned FWASWRITTEN status bit after I/O.
        // Assert the descriptor mode this operation actually changes.
        assert_eq!(
            unsafe { libc::fcntl(fd, libc::F_GETFL) } & libc::O_NONBLOCK,
            flags & libc::O_NONBLOCK
        );
    }

    #[test]
    fn cloud_image_paste_pty_write_expired_deadline_never_delivers_input() {
        let (sender, _receiver) = UnixStream::pair().unwrap();
        let fd = sender.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        let error = write_bounded(fd, b"input", Duration::ZERO, "test timeout").unwrap_err();
        assert_eq!(error.error.kind(), io::ErrorKind::TimedOut);
        assert_eq!(error.delivered, 0);
        // Darwin adds the kernel-owned FWASWRITTEN status bit after I/O.
        // Assert the descriptor mode this operation actually changes.
        assert_eq!(
            unsafe { libc::fcntl(fd, libc::F_GETFL) } & libc::O_NONBLOCK,
            flags & libc::O_NONBLOCK
        );
    }
}
