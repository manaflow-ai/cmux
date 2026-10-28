//! `--exit-with-pid <pid>`: an owner bound to the process that started it.
//!
//! A detached owner outlives every client by design: the app's daemon keeps
//! the person's terminals across an app quit, crash or relaunch, and the app
//! re-attaches. A test or CI launcher is different: it starts an owner for
//! itself and stops it in its cleanup (`server stop --end-terminals`). When
//! the launcher is killed first (a cancelled job, SIGKILL), nothing stopped
//! the owner, and it kept its terminals and the runner's work tree for days
//! (HQ REPAIR.md "Orphaned cmux-tui holds runner dirs"). Such a launcher
//! passes its own pid (`server ensure --exit-with-pid $$`); once that
//! process dies, the owner ends its terminals (no one will adopt them) and
//! leaves through the normal shutdown path.
//!
//! One thread waits on the kernel's exit event for the pid (kqueue
//! `EVFILT_PROC`/`NOTE_EXIT` on macOS, a pidfd on Linux) together with a stop
//! pipe; no timer and no poll. It ends when the process exits (after it has
//! asked the owner to leave) or when the owner leaves for another reason:
//! [`BoundOwner::stop`] closes the pipe's write end, the thread wakes on its
//! end of file, and `stop` joins it.

use std::io;
use std::sync::{Arc, Weak};

use cmux_tui_core::Mux;

