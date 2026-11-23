//! One thread hears every process exit acpmux follows (RFD 0049 R5: a session acpmux did not
//! start is dead when the kernel says its process exited, never because a heartbeat was missed).
//!
//! [`watch`] arms the kernel's exit event for a pid: a pidfd in one epoll set on Linux, an
//! `EVFILT_PROC` `NOTE_EXIT` filter in one kqueue on macOS. A single thread blocks in that set with
//! no timeout and runs a pid's callbacks once its process exits, so a thousand watched sessions
//! cost one thread and no polling. A stopped process (SIGSTOP) or one starved of CPU has not
//! exited, so it never fires.
//!
//! A pid alone does not name one process: it is reused once its process is gone. [`watch`] takes
//! the start time the caller saw ([`crate::owner_exit::process_start`]) and checks it once the
//! event is armed (the armed event then holds that process): a different process under the pid
//! counts as the watched one's exit, and its own exit never fires the watched one's callbacks.

use std::collections::HashMap;
use std::io;
use std::sync::{Mutex, OnceLock};

type OnExit = Box<dyn FnOnce() + Send>;

struct Armed {
    start: Option<u64>,
    /// The pidfd in the epoll set; closing it takes it out of the set.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    _fd: std::os::fd::OwnedFd,
    calls: Vec<OnExit>,
}

struct Watcher {
    queue: imp::Queue,
    armed: Mutex<HashMap<u32, Armed>>,
}

/// The process-wide watcher, started at the first [`watch`]; `Err` when this host has no exit
/// event (no pidfd, an old kernel), said once in the log.
fn watcher() -> io::Result<&'static Watcher> {
    static WATCHER: OnceLock<Result<Watcher, String>> = OnceLock::new();
    let made = WATCHER.get_or_init(|| {
        let queue = imp::Queue::new().map_err(|e| e.to_string())?;
        Ok(Watcher { queue, armed: Mutex::new(HashMap::new()) })
    });
    match made {
        Ok(watcher) => {
            static THREAD: OnceLock<Result<(), String>> = OnceLock::new();
            THREAD
                .get_or_init(|| {
                    std::thread::Builder::new()
                        .name("acpmux-proc-exit".into())
                        .spawn(move || run(watcher))
                        .map(drop)
                        .map_err(|e| e.to_string())
                })
                .clone()
                .map_err(io::Error::other)?;
            Ok(watcher)
        }
        Err(error) => Err(io::Error::other(error.clone())),
    }
}

