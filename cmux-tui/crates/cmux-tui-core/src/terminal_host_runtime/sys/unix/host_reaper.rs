//! One thread reaps every committed terminal-host child (perf100 tui lane).
//!
//! A committed host lives on its own, but the daemon that spawned it must
//! still collect its exit status, or it stays a zombie. Each host used to get
//! its own `terminal-host-reaper` thread blocked in `wait4` for the host's
//! whole life: one thread per terminal (335 in one Chief daemon on
//! 2026-10-20). Now one `terminal-host-reaper` thread waits on a kernel
//! readiness queue (kqueue `EVFILT_PROC`/`NOTE_EXIT` on Apple platforms, a
//! pidfd in epoll on Linux) for every host, and blocks with no timeout while
//! no host exits. A platform without either, or a registration the kernel
//! refuses, falls back to the old per-host thread.
//!
//! Exit statuses are only collected with `try_wait` (`WNOHANG`): a stale or
//! early readiness event can never block the shared thread on a live child.

use std::collections::HashMap;
use std::process::Child;
use std::sync::{Mutex, OnceLock, PoisonError};
use std::thread;

/// Collect `child`'s exit status when it exits, without a thread of its own.
pub(crate) fn reap_when_exited(mut child: Child) {
    if matches!(child.try_wait(), Ok(Some(_))) {
        return;
    }
    match reaper() {
        Some(reaper) => reaper.watch(child),
        None => reap_on_own_thread(child),
    }
}

/// The pre-perf100 path: one thread blocked in `wait4` for this child.
fn reap_on_own_thread(mut child: Child) {
    let _ = thread::Builder::new().name("terminal-host-reaper".into()).spawn(move || {
        let _ = child.wait();
    });
}

struct Reaper {
    queue: queue::Queue,
    children: Mutex<HashMap<u32, Watched>>,
}

struct Watched {
    child: Child,
    /// Keeps the pidfd registered in epoll open while the child is watched.
    _handle: queue::Handle,
}

fn reaper() -> Option<&'static Reaper> {
    static REAPER: OnceLock<Option<&'static Reaper>> = OnceLock::new();
    *REAPER.get_or_init(|| {
        let queue = queue::Queue::new()?;
        let reaper: &'static Reaper =
            Box::leak(Box::new(Reaper { queue, children: Mutex::new(HashMap::new()) }));
        thread::Builder::new()
            .name("terminal-host-reaper".into())
            .spawn(move || reaper.run())
            .ok()?;
        Some(reaper)
    })
}

impl Reaper {
    fn watch(&self, child: Child) {
        let pid = child.id();
        // Insert before registering, so an exit event can never arrive for a
        // pid the map does not hold yet.
        let mut children = self.children.lock().unwrap_or_else(PoisonError::into_inner);
        let handle = match self.queue.register(pid) {
            Ok(handle) => handle,
            Err(_) => {
                drop(children);
                let mut child = child;
                // ESRCH: the child exited before registration (a zombie).
                if !matches!(child.try_wait(), Ok(Some(_))) {
                    reap_on_own_thread(child);
                }
                return;
            }
        };
        children.insert(pid, Watched { child, _handle: handle });
        // A child that exited between the first try_wait and registration
        // may not raise an event on every kernel: collect it now.
        if let Some(watched) = children.get_mut(&pid)
            && !matches!(watched.child.try_wait(), Ok(None))
        {
            children.remove(&pid);
        }
    }

    fn run(&self) {
        let mut ready = Vec::with_capacity(64);
        loop {
            ready.clear();
            if self.queue.wait(&mut ready).is_err() {
                // The queue failed (should not happen): hand every child to
                // its own thread and stop.
                let children: Vec<Watched> = self
                    .children
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .drain()
                    .map(|(_, watched)| watched)
                    .collect();
                for watched in children {
                    reap_on_own_thread(watched.child);
                }
                return;
            }
            let mut children = self.children.lock().unwrap_or_else(PoisonError::into_inner);
            for pid in ready.drain(..) {
                let Some(watched) = children.get_mut(&pid) else { continue };
                if !matches!(watched.child.try_wait(), Ok(None)) {
                    children.remove(&pid);
                    continue;
                }
                // Not reapable yet. Either the event came before the exiting
                // child became a zombie (XNU posts NOTE_EXIT first), or it is
                // a stale event for a pid now reused by a live child. Arm
                // again: the kernel refuses an exiting process (ESRCH), and
                // only then is a blocking wait certain to return at once.
                match self.queue.register(pid) {
                    Ok(handle) => watched._handle = handle,
                    Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {
                        if let Some(mut gone) = children.remove(&pid) {
                            let _ = gone.child.wait();
                        }
                    }
                    Err(_) => {
                        if let Some(gone) = children.remove(&pid) {
                            reap_on_own_thread(gone.child);
                        }
                    }
                }
            }
        }
    }
}

#[cfg(target_vendor = "apple")]
mod queue {
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

