//! `--exit-with-pid <pid>[@<start ms>]`: an owner bound to its launcher.
//! A detached owner outlives every client by design (the app's daemon keeps
//! terminals across an app quit or crash). A CI launcher killed before its
//! cleanup left its owner running for days (HQ REPAIR.md "Orphaned cmux-tui
//! holds runner dirs"); a bound owner ends its terminals and shuts down once
//! that process exits. The watch is armed and its thread started before the
//! owner reports ready (failing either fails the start). The start time is
//! checked after the kernel watch is registered, so a reused pid counts as
//! exited. One thread blocks on the exit event (kqueue `NOTE_EXIT`, a Linux
//! pidfd) and a stop pipe, no timer; it ends on the exit, a failed wait, or
//! [`BoundOwner::stop`] (closes the pipe and joins it).

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

/// Arms the watch on `bound`'s process; an error fails the owner's start.
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
            Ok(thread) => Ok(BoundOwner { stop, thread }),
            Err(error) => {
                end_every_terminal(mux);
                Err(error)
            }
        }
    }
}

/// The running watch; [`BoundOwner::stop`] ends and joins it.
pub(crate) struct BoundOwner {
    stop: io::PipeWriter,
    thread: std::thread::JoinHandle<()>,
}

impl BoundOwner {
    pub(crate) fn stop(self) {
        drop(self.stop);
        let _ = self.thread.join();
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
            // The kernel's event first: a zombie still has its start time.
            if (watch.exited() || process.gone())
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

    /// Whether the exit event is pending now (no wait).
    fn exited(&self) -> bool {
        let now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        self.gone || matches!(self.poll(&now), Ok(Some(Woke::Exited)))
    }

    fn wait(&self) -> io::Result<Woke> {
        if self.gone {
            return Ok(Woke::Exited);
        }
        loop {
            if let Some(woke) = self.poll(std::ptr::null())? {
                return Ok(woke);
            }
        }
    }

    /// One `kevent` call (`timeout` null: no timeout). `None`: no event, or
    /// interrupted. The process's exit wins over a stop seen in the same call.
    fn poll(&self, timeout: *const libc::timespec) -> io::Result<Option<Woke>> {
        use std::os::fd::AsRawFd;
        // SAFETY: kevent is plain data; all-zero is a valid value.
        let mut events: [libc::kevent; 2] = unsafe { std::mem::zeroed() };
        // SAFETY: no changes, two event slots, a null or live timeout.
        let n = unsafe {
            libc::kevent(
                self.queue.as_raw_fd(),
                std::ptr::null(),
                0,
                events.as_mut_ptr(),
                2,
                timeout,
            )
        };
        if n < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::Interrupted { Ok(None) } else { Err(error) };
        }
        let events = &events[..n as usize];
        Ok(if events.iter().any(|event| event.filter == libc::EVFILT_PROC) {
            Some(Woke::Exited)
        } else {
            (!events.is_empty()).then_some(Woke::Stopped)
        })
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

    /// Whether the process has exited now (no wait): the pidfd is readable.
    fn exited(&self) -> bool {
        matches!(self.poll(0), Ok(Some(Woke::Exited)))
    }

    fn wait(&self) -> io::Result<Woke> {
        loop {
            if let Some(woke) = self.poll(-1)? {
                return Ok(woke);
            }
        }
    }

    /// One `poll` (`timeout` -1: no timeout). `None`: no event, or
    /// interrupted. The process's exit wins over a stop seen in the same call.
    fn poll(&self, timeout: libc::c_int) -> io::Result<Option<Woke>> {
        use std::os::fd::AsRawFd;
        let Some(pidfd) = &self.pidfd else { return Ok(Some(Woke::Exited)) };
        let mut fds = [pidfd.as_raw_fd(), self.stop.as_raw_fd()].map(|fd| libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        });
        // SAFETY: two live pollfds.
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) } < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::Interrupted { Ok(None) } else { Err(error) };
        }
        // The pidfd is readable once the process has exited.
        Ok(if fds[0].revents != 0 {
            Some(Woke::Exited)
        } else {
            (fds[1].revents != 0).then_some(Woke::Stopped)
        })
    }
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
struct Watch;

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
impl Watch {
    fn new(_pid: u32, _stop: io::PipeReader) -> io::Result<Self> {
        Err(io::ErrorKind::Unsupported.into())
    }
    fn wait(&self) -> io::Result<Woke> {
        Err(io::ErrorKind::Unsupported.into())
    }
    fn exited(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Child, Command, Stdio};

    /// A child that runs until its stdin closes.
    fn waiting_child() -> Child {
        let stdin = Stdio::piped();
        Command::new("/bin/sh").args(["-c", "read line"]).stdin(stdin).spawn().unwrap()
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
        drop(writer);
        assert_eq!(watch.wait().unwrap(), Woke::Stopped);
        assert!(!watch.exited(), "a running process counted as exited");
        end(child);
        // Exited but not reaped (a zombie still has its start time): the
        // kernel's event says so without a wait.
        let mut zombie = Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
        let (reader, _writer) = io::pipe().unwrap();
        let watch = Watch::new(zombie.id(), reader).unwrap();
        assert_eq!(watch.wait().unwrap(), Woke::Exited);
        assert!(watch.exited());
        zombie.wait().unwrap();
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

        // A process that exited and was reaped: its pid names nothing.
        let mut gone = Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
        gone.wait().unwrap();
        let gone = gone.id();
        assert!(arm(BoundPid { pid: gone, started_ms: None }).is_err());
        let (reader, _writer) = io::pipe().unwrap();
        assert_eq!(Watch::new(gone, reader).unwrap().wait().unwrap(), Woke::Exited);
    }
}
