//! Blocking waits on file descriptors (poll(2)) and a pipe-based waker.

use std::io;
use std::os::fd::RawFd;

/// Blocks until one of `fds` is readable or `timeout_ns` elapses (`None` = forever).
pub fn wait_readable(fds: &[RawFd], timeout_ns: Option<u64>) -> io::Result<()> {
    let mut pfds: Vec<libc::pollfd> = fds.iter().map(|&fd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 }).collect();
    let timeout_ms = match timeout_ns {
        None => -1,
        // Round up so we never wake before the deadline and spin.
        Some(ns) => ns.div_ceil(1_000_000).min(i32::MAX as u64) as i32,
    };
    // SAFETY: pfds is a valid array of pollfd for its length.
    let rc = unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, timeout_ms) };
    if rc < 0 {
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
    Ok(())
}
