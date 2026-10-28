//! `--exit-with-pid <pid>`: an owner bound to the process that started it.
//!
//! A detached owner outlives every client by design: the app's daemon keeps
//! the person's terminals across an app quit, crash or relaunch, and the app
//! re-attaches. A test or CI launcher is different: it starts an owner for
//! itself and stops it in its cleanup (`server stop --end-terminals`). When
//! the launcher is killed first (a cancelled job, SIGKILL), nothing stopped
//! the owner, and it kept its terminals and the runner's work tree for days
//! (HQ REPAIR.md "Orphaned cmux-tui holds runner dirs"). Such a launcher
//! passes its own pid (`--headless --exit-with-pid $$`); once that
//! process dies, the owner ends its terminals (no one will adopt them) and
//! leaves through the normal shutdown path.
//!
//! The watch is armed at startup, before the owner reports itself ready, so
//! an owner asked to exit with a process never runs unbound: a watch that
//! cannot be armed (no pidfd on an old Linux kernel, a seccomp denial) fails
//! the start. A launcher may pass the process's start time with its pid
//! (`<pid>@<ms>`); without it the owner reads it before arming. Once the
//! watch is armed the owner compares it, so a pid that was reused
//! before the watch counts as the process having exited. When the owner
//! stops while the bound process has exited too, its terminals still end.
//!
//! One thread waits on the kernel's exit event for the pid (kqueue
//! `EVFILT_PROC`/`NOTE_EXIT` on macOS, a pidfd on Linux) together with a stop
//! pipe; no timer and no poll. It ends when the process exits (after it has
//! asked the owner to leave), when the wait itself fails (it then also asks
//! the owner to leave: a bound owner never keeps running unwatched), or when
//! the owner leaves for another reason: [`BoundOwner::stop`] closes the
//! pipe's write end, the thread wakes on its end of file, and `stop` joins
//! it.

use std::io;
use std::sync::{Arc, Weak};

use cmux_tui_core::Mux;

use crate::BoundPid;

/// A watch armed at startup; [`Armed::start`] runs it once the mux exists.
pub(crate) struct Armed {
    process: Process,
    watch: Watch,
    stop: io::PipeWriter,
    /// The pid now names another process than the bound one.
    reused: bool,
}

/// The bound process: its pid and when it started.
#[derive(Clone, Copy)]
struct Process {
    pid: u32,
    started_ms: u64,
}

impl Process {
    /// The pid no longer names this process (it exited, or was reused).
    fn gone(self) -> bool {
        cmux_tui_core::process_started_ms(self.pid) != Some(self.started_ms)
    }
}

/// Arms the watch on `bound`'s process. An error fails the owner's start.
/// The start time comes from the launcher (`<pid>@<ms>`), else it is read
/// here, before the watch, and the start fails when it cannot be.
pub(crate) fn arm(bound: BoundPid) -> io::Result<Armed> {
    let started_ms = match bound.started_ms {
        Some(started) => started,
        None => cmux_tui_core::process_started_ms(bound.pid).ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, format!("process {} is not running", bound.pid))
        })?,
    };
    let process = Process { pid: bound.pid, started_ms };
    let (reader, stop) = io::pipe()?;
    let watch = Watch::new(bound.pid, reader)?;
    // After the watch is registered, the pid cannot be reused unseen: a
    // start time other than the recorded one (or none: gone) means the
    // bound process already exited.
    let reused = process.gone();
    Ok(Armed { process, watch, stop, reused })
}

impl Armed {
    /// Starts the watching thread for this owner, before it reports itself
    /// ready. When the thread cannot start, the owner must not keep its
    /// terminals unwatched: they are ended here (with the survivor sweep)
    /// and the error fails the start.
    pub(crate) fn start(self, mux: &Arc<Mux>) -> io::Result<BoundOwner> {
        let Self { process, watch, stop, reused } = self;
        let weak = Arc::downgrade(mux);
        let thread = std::thread::Builder::new()
            .name("bound-owner".into())
            .spawn(move || run(&watch, reused, &weak, process));
        match thread {
            Ok(thread) => Ok(BoundOwner { stop: Some(stop), thread: Some(thread) }),
            Err(error) => {
                end_every_terminal(mux);
                Err(error)
            }
        }
    }
}

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

#[derive(Debug, PartialEq, Eq)]
enum Woke {
    /// The bound process exited (or was gone when the watch was armed).
    Exited,
    /// The owner is leaving: the stop pipe's write end closed.
    Stopped,
}

