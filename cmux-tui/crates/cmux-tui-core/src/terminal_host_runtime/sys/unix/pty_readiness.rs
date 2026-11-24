//! Wait until the host's PTY is readable or a forced drain ends
//! (cx-ko2e `PtyReadiness` seam, Unix side: `poll` on the PTY descriptor and
//! the drain waker). Moved from `mod unix` unchanged.

use std::io::Read;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use super::super::super::shared::host_state::HOST_FORCED_DRAIN_WINDOW;

pub(crate) fn wait_for_pty_readable_or_forced_drain(
    pty_fd: RawFd,
    drain_waiter: &mut UnixStream,
    force_drain: &AtomicBool,
    forced_at: &mut Option<Instant>,
) -> std::io::Result<bool> {
    // A hung-up waiter stays readable forever, so once forced it is left
    // out of the poll set; it used to busy-loop the rest of the window.
    let mut waiter_closed = false;
    loop {
        if force_drain.load(Ordering::Acquire) {
            let started = forced_at.get_or_insert_with(Instant::now);
            if started.elapsed() >= HOST_FORCED_DRAIN_WINDOW {
                return Ok(false);
            }
        }
        let mut poll_fds = [
            libc::pollfd {
                fd: pty_fd,
                events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                revents: 0,
            },
            libc::pollfd {
                // poll ignores negative descriptors.
                fd: if waiter_closed { -1 } else { drain_waiter.as_raw_fd() },
                events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
                revents: 0,
            },
        ];
        let timeout_ms = forced_at
            .map(|started| {
                let remaining = HOST_FORCED_DRAIN_WINDOW.saturating_sub(started.elapsed());
                remaining.as_millis().clamp(1, i32::MAX as u128) as i32
            })
            .unwrap_or(-1);
        // SAFETY: poll_fds points to two initialized values and both
        // descriptors remain owned by the caller for this call.
        let ready = unsafe {
            libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as libc::nfds_t, timeout_ms)
        };
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if poll_fds[0].revents & libc::POLLNVAL != 0 {
            return Ok(false);
        }
        if poll_fds[1].revents & libc::POLLIN != 0 {
            let mut wake = [0u8; 64];
            let _ = drain_waiter.read(&mut wake);
        }
        if poll_fds[0].revents != 0 {
            return Ok(true);
        }
        if poll_fds[1].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
            if !force_drain.load(Ordering::Acquire) {
                return Ok(false);
            }
            waiter_closed = true;
        }
        // A wake transitions the next iteration into forced mode. While
        // forced, an empty poll waits again until the remaining bounded
        // window expires so late final bytes are still observed.
    }
}

/// Whether a read on the PTY returns at once when it is empty (`O_NONBLOCK`,
/// set by `nonblocking_pty_writer`): the reader then fills a frame with reads
/// alone and the read that finds nothing (`WouldBlock`) ends it. A zero-timeout
/// `poll` before every read (1 KiB on macOS) doubled the reader's system calls
/// and held a 200 MB burst near 110 MB/s (CMUX-571). Asked once per frame,
/// since the flag belongs to an open file description other processes share.
// perf-hot: 1us terminal-host-output (every PTY frame)
pub(crate) fn pty_reads_without_waiting(pty_fd: RawFd) -> bool {
    // SAFETY: fcntl on a descriptor the caller owns.
    let flags = unsafe { libc::fcntl(pty_fd, libc::F_GETFL) };
    flags >= 0 && flags & libc::O_NONBLOCK != 0
}

/// Whether the PTY has bytes to read now, without waiting: a blocking reader
/// then reads them into the same frame before it publishes. A flooding program
/// fills the PTY faster than one read drains it (a macOS PTY read returns at
/// most 1 KiB), and each published frame costs a parser hand-off and a
/// daemon frame; a lone key echo finds nothing more and goes out at once.
// perf-hot: 1us terminal-host-output (every PTY read)
pub(crate) fn pty_readable_now(pty_fd: RawFd) -> bool {
    let mut poll_fd = libc::pollfd { fd: pty_fd, events: libc::POLLIN, revents: 0 };
    // SAFETY: one initialized pollfd; the caller owns the descriptor.
    let ready = unsafe { libc::poll(&mut poll_fd, 1, 0) };
    ready > 0 && poll_fd.revents & libc::POLLIN != 0
}