    pub(super) struct Queue(OwnedFd);
    pub(super) struct Handle;

    impl Queue {
        pub(super) fn new() -> Option<Self> {
            // SAFETY: kqueue takes no arguments; a non-negative result is a new
            // descriptor this process owns.
            let fd = unsafe { libc::kqueue() };
            // SAFETY: fd is a fresh kqueue descriptor owned by nobody else.
            (fd >= 0).then(|| Queue(unsafe { OwnedFd::from_raw_fd(fd) }))
        }

        pub(super) fn register(&self, pid: u32) -> io::Result<Handle> {
            let change = libc::kevent {
                ident: pid as libc::uintptr_t,
                filter: libc::EVFILT_PROC,
                flags: libc::EV_ADD | libc::EV_ONESHOT,
                fflags: libc::NOTE_EXIT,
                data: 0,
                udata: std::ptr::null_mut(),
            };
            // SAFETY: one valid change, no event buffer, and a null timeout;
            // registering from another thread while the reaper waits in
            // kevent is supported by kqueue.
            let result = unsafe {
                libc::kevent(
                    self.0.as_raw_fd(),
                    &change,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                )
            };
            if result < 0 { Err(io::Error::last_os_error()) } else { Ok(Handle) }
        }

        /// Blocks with no timeout until at least one watched child exits.
        pub(super) fn wait(&self, ready: &mut Vec<u32>) -> io::Result<()> {
            let mut events: [libc::kevent; 64] =
                // SAFETY: kevent is a plain C struct; all-zero is a valid value.
                unsafe { std::mem::zeroed() };
            loop {
                // SAFETY: the buffer holds 64 events and the timeout is null
                // (wait until an event arrives).
                let count = unsafe {
                    libc::kevent(
                        self.0.as_raw_fd(),
                        std::ptr::null(),
                        0,
                        events.as_mut_ptr(),
                        events.len() as libc::c_int,
                        std::ptr::null(),
                    )
                };
                if count < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                ready.extend(
                    events
                        .iter()
                        .take(usize::try_from(count).unwrap_or(0))
                        .map(|event| event.ident as u32),
                );
                return Ok(());
            }
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod queue {
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

    pub(super) struct Queue(OwnedFd);
    /// The child's pidfd; closing it removes it from the epoll set.
    pub(super) struct Handle(#[allow(dead_code)] OwnedFd);

    impl Queue {
        pub(super) fn new() -> Option<Self> {
            // SAFETY: epoll_create1 takes a flag word; a non-negative result is
            // a new descriptor this process owns.
            let fd = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
            // SAFETY: fd is a fresh epoll descriptor owned by nobody else.
            (fd >= 0).then(|| Queue(unsafe { OwnedFd::from_raw_fd(fd) }))
        }

        pub(super) fn register(&self, pid: u32) -> io::Result<Handle> {
            // SAFETY: pidfd_open takes a pid and a flag word and returns a new
            // descriptor (or -1). Called through syscall because older libcs
            // have no wrapper.
            let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: fd is a fresh pidfd owned by nobody else.
            let pidfd = unsafe { OwnedFd::from_raw_fd(fd as libc::c_int) };
            let mut event = libc::epoll_event { events: libc::EPOLLIN as u32, u64: pid as u64 };
            // SAFETY: both descriptors are valid and event is a valid pointer.
            let result = unsafe {
                libc::epoll_ctl(
                    self.0.as_raw_fd(),
                    libc::EPOLL_CTL_ADD,
                    pidfd.as_raw_fd(),
                    &mut event,
                )
            };
            if result < 0 { Err(io::Error::last_os_error()) } else { Ok(Handle(pidfd)) }
        }

        /// Blocks with no timeout until at least one watched child exits.
        pub(super) fn wait(&self, ready: &mut Vec<u32>) -> io::Result<()> {
            let mut events = [libc::epoll_event { events: 0, u64: 0 }; 64];
            loop {
                // SAFETY: the buffer holds 64 events; -1 waits with no timeout.
                let count = unsafe {
                    libc::epoll_wait(
                        self.0.as_raw_fd(),
                        events.as_mut_ptr(),
                        events.len() as libc::c_int,
                        -1,
                    )
                };
                if count < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                ready.extend(
                    events
                        .iter()
                        .take(usize::try_from(count).unwrap_or(0))
                        .map(|event| event.u64 as u32),
                );
                return Ok(());
            }
        }
    }
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
mod queue {
    use std::io;

    pub(super) struct Queue;
    pub(super) struct Handle;

    impl Queue {
        pub(super) fn new() -> Option<Self> {
            None
        }

        pub(super) fn register(&self, _pid: u32) -> io::Result<Handle> {
            Err(io::Error::from(io::ErrorKind::Unsupported))
        }

        pub(super) fn wait(&self, _ready: &mut Vec<u32>) -> io::Result<()> {
            Err(io::Error::from(io::ErrorKind::Unsupported))
        }
    }
}