/// Runs `on_exit` once the process `pid` names exits: on the watcher thread, so it must not
/// block. `start` is the process's start time as the caller saw it; when `pid` already names
/// another process (or none), `on_exit` runs at once, on this thread. `Err`: this host cannot
/// watch exits, and `on_exit` is dropped unrun.
pub fn watch(
    pid: u32,
    start: Option<u64>,
    on_exit: impl FnOnce() + Send + 'static,
) -> io::Result<()> {
    let watcher = watcher()?;
    let on_exit: OnExit = Box::new(on_exit);
    let mut armed = watcher.armed.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(entry) = armed.get_mut(&pid) {
        // The armed process still runs (its exit takes the entry out), so a caller who saw a
        // different start saw a process that is gone.
        if start.is_none() || entry.start.is_none() || entry.start == start {
            entry.calls.push(on_exit);
        } else {
            drop(armed);
            on_exit();
        }
        return Ok(());
    }
    let added = match watcher.queue.add(pid) {
        Ok(added) => added,
        Err(error) if gone(&error) => {
            drop(armed);
            on_exit();
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    // The event holds a process now: the pid's start is read from the process it holds.
    let now = crate::owner_exit::process_start(pid);
    if start.is_some_and(|start| now != Some(start)) {
        watcher.queue.remove(pid, added);
        drop(armed);
        on_exit();
        return Ok(());
    }
    armed.insert(
        pid,
        Armed {
            start: start.or(now),
            #[cfg(any(target_os = "linux", target_os = "android"))]
            _fd: added,
            calls: vec![on_exit],
        },
    );
    Ok(())
}

/// Whether `pid` is armed now (tests).
#[cfg(test)]
fn armed(pid: u32) -> bool {
    watcher().is_ok_and(|w| w.armed.lock().unwrap_or_else(|e| e.into_inner()).contains_key(&pid))
}

fn run(watcher: &'static Watcher) {
    let mut exited = Vec::new();
    loop {
        exited.clear();
        if let Err(error) = watcher.queue.wait(&mut exited) {
            tracing::warn!(%error, "the process exit watch stopped");
            return;
        }
        for pid in &exited {
            let entry = watcher.armed.lock().unwrap_or_else(|e| e.into_inner()).remove(pid);
            for call in entry.into_iter().flat_map(|e| e.calls) {
                call();
            }
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux", target_os = "android"))]
fn gone(error: &io::Error) -> bool {
    error.raw_os_error() == Some(libc::ESRCH)
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "android")))]
fn gone(_error: &io::Error) -> bool {
    false
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod imp {
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};

    /// One epoll set of pidfds; each event's data is its pid.
    pub(super) struct Queue(OwnedFd);

    impl Queue {
        pub(super) fn new() -> io::Result<Self> {
            // SAFETY: epoll_create1 takes flags only.
            let raw = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
            if raw < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: `raw` is a new descriptor this queue owns.
            Ok(Self(unsafe { OwnedFd::from_raw_fd(raw) }))
        }

        /// Opens `pid`'s pidfd and adds it to the set; ESRCH when it is gone.
        pub(super) fn add(&self, pid: u32) -> io::Result<OwnedFd> {
            let pid_t = libc::pid_t::try_from(pid)
                .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
            // SAFETY: pidfd_open takes a pid and flags 0.
            let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid_t, 0) };
            if raw < 0 {
                return Err(io::Error::last_os_error());
            }
            let raw =
                i32::try_from(raw).map_err(|_| io::Error::from(io::ErrorKind::InvalidData))?;
            // SAFETY: `raw` is a new descriptor the caller owns.
            let fd = unsafe { OwnedFd::from_raw_fd(raw) };
            // The pidfd is not inherited by a process acpmux starts.
            // SAFETY: F_SETFD on a descriptor this function owns.
            unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
            let mut event = libc::epoll_event { events: libc::EPOLLIN as u32, u64: u64::from(pid) };
            // SAFETY: both descriptors are open; `event` is valid for the call.
            if unsafe { libc::epoll_ctl(self.0.as_raw_fd(), libc::EPOLL_CTL_ADD, raw, &mut event) }
                < 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(fd)
        }

        /// Takes `pid`'s pidfd out: closing it does.
        pub(super) fn remove(&self, _pid: u32, fd: OwnedFd) {
            drop(fd);
        }

        /// Blocks until one or more watched processes exited, and appends their pids.
        pub(super) fn wait(&self, exited: &mut Vec<u32>) -> io::Result<()> {
            // SAFETY: epoll_event is plain data; all-zero is a valid value.
            let mut events: [libc::epoll_event; 32] = unsafe { std::mem::zeroed() };
            loop {
                // SAFETY: `events` holds 32 slots, valid for the call; no timeout.
                let n =
                    unsafe { libc::epoll_wait(self.0.as_raw_fd(), events.as_mut_ptr(), 32, -1) };
                if n < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                let n = usize::try_from(n).unwrap_or(0);
                // `epoll_event` is packed on x86_64: copy the field out before use.
                exited.extend(events[..n].iter().filter_map(|e| {
                    let data = e.u64;
                    u32::try_from(data).ok()
                }));
                return Ok(());
            }
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};

    /// One kqueue of `EVFILT_PROC` `NOTE_EXIT` filters, one per pid.
    pub(super) struct Queue(OwnedFd);

    impl Queue {
        pub(super) fn new() -> io::Result<Self> {
            // SAFETY: kqueue has no preconditions.
            let raw = unsafe { libc::kqueue() };
            if raw < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: `raw` is a new descriptor this queue owns.
            let queue = unsafe { OwnedFd::from_raw_fd(raw) };
            // SAFETY: F_SETFD on a descriptor this function owns.
            unsafe { libc::fcntl(queue.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
            Ok(Self(queue))
        }

        fn change(&self, pid: u32, flags: u16) -> io::Result<()> {
            // SAFETY: kevent is plain data; all-zero is a valid value.
            let mut change: libc::kevent = unsafe { std::mem::zeroed() };
            change.ident = pid as usize;
            change.filter = libc::EVFILT_PROC;
            change.flags = flags;
            change.fflags = libc::NOTE_EXIT;
            let now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
            loop {
                // SAFETY: one change, no event slot, a zero timeout; all valid for the call.
                let n = unsafe {
                    libc::kevent(self.0.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, &now)
                };
                if n >= 0 {
                    return Ok(());
                }
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }

        /// Adds `pid`'s exit filter; ESRCH when it is gone.
        pub(super) fn add(&self, pid: u32) -> io::Result<()> {
            self.change(pid, libc::EV_ADD | libc::EV_ONESHOT)
        }

        /// Takes `pid`'s filter out (already gone: nothing to take).
        pub(super) fn remove(&self, pid: u32, _added: ()) {
            let _ = self.change(pid, libc::EV_DELETE);
        }

        /// Blocks until one or more watched processes exited, and appends their pids.
        pub(super) fn wait(&self, exited: &mut Vec<u32>) -> io::Result<()> {
            // SAFETY: kevent is plain data; all-zero is a valid value.
            let mut events: [libc::kevent; 32] = unsafe { std::mem::zeroed() };
            loop {
                // SAFETY: no change and 32 event slots, valid for the call; no timeout.
                let n = unsafe {
                    libc::kevent(
                        self.0.as_raw_fd(),
                        std::ptr::null(),
                        0,
                        events.as_mut_ptr(),
                        32,
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
                let n = usize::try_from(n).unwrap_or(0);
                // An EV_ERROR event (ESRCH: the process went before the filter held it) is an
                // exit too.
                exited.extend(events[..n].iter().filter_map(|e| u32::try_from(e.ident).ok()));
                return Ok(());
            }
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "android")))]
mod imp {
    use std::io;

    /// No exit event here: nothing is watched.
    pub(super) struct Queue;

    impl Queue {
        pub(super) fn new() -> io::Result<Self> {
            Err(io::Error::from(io::ErrorKind::Unsupported))
        }
        pub(super) fn add(&self, _pid: u32) -> io::Result<()> {
            Err(io::Error::from(io::ErrorKind::Unsupported))
        }
        pub(super) fn remove(&self, _pid: u32, _added: ()) {}
        pub(super) fn wait(&self, _exited: &mut Vec<u32>) -> io::Result<()> {
            Err(io::Error::from(io::ErrorKind::Unsupported))
        }
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
#[path = "proc_exit_tests.rs"]
mod tests;
