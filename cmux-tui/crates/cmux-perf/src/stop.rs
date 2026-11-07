//! SIGINT and SIGTERM end the window early. The handler only writes one byte
//! to a pipe (async-signal-safe); the sampling loop waits on that pipe with
//! the interval as its timeout, so a signal ends the wait at once instead of
//! at the next sample. The previous handlers come back when the recording ends.

use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::Duration;

static WRITE_FD: AtomicI32 = AtomicI32::new(-1);
static STOPPED: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_signal: libc::c_int) {
    STOPPED.store(true, Ordering::SeqCst);
    let fd = WRITE_FD.load(Ordering::SeqCst);
    if fd >= 0 {
        let byte = 1u8;
        // SAFETY: write is async-signal-safe; one byte from a valid buffer.
        let _ = unsafe { libc::write(fd, (&raw const byte).cast(), 1) };
    }
}

pub(crate) struct Stop {
    read_fd: libc::c_int,
    write_fd: libc::c_int,
    previous: Vec<(libc::c_int, libc::sigaction)>,
}

impl Stop {
    /// Installs the handlers. Without a pipe the window still ends at its length.
    pub(crate) fn install() -> Self {
        STOPPED.store(false, Ordering::SeqCst);
        let mut fds = [-1; 2];
        // SAFETY: `fds` is two ints.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            fds = [-1, -1];
        }
        WRITE_FD.store(fds[1], Ordering::SeqCst);
        let mut previous = Vec::new();
        for signal in [libc::SIGINT, libc::SIGTERM] {
            // SAFETY: zeroed sigaction structs are valid; the handler is an
            // extern "C" fn(c_int) that only touches atomics and write(2).
            unsafe {
                let mut action: libc::sigaction = std::mem::zeroed();
                action.sa_sigaction = on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t;
                libc::sigemptyset(&mut action.sa_mask);
                let mut old: libc::sigaction = std::mem::zeroed();
                if libc::sigaction(signal, &action, &mut old) == 0 {
                    previous.push((signal, old));
                }
            }
        }
        Self { read_fd: fds[0], write_fd: fds[1], previous }
    }

    /// Waits up to `timeout`; `true` when a signal asked to stop.
    pub(crate) fn wait(&self, timeout: Duration) -> bool {
        if STOPPED.load(Ordering::SeqCst) {
            return true;
        }
        if self.read_fd < 0 {
            // No pipe: the interval itself is the wait.
            std::thread::sleep(timeout);
            return STOPPED.load(Ordering::SeqCst);
        }
        let mut poll = libc::pollfd { fd: self.read_fd, events: libc::POLLIN, revents: 0 };
        let millis = libc::c_int::try_from(timeout.as_millis()).unwrap_or(libc::c_int::MAX);
        // SAFETY: one valid pollfd. EINTR (the signal itself) also returns here.
        let _ = unsafe { libc::poll(&mut poll, 1, millis) };
        STOPPED.load(Ordering::SeqCst)
    }
}

impl Drop for Stop {
    fn drop(&mut self) {
        for (signal, old) in &self.previous {
            // SAFETY: restores the action saved by `install`.
            unsafe { libc::sigaction(*signal, old, std::ptr::null_mut()) };
        }
        WRITE_FD.store(-1, Ordering::SeqCst);
        for fd in [self.read_fd, self.write_fd] {
            if fd >= 0 {
                // SAFETY: our own pipe ends, closed once.
                unsafe { libc::close(fd) };
            }
        }
    }
}
