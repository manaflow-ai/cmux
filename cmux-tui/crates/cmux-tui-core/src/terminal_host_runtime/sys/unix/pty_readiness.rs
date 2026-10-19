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
        match poll_pty(pty_fd, drain_waiter, force_drain, forced_at, &mut waiter_closed, true)? {
            PtyPoll::Readable => return Ok(true),
            PtyPoll::Ended => return Ok(false),
            PtyPoll::Pending(_) => {}
        }
    }
}

/// One wait of [`wait_for_pty_readable_or_forced_drain`].
pub(crate) enum PtyPoll {
    Readable,
    /// The reader ends (no more bytes, or the forced window passed).
    Ended,
    /// Nothing yet; while forced, at most this long until the window ends.
    Pending(Option<std::time::Duration>),
}

/// One pass of the wait: `block` waits as the reader thread does; without
/// it a shared host's event loop asks and arms the next wait itself.
/// `waiter_closed` persists across passes.
pub(crate) fn poll_pty(
    pty_fd: RawFd,
    drain_waiter: &mut UnixStream,
    force_drain: &AtomicBool,
    forced_at: &mut Option<Instant>,
    waiter_closed: &mut bool,
    block: bool,
) -> std::io::Result<PtyPoll> {
    if force_drain.load(Ordering::Acquire) {
        let started = forced_at.get_or_insert_with(Instant::now);
        if started.elapsed() >= HOST_FORCED_DRAIN_WINDOW {
            return Ok(PtyPoll::Ended);
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
            fd: if *waiter_closed { -1 } else { drain_waiter.as_raw_fd() },
            events: libc::POLLIN | libc::POLLHUP | libc::POLLERR,
            revents: 0,
        },
    ];
    let remaining =
        forced_at.map(|started| HOST_FORCED_DRAIN_WINDOW.saturating_sub(started.elapsed()));
    let timeout_ms = if !block {
        0
    } else {
        remaining
            .map(|remaining| remaining.as_millis().clamp(1, i32::MAX as u128) as i32)
            .unwrap_or(-1)
    };
    // SAFETY: poll_fds points to two initialized values and both
    // descriptors remain owned by the caller for this call.
    let ready =
        unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as libc::nfds_t, timeout_ms) };
    if ready < 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            return Ok(PtyPoll::Pending(remaining));
        }
        return Err(error);
    }
    if poll_fds[0].revents & libc::POLLNVAL != 0 {
        return Ok(PtyPoll::Ended);
    }
    if poll_fds[1].revents & libc::POLLIN != 0 {
        let mut wake = [0u8; 64];
        let _ = drain_waiter.read(&mut wake);
    }
    if poll_fds[0].revents != 0 {
        return Ok(PtyPoll::Readable);
    }
    if poll_fds[1].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
        if !force_drain.load(Ordering::Acquire) {
            return Ok(PtyPoll::Ended);
        }
        *waiter_closed = true;
    }
    // A wake transitions the next pass into forced mode. While forced, an
    // empty poll waits again until the remaining bounded window expires so
    // late final bytes are still observed.
    if !block && force_drain.load(Ordering::Acquire) && forced_at.is_none() {
        forced_at.get_or_insert_with(Instant::now);
    }
    Ok(PtyPoll::Pending(
        forced_at.map(|started| HOST_FORCED_DRAIN_WINDOW.saturating_sub(started.elapsed())),
    ))
}