fn run(watch: &Watch, reused: bool, mux: &Weak<Mux>, process: Process) {
    let pid = process.pid;
    let woke = if reused { Ok(Woke::Exited) } else { watch.wait() };
    match woke {
        // The owner is leaving for its own reason. If the bound process
        // exited too (both events at once), its terminals still end: a
        // normal shutdown would keep them for an adopter that never comes.
        Ok(Woke::Stopped) => {
            if process.gone()
                && let Some(mux) = mux.upgrade()
            {
                crate::client_log::stderr_log!(
                    "lifecycle",
                    "{BIN}: process {pid} exited (--exit-with-pid) as this owner stopped; ending its terminals"
                );
                end_every_terminal(&mux);
            }
            return;
        }
        Ok(Woke::Exited) => crate::client_log::stderr_log!(
            "lifecycle",
            "{BIN}: process {pid} exited (--exit-with-pid); ending this owner's terminals and stopping"
        ),
        Err(error) => crate::client_log::stderr_log!(
            "lifecycle",
            "{BIN}: watching process {pid} (--exit-with-pid) failed: {error}; ending this owner's terminals and stopping"
        ),
    }
    let Some(mux) = mux.upgrade() else { return };
    end_every_terminal(&mux);
    mux.request_daemon_shutdown();
}

/// Ends every terminal of this owner, and every host still running by its
/// record when that fails, so none outlives a bound owner.
fn end_every_terminal(mux: &Mux) {
    if let Err(error) = mux.end_all_terminals() {
        crate::client_log::stderr_log!(
            "lifecycle",
            "{BIN}: ending the terminals of a bound owner failed: {error:#}"
        );
        // end_all_terminals can stop before its own survivor sweep: end
        // every host still running by its record, so none outlives us.
        let survivors = mux.end_surviving_terminal_hosts();
        if !survivors.is_empty() {
            crate::client_log::stderr_log!(
                "lifecycle",
                "{BIN}: terminal hosts still running after a bound owner's exit: {}",
                survivors.join(", ")
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
            let mut events: [libc::kevent; 2] = unsafe { std::mem::zeroed() };
            // SAFETY: no changes, two event slots, no timeout.
            let n = unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    events.as_mut_ptr(),
                    2,
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
            // The process's exit wins over a stop seen in the same call.
            let exited = events[..n as usize].iter().any(|event| event.filter == libc::EVFILT_PROC);
            return Ok(if exited { Woke::Exited } else { Woke::Stopped });
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
            // The process's exit wins over a stop seen in the same call.
            if fds[1].revents != 0 {
                return Ok(Woke::Exited);
            }
            if fds[0].revents != 0 {
                return Ok(Woke::Stopped);
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
    use std::process::{Child, Command, Stdio};

    /// A child that runs until its stdin closes, and the pid of one that
    /// has exited and been reaped.
    fn waiting_child() -> Child {
        let stdin = Stdio::piped();
        Command::new("/bin/sh").args(["-c", "read line"]).stdin(stdin).spawn().unwrap()
    }

    fn gone_pid() -> u32 {
        let mut child = Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
        child.wait().unwrap();
        child.id()
    }

    fn end(mut child: Child) {
        drop(child.stdin.take());
        child.wait().unwrap();
    }

    #[test]
    fn the_watch_wakes_on_exit_and_ends_on_stop() {
        let child = waiting_child();
        let (reader, _writer) = io::pipe().unwrap();
        let watch = Watch::new(child.id(), reader).unwrap();
        let exited = std::thread::spawn(move || watch.wait().unwrap());
        end(child);
        assert_eq!(exited.join().unwrap(), Woke::Exited);

        let child = waiting_child();
        let (reader, writer) = io::pipe().unwrap();
        let watch = Watch::new(child.id(), reader).unwrap();
        let stopped = std::thread::spawn(move || watch.wait().unwrap());
        drop(writer);
        assert_eq!(stopped.join().unwrap(), Woke::Stopped);
        end(child);
    }

    #[test]
    fn a_reused_or_gone_pid_counts_as_exited() {
        let child = waiting_child();
        let pid = child.id();
        let started = cmux_tui_core::process_started_ms(pid);
        assert!(started.is_some(), "no start time for a live child");
        assert!(!arm(BoundPid { pid, started_ms: started }).unwrap().reused);
        assert!(!arm(BoundPid { pid, started_ms: None }).unwrap().reused);
        let other = started.map(|started| started.wrapping_sub(60_000));
        assert!(arm(BoundPid { pid, started_ms: other }).unwrap().reused);
        end(child);

        let gone = gone_pid();
        assert!(arm(BoundPid { pid: gone, started_ms: None }).is_err());
        let (reader, _writer) = io::pipe().unwrap();
        assert_eq!(Watch::new(gone, reader).unwrap().wait().unwrap(), Woke::Exited);
    }
}
