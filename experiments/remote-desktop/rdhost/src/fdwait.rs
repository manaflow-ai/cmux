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

/// Wakes a thread blocked in `wait_readable` on `fd()`.
pub struct Waker {
    rd: RawFd,
    wr: RawFd,
}

impl Waker {
    pub fn new() -> io::Result<Self> {
        let mut fds = [0 as RawFd; 2];
        // SAFETY: fds has room for two descriptors.
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { rd: fds[0], wr: fds[1] })
    }

    pub fn fd(&self) -> RawFd {
        self.rd
    }

    pub fn wake(&self) {
        let b = 1u8;
        // SAFETY: writing one byte from a valid buffer; EAGAIN (pipe full) still leaves it readable.
        unsafe { libc::write(self.wr, (&b as *const u8).cast(), 1) };
    }

    pub fn drain(&self) {
        let mut buf = [0u8; 64];
        // SAFETY: non-blocking reads into a valid buffer until empty.
        while unsafe { libc::read(self.rd, buf.as_mut_ptr().cast(), buf.len()) } > 0 {}
    }
}

impl Drop for Waker {
    fn drop(&mut self) {
        // SAFETY: closing descriptors we own.
        unsafe {
            libc::close(self.rd);
            libc::close(self.wr);
        }
    }
}