/// The running watch; [`BoundOwner::stop`] ends and joins it.
pub(crate) struct BoundOwner {
    stop: Option<io::PipeWriter>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl BoundOwner {
    pub(crate) fn stop(mut self) {
        drop(self.stop.take());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Binds this owner to `pid`. `None` when the watch cannot be armed (the
/// owner then keeps running, as an unbound owner does, and says so in its
/// log).
pub(crate) fn start(mux: &Arc<Mux>, pid: u32) -> Option<BoundOwner> {
    let armed = io::pipe().and_then(|(reader, writer)| Ok((Watch::new(pid, reader)?, writer)));
    let (watch, writer) = match armed {
        Ok(armed) => armed,
        Err(error) => {
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: cannot watch process {pid} (--exit-with-pid): {error}; this owner keeps running"
            );
            return None;
        }
    };
    let mux = Arc::downgrade(mux);
    let thread = std::thread::Builder::new()
        .name("bound-owner".into())
        .spawn(move || run(&watch, &mux, pid));
    match thread {
        Ok(thread) => Some(BoundOwner { stop: Some(writer), thread: Some(thread) }),
        Err(error) => {
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: cannot watch process {pid} (--exit-with-pid): {error}; this owner keeps running"
            );
            None
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Woke {
    /// The bound process exited (or was gone when the watch was armed).
    Exited,
    /// The owner is leaving: the stop pipe's write end closed.
    Stopped,
}

fn run(watch: &Watch, mux: &Weak<Mux>, pid: u32) {
    match watch.wait() {
        Ok(Woke::Stopped) => {}
        Ok(Woke::Exited) => {
            let Some(mux) = mux.upgrade() else { return };
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: process {pid} exited (--exit-with-pid); ending this owner's terminals and stopping"
            );
            if let Err(error) = mux.end_all_terminals() {
                crate::client_log::stderr_log!(
                    "lifecycle",
                    "{BIN}: ending the terminals of a bound owner failed: {error:#}"
                );
            }
            mux.request_daemon_shutdown();
        }
        Err(error) => {
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: watching process {pid} (--exit-with-pid) failed: {error}; this owner keeps running"
            );
        }
    }
}

#[cfg(target_vendor = "apple")]
struct Watch {
    queue: std::os::fd::OwnedFd,
    /// The process was gone when the watch was armed.
    gone: bool,
    _stop: io::PipeReader,
}

#[cfg(target_vendor = "apple")]
impl Watch {
    fn new(pid: u32, stop: io::PipeReader) -> io::Result<Self> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        let pid = libc::pid_t::try_from(pid).map_err(|_| io::ErrorKind::InvalidInput)?;
        // SAFETY: kqueue returns a new descriptor or -1.
        let raw = unsafe { libc::kqueue() };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a new descriptor this function owns.
        let queue = unsafe { OwnedFd::from_raw_fd(raw) };
        let change = |ident: usize, filter, fflags| {
            // SAFETY: kevent is plain data; all-zero is a valid value.
            let mut change: libc::kevent = unsafe { std::mem::zeroed() };
            change.ident = ident as _;
            change.filter = filter;
            // EV_RECEIPT: each registration reports its outcome as an
            // EV_ERROR event (data 0 on success) instead of a real event.
            change.flags = libc::EV_ADD | libc::EV_RECEIPT;
            change.fflags = fflags;
            change
        };
        let changes = [
            change(pid as usize, libc::EVFILT_PROC, libc::NOTE_EXIT),
            change(stop.as_raw_fd() as usize, libc::EVFILT_READ, 0),
        ];
        // SAFETY: as above.
        let mut receipts: [libc::kevent; 2] = unsafe { std::mem::zeroed() };
        // SAFETY: two changes in, at most two receipts out, no timeout.
        let n = unsafe {
            libc::kevent(
                queue.as_raw_fd(),
                changes.as_ptr(),
                2,
                receipts.as_mut_ptr(),
                2,
                std::ptr::null(),
            )
        };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut gone = false;
        for receipt in &receipts[..n as usize] {
            let code = receipt.data as i32;
            if receipt.flags & libc::EV_ERROR == 0 || code == 0 {
                continue;
            }
            // ESRCH: the process exited before the watch was added.
            if receipt.filter == libc::EVFILT_PROC && code == libc::ESRCH {
                gone = true;
            } else {
                return Err(io::Error::from_raw_os_error(code));
            }
        }
        Ok(Self { queue, gone, _stop: stop })
    }

    fn wait(&self) -> io::Result<Woke> {
        use std::os::fd::AsRawFd;
        if self.gone {
            return Ok(Woke::Exited);
        }
        loop {
            // SAFETY: kevent is plain data; all-zero is a valid value.
            let mut event: libc::kevent = unsafe { std::mem::zeroed() };
            // SAFETY: no changes, one event slot, no timeout.
            let n = unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    &mut event,
                    1,
                    std::ptr::null(),
                )
            };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if n == 0 {
                continue;
            }
            return Ok(if event.filter == libc::EVFILT_PROC {
                Woke::Exited
            } else {
                Woke::Stopped
            });
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
struct Watch {
    /// `None` when the process was gone when the watch was armed.
    pidfd: Option<std::os::fd::OwnedFd>,
    stop: io::PipeReader,
}

#[cfg(any(target_os = "linux", target_os = "android"))]
impl Watch {
    fn new(pid: u32, stop: io::PipeReader) -> io::Result<Self> {
        use std::os::fd::{FromRawFd, OwnedFd};
        let pid = libc::pid_t::try_from(pid).map_err(|_| io::ErrorKind::InvalidInput)?;
        // SAFETY: pidfd_open takes a pid and flags 0; it returns a new
        // descriptor or -1.
        let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if raw < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return Ok(Self { pidfd: None, stop });
            }
            return Err(error);
        }
        // SAFETY: a new descriptor this function owns.
        let pidfd = unsafe { OwnedFd::from_raw_fd(raw as libc::c_int) };
        Ok(Self { pidfd: Some(pidfd), stop })
    }

    fn wait(&self) -> io::Result<Woke> {
        use std::os::fd::AsRawFd;
        let Some(pidfd) = &self.pidfd else { return Ok(Woke::Exited) };
        let mut fds = [
            libc::pollfd { fd: self.stop.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            // The pidfd is readable once the process has exited.
            libc::pollfd { fd: pidfd.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        ];
        loop {
            // SAFETY: two live pollfds, no timeout.
            let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, -1) };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            // A leaving owner wins: its own shutdown is already running.
            if fds[0].revents != 0 {
                return Ok(Woke::Stopped);
            }
            if fds[1].revents != 0 {
                return Ok(Woke::Exited);
            }
        }
    }
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
struct Watch;

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
impl Watch {
    fn new(_pid: u32, _stop: io::PipeReader) -> io::Result<Self> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "no process exit event on this platform"))
    }

    fn wait(&self) -> io::Result<Woke> {
        Err(io::ErrorKind::Unsupported.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_watch_wakes_when_the_bound_process_exits() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "read line"])
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let (reader, _writer) = io::pipe().unwrap();
        let watch = Watch::new(child.id(), reader).unwrap();
        let waiter = std::thread::spawn(move || watch.wait().unwrap());
        drop(child.stdin.take());
        child.wait().unwrap();
        assert_eq!(waiter.join().unwrap(), Woke::Exited);
    }

    #[test]
    fn the_watch_ends_when_the_owner_stops_it() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "read line"])
            .stdin(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let (reader, writer) = io::pipe().unwrap();
        let watch = Watch::new(child.id(), reader).unwrap();
        let waiter = std::thread::spawn(move || watch.wait().unwrap());
        drop(writer);
        assert_eq!(waiter.join().unwrap(), Woke::Stopped);
        drop(child.stdin.take());
        child.wait().unwrap();
    }

    #[test]
    fn a_process_gone_before_the_watch_counts_as_exited() {
        let mut child =
            std::process::Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
        let pid = child.id();
        child.wait().unwrap();
        let (reader, _writer) = io::pipe().unwrap();
        assert_eq!(Watch::new(pid, reader).unwrap().wait().unwrap(), Woke::Exited);
    }
}
