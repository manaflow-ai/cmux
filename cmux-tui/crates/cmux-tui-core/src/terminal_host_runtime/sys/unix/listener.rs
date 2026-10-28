//! The host's endpoint listener (cx-ko2e `HostListener` seam, Unix side):
//! a private (0600), nonblocking Unix socket listener, and the accept loop's
//! wait on that listener or the accept waker. Moved from
//! `serve_terminal_host_stdio` unchanged.

use cmux_threads::checked::fs as files;
use std::fs;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::time::Duration;

use super::{AcceptWaker, HostStream};
use crate::wake;

pub(crate) struct HostListener(UnixListener);

impl HostListener {
    /// Bind `endpoint`, make it owner-only, and make accepts nonblocking.
    pub(crate) fn bind(endpoint: &Path) -> anyhow::Result<Self> {
        let listener = UnixListener::bind(endpoint)?;
        files::set_permissions(endpoint, fs::Permissions::from_mode(0o600))?;
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
        let timeout = poll_timeout_ms(timeout, wake::Ticks::now());
        let mut fds = [
            libc::pollfd { fd: self.0.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: waker.fd(), events: libc::POLLIN, revents: 0 },
        ];
        // SAFETY: both descriptors stay open for this call: the listener
        // with `self` and the waker with its owner.
        // wakeup-allow: deadline the accept loop's launch-owner and orphan deadlines (no timeout once
        // both are past); a client or the waker ends the wait first
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(fds[1].revents != 0)
    }
}

/// The accept loop's `poll` timeout for `timeout` from `now`: -1 (none)
/// for `None`, else the milliseconds until `wake::deadline`'s fire time,
/// rounded up, so the wake lands on the shared grid and never before the
/// deadline (a wake before it would only wait again).
fn poll_timeout_ms(timeout: Option<Duration>, now: wake::Ticks) -> libc::c_int {
    let Some(remaining) = timeout else { return -1 };
    let wait = wake::deadline(now, remaining, wake::Policy::FlexibleNoSooner).wait_from(now);
    let millis = wait.as_nanos().div_ceil(1_000_000);
    libc::c_int::try_from(millis).unwrap_or(libc::c_int::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_deadline_waits_without_a_timeout() {
        assert_eq!(poll_timeout_ms(None, wake::Ticks(0)), -1);
    }

    #[test]
    fn the_wake_is_never_before_the_deadline_and_lands_on_the_grid() {
        // 3.2 s from 0.5 s: the deadline is 3.7 s, the whole-second grid puts the wake at 4 s.
        let now = wake::Ticks(500_000_000);
        assert_eq!(poll_timeout_ms(Some(Duration::from_millis(3_200)), now), 3_500);
        // Below 1 s: the 8 ms grid, rounded up to whole milliseconds.
        let now = wake::Ticks(1_000_000);
        let millis = poll_timeout_ms(Some(Duration::from_micros(20_500)), now);
        assert_eq!(millis, 23, "deadline 21.5 ms, grid 24 ms, from 1 ms");
        // A passed deadline is due now.
        assert_eq!(poll_timeout_ms(Some(Duration::ZERO), now), 0);
    }
}
