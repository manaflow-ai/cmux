//! One `child-exit` thread for every child of this process: one kqueue with
//! an `EVFILT_PROC` `NOTE_EXIT` event per child on macOS, one epoll set with
//! a pidfd per child on Linux. A caller hands [`ExitWatcher::register`] a pid
//! and a callback; the thread runs the callback once the child has ended,
//! instead of the caller parking a thread of its own in `waitpid`.
//!
//! Chrome waits for a child's exit as a kernel event, not a poll: kqueue
//! `NOTE_EXIT` in `base/process/kill_mac.cc` (`WaitForChildToDie`). It still
//! spends a task per child there; this watcher folds every child's event
//! into one kqueue, as `base/message_loop/message_pump_kqueue.cc` folds
//! every descriptor watch of Chrome's IO thread into one.
//!
//! The watcher never reaps: a callback sees a child that waits as a zombie,
//! so its pid is still its own (a signal to its group cannot reach a reused
//! pid), and reaps it itself (`Child::wait`, which no longer blocks then)
//! or leaves that to whoever owns the child.

use std::collections::HashMap;
use std::io;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, OnceLock, mpsc};

use cmux_threads::ThreadQos;

/// The thread's label in the thread registry and threading-model.md.
const THREAD_NAME: &str = "child-exit";

/// Run on the `child-exit` thread once the child ended. It must not block:
/// it sends, signals, or reaps the ended child (which returns at once).
type Callback = Box<dyn FnOnce() + Send + 'static>;

enum Request {
    Watch(u32, Callback),
    Stop,
}

/// A handle to a `child-exit` thread. Dropping it stops the thread once the
/// children it watches have ended (their callbacks still run).
pub struct ExitWatcher {
    requests: mpsc::Sender<Request>,
    waker: Arc<sys::Waker>,
}

/// The watcher of this process's children. Children are a process resource
/// (the kernel's child table is per process), as threads are for
/// `cmux_threads::registry`: one watcher serves them all.
static PROCESS: OnceLock<ExitWatcher> = OnceLock::new();

impl ExitWatcher {
    /// Start a `child-exit` thread of its own (tests; the daemon uses
    /// [`ExitWatcher::process`]).
    pub fn start() -> io::Result<Self> {
        Self::start_with(true)
    }

    /// `kernel_watch` false: every child takes the `waitid` thread fallback.
    fn start_with(kernel_watch: bool) -> io::Result<Self> {
        let poller = sys::Poller::new()?;
        let waker = poller.waker();
        let (requests, inbox) = mpsc::channel();
        let (exited, exits) = mpsc::channel();
        let mut watches = Watches {
            poller,
            inbox,
            exited,
            exits,
            watches: HashMap::new(),
            stopping: false,
            kernel_watch,
        };
        cmux_threads::spawn(THREAD_NAME, ThreadQos::Utility, move || watches.run())?;
        Ok(Self { requests, waker })
    }

    /// The process's watcher, started by its first use. A start that fails
    /// (no thread) is tried again by the next use.
    pub fn process() -> io::Result<&'static Self> {
        if let Some(watcher) = PROCESS.get() {
            return Ok(watcher);
        }
        let started = Self::start()?;
        // Two first uses at once: the loser's watcher is dropped, which
        // stops its thread (it watches nothing).
        Ok(PROCESS.get_or_init(move || started))
    }

    /// Run `on_exit` on the `child-exit` thread once child `pid` has ended,
    /// at once when it already has. `pid` must be a child of this process
    /// that nobody has reaped (so it cannot have been reused). Callbacks for
    /// the same pid run in the order they were registered.
    pub fn register(&self, pid: u32, on_exit: impl FnOnce() + Send + 'static) -> io::Result<()> {
        self.requests
            .send(Request::Watch(pid, Box::new(on_exit)))
            .map_err(|_| io::Error::other("the child-exit watcher stopped"))?;
        self.waker.wake()
    }

    /// A watcher that never uses the kernel's per-process event (kqueue or
    /// pidfd), so every child takes the `waitid` thread fallback.
    #[cfg(test)]
    pub(crate) fn start_without_kernel_watch() -> io::Result<Self> {
        Self::start_with(false)
    }
}

impl Drop for ExitWatcher {
    fn drop(&mut self) {
        let _ = self.requests.send(Request::Stop);
        let _ = self.waker.wake();
    }
}

impl std::fmt::Debug for ExitWatcher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExitWatcher").finish_non_exhaustive()
    }
}

/// One watched child: its kernel watch (none while a `waitid` thread waits
/// for it instead) and the callbacks for its exit.
struct Watch {
    _kernel: Option<sys::KernelWatch>,
    callbacks: Vec<Callback>,
}

/// The `child-exit` thread's state.
struct Watches {
    poller: sys::Poller,
    inbox: mpsc::Receiver<Request>,
    /// `waitid` fallback threads report an exit here, then wake the poller.
    exited: mpsc::Sender<u32>,
    exits: mpsc::Receiver<u32>,
    watches: HashMap<u32, Watch>,
    stopping: bool,
    /// False only in tests of the fallback.
    kernel_watch: bool,
}

impl Watches {
    fn run(&mut self) {
        let mut events = Vec::new();
        while !(self.stopping && self.watches.is_empty()) {
            if self.poller.wait(&mut events).is_err() {
                // The kqueue or epoll set itself failed: nothing can wake
                // this thread again. Dropping the inbox fails later
                // registrations instead of losing them.
                return;
            }
            // Exits before registrations: an exit in this batch happened
            // before any registration it shares the batch with, so a pid
            // reaped and reused in between gets the new child's watch, not
            // the old child's event.
            let mut woken = false;
            for event in events.drain(..) {
                match event {
                    sys::Event::Wake => woken = true,
                    sys::Event::Exit(pid) => self.fire(pid),
                }
            }
            if woken {
                self.drain();
            }
        }
    }

    /// Take every queued registration and every fallback exit.
    fn drain(&mut self) {
        loop {
            match self.inbox.try_recv() {
                Ok(Request::Watch(pid, callback)) => self.watch(pid, callback),
                Ok(Request::Stop) | Err(mpsc::TryRecvError::Disconnected) => {
                    self.stopping = true;
                    break;
                }
                Err(mpsc::TryRecvError::Empty) => break,
            }
        }
        while let Ok(pid) = self.exits.try_recv() {
            self.fire(pid);
        }
    }

    fn watch(&mut self, pid: u32, callback: Callback) {
        if let Some(watch) = self.watches.get_mut(&pid) {
            watch.callbacks.push(callback);
            return;
        }
        let kernel = if self.kernel_watch {
            self.poller.watch(pid)
        } else {
            Err(io::Error::from_raw_os_error(libc::ENOSYS))
        };
        match kernel {
            Ok(kernel) => {
                self.watches
                    .insert(pid, Watch { _kernel: Some(kernel), callbacks: vec![callback] });
            }
            // A zombie (macOS: `EV_ADD` of an exited process fails with
            // ESRCH) or a pid that is gone: nothing left to wait for.
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => run(callback),
            // Linux before 5.3 or a seccomp profile without `pidfd_open`,
            // or no descriptor left: a thread blocked in `waitid` for this
            // child, which reports through `exits`.
            Err(_) => match spawn_waitid(pid, self.exited.clone(), self.poller.waker()) {
                Ok(()) => {
                    self.watches.insert(pid, Watch { _kernel: None, callbacks: vec![callback] });
                }
                // No event and no thread: the callback cannot run.
                Err(_) => drop(callback),
            },
        }
    }

    fn fire(&mut self, pid: u32) {
        let Some(watch) = self.watches.remove(&pid) else { return };
        for callback in watch.callbacks {
            run(callback);
        }
    }
}

/// A panicking callback must not end the thread every other child's exit
/// depends on.
fn run(callback: Callback) {
    let _ = catch_unwind(AssertUnwindSafe(callback));
}

/// A thread blocked in `waitid(WEXITED | WNOWAIT)` until `pid` ends (without
/// reaping it), which then reports the exit to the watcher: the wait where
/// the kernel gives no per-process event.
fn spawn_waitid(pid: u32, exited: mpsc::Sender<u32>, waker: Arc<sys::Waker>) -> io::Result<()> {
    cmux_threads::spawn("child-exit-waitid", ThreadQos::Utility, move || {
        loop {
            // SAFETY: zeroed siginfo_t is valid output storage.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            // SAFETY: waitid writes one siginfo_t; WNOWAIT leaves the child
            // to its owner's wait.
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid as libc::id_t,
                    &mut info,
                    libc::WEXITED | libc::WNOWAIT,
                )
            };
            if result == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                break;
            }
        }
        if exited.send(pid).is_ok() {
            let _ = waker.wake();
        }
    })
    .map(drop)
}

#[cfg(target_vendor = "apple")]
mod sys {
    //! One kqueue: `EVFILT_PROC` `NOTE_EXIT` per child, `EVFILT_USER` to wake.

    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::sync::Arc;

    pub(super) enum Event {
        Wake,
        Exit(u32),
    }

    /// The `EVFILT_USER` ident of the wake event.
    const WAKE: libc::uintptr_t = 0;

    pub(super) struct Poller {
        queue: Arc<OwnedFd>,
        waker: Arc<Waker>,
    }

    pub(super) struct Waker {
        queue: Arc<OwnedFd>,
    }

    /// An `EVFILT_PROC` event is `EV_ONESHOT`: the kernel drops it with the
    /// exit it reports, so there is nothing to undo.
    pub(super) struct KernelWatch;

    fn event(ident: libc::uintptr_t, filter: i16, flags: u16, fflags: u32) -> libc::kevent {
        libc::kevent { ident, filter, flags, fflags, data: 0, udata: std::ptr::null_mut() }
    }

    /// Apply one change and return its own result (`EV_RECEIPT`: no pending
    /// event is taken).
    fn change(queue: &OwnedFd, mut change: libc::kevent) -> io::Result<()> {
        change.flags |= libc::EV_RECEIPT;
        let zero = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        loop {
            // SAFETY: zeroed kevent is valid output storage.
            let mut receipt: libc::kevent = unsafe { std::mem::zeroed() };
            // SAFETY: one change in, one receipt out, a live timeout.
            let n = unsafe { libc::kevent(queue.as_raw_fd(), &change, 1, &mut receipt, 1, &zero) };
            if n == 1 && receipt.flags & libc::EV_ERROR != 0 && receipt.data != 0 {
                return Err(io::Error::from_raw_os_error(receipt.data as i32));
            }
            if n >= 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }

    impl Poller {
        pub(super) fn new() -> io::Result<Self> {
            // SAFETY: kqueue returns a new descriptor or -1.
            let raw = unsafe { libc::kqueue() };
            if raw < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: a new descriptor this poller owns.
            let queue = Arc::new(unsafe { OwnedFd::from_raw_fd(raw) });
            change(&queue, event(WAKE, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0))?;
            let waker = Arc::new(Waker { queue: Arc::clone(&queue) });
            Ok(Self { queue, waker })
        }

        pub(super) fn waker(&self) -> Arc<Waker> {
            Arc::clone(&self.waker)
        }

        /// Watch `pid`'s exit. ESRCH: it already exited (a zombie) or is gone.
        pub(super) fn watch(&self, pid: u32) -> io::Result<KernelWatch> {
            let ident = libc::pid_t::try_from(pid)
                .map_err(|_| io::Error::from_raw_os_error(libc::ESRCH))?
                as libc::uintptr_t;
            let flags = libc::EV_ADD | libc::EV_ONESHOT;
            change(&self.queue, event(ident, libc::EVFILT_PROC, flags, libc::NOTE_EXIT))?;
            Ok(KernelWatch)
        }

        /// Block, with no timeout, until at least one event; replaces `events`.
        pub(super) fn wait(&self, events: &mut Vec<Event>) -> io::Result<()> {
            // SAFETY: zeroed kevents are valid output storage.
            let mut raw: [libc::kevent; 64] = unsafe { std::mem::zeroed() };
            let n = loop {
                // SAFETY: no changes, up to 64 events out, no timeout.
                let n = unsafe {
                    libc::kevent(
                        self.queue.as_raw_fd(),
                        std::ptr::null(),
                        0,
                        raw.as_mut_ptr(),
                        raw.len() as libc::c_int,
                        std::ptr::null(),
                    )
                };
                if n >= 0 {
                    break n as usize;
                }
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            };
            events.extend(raw[..n].iter().map(|event| match event.filter {
                libc::EVFILT_PROC => Event::Exit(event.ident as u32),
                _ => Event::Wake,
            }));
            Ok(())
        }
    }

    impl Waker {
        pub(super) fn wake(&self) -> io::Result<()> {
            change(&self.queue, event(WAKE, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER))
        }
    }
}

#[cfg(target_os = "linux")]
mod sys {
    //! One epoll set: a pidfd per child (readable once it ended), an eventfd
    //! to wake.

    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::sync::Arc;

    pub(super) enum Event {
        Wake,
        Exit(u32),
    }

    /// The epoll data of the eventfd; a pidfd's is its pid.
    const WAKE: u64 = u64::MAX;

    pub(super) struct Poller {
        epoll: Arc<OwnedFd>,
        waker: Arc<Waker>,
    }

    pub(super) struct Waker {
        eventfd: OwnedFd,
    }

    /// A child's pidfd, in the epoll set until dropped.
    pub(super) struct KernelWatch {
        epoll: Arc<OwnedFd>,
        pidfd: OwnedFd,
    }

    impl Drop for KernelWatch {
        fn drop(&mut self) {
            // SAFETY: both descriptors are live; DEL takes no event.
            unsafe {
                libc::epoll_ctl(
                    self.epoll.as_raw_fd(),
                    libc::EPOLL_CTL_DEL,
                    self.pidfd.as_raw_fd(),
                    std::ptr::null_mut(),
                );
            }
        }
    }

    fn owned(raw: libc::c_int) -> io::Result<OwnedFd> {
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a new descriptor the caller owns.
        Ok(unsafe { OwnedFd::from_raw_fd(raw) })
    }

    fn add(epoll: &OwnedFd, fd: &OwnedFd, data: u64) -> io::Result<()> {
        let mut event = libc::epoll_event { events: libc::EPOLLIN as u32, u64: data };
        // SAFETY: two live descriptors and one live event.
        if unsafe {
            libc::epoll_ctl(epoll.as_raw_fd(), libc::EPOLL_CTL_ADD, fd.as_raw_fd(), &mut event)
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    impl Poller {
        pub(super) fn new() -> io::Result<Self> {
            // SAFETY: epoll_create1 and eventfd return a new descriptor or -1.
            let epoll = Arc::new(owned(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) })?);
            let eventfd =
                owned(unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) })?;
            add(&epoll, &eventfd, WAKE)?;
            Ok(Self { epoll, waker: Arc::new(Waker { eventfd }) })
        }

        pub(super) fn waker(&self) -> Arc<Waker> {
            Arc::clone(&self.waker)
        }

        /// Watch `pid`'s exit. ESRCH: no such process (already reaped).
        pub(super) fn watch(&self, pid: u32) -> io::Result<KernelWatch> {
            let pid_t = libc::pid_t::try_from(pid)
                .map_err(|_| io::Error::from_raw_os_error(libc::ESRCH))?;
            // SAFETY: pidfd_open returns a new descriptor (close-on-exec) or -1.
            let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid_t, 0) };
            let pidfd = owned(raw as libc::c_int)?;
            add(&self.epoll, &pidfd, u64::from(pid))?;
            Ok(KernelWatch { epoll: Arc::clone(&self.epoll), pidfd })
        }

        /// Block, with no timeout, until at least one event; replaces `events`.
        pub(super) fn wait(&self, events: &mut Vec<Event>) -> io::Result<()> {
            let mut raw = [libc::epoll_event { events: 0, u64: 0 }; 64];
            let n = loop {
                // SAFETY: up to 64 events out, no timeout.
                let n = unsafe {
                    libc::epoll_wait(self.epoll.as_raw_fd(), raw.as_mut_ptr(), raw.len() as i32, -1)
                };
                if n >= 0 {
                    break n as usize;
                }
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            };
            for event in &raw[..n] {
                let data = event.u64;
                if data == WAKE {
                    self.waker.reset();
                    events.push(Event::Wake);
                } else {
                    events.push(Event::Exit(data as u32));
                }
            }
            Ok(())
        }
    }

    impl Waker {
        pub(super) fn wake(&self) -> io::Result<()> {
            let one = 1_u64.to_ne_bytes();
            // SAFETY: eight bytes from a live buffer to a live eventfd.
            let n =
                unsafe { libc::write(self.eventfd.as_raw_fd(), one.as_ptr().cast(), one.len()) };
            if n >= 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            // EAGAIN: the counter is full, so a wake is already pending.
            if error.kind() == io::ErrorKind::WouldBlock { Ok(()) } else { Err(error) }
        }

        fn reset(&self) {
            let mut count = [0_u8; 8];
            // SAFETY: eight bytes into a live buffer from a live eventfd.
            let _ = unsafe {
                libc::read(self.eventfd.as_raw_fd(), count.as_mut_ptr().cast(), count.len())
            };
        }
    }
}

#[cfg(all(unix, not(target_vendor = "apple"), not(target_os = "linux")))]
mod sys {
    //! No per-process exit event here: the watcher does not start.

    use std::io;
    use std::sync::Arc;

    pub(super) enum Event {
        Wake,
        Exit(u32),
    }

    pub(super) struct Poller;
    pub(super) struct Waker;
    pub(super) struct KernelWatch;

    impl Poller {
        pub(super) fn new() -> io::Result<Self> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "child-exit watcher"))
        }

        pub(super) fn waker(&self) -> Arc<Waker> {
            Arc::new(Waker)
        }

        pub(super) fn watch(&self, _pid: u32) -> io::Result<KernelWatch> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "child-exit watcher"))
        }

        pub(super) fn wait(&self, _events: &mut Vec<Event>) -> io::Result<()> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "child-exit watcher"))
        }
    }

    impl Waker {
        pub(super) fn wake(&self) -> io::Result<()> {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::Duration;

    use super::ExitWatcher;
    use crate::Command;

    const PROMPT: Duration = Duration::from_secs(5);

    /// Block until child `pid` has exited, without reaping it: a zombie.
    fn wait_until_zombie(pid: u32) {
        // SAFETY: zeroed siginfo is valid output storage for waitid.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: waitid writes one siginfo for this child.
        let result = unsafe {
            libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT)
        };
        assert_eq!(result, 0);
    }

    fn exits_through(watcher: &ExitWatcher) {
        // A running child: its callback waits for its exit.
        let mut running = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let (sender, exits) = mpsc::channel();
        let first = sender.clone();
        watcher.register(running.id(), move || first.send("first").unwrap()).unwrap();
        let second = sender.clone();
        watcher.register(running.id(), move || second.send("second").unwrap()).unwrap();
        assert!(exits.recv_timeout(Duration::from_millis(200)).is_err(), "fired for a live child");
        assert!(running.try_wait().unwrap().is_none(), "the watcher reaped the child");
        running.kill().unwrap();
        assert_eq!(exits.recv_timeout(PROMPT).unwrap(), "first");
        assert_eq!(exits.recv_timeout(PROMPT).unwrap(), "second");
        assert!(running.try_wait().unwrap().is_some(), "the owner reaps after the callback");

        // A child that ended before its registration: its callback runs at once.
        let mut ended = Command::new("/bin/sh").args(["-c", "exit 3"]).spawn().unwrap();
        wait_until_zombie(ended.id());
        let late = sender.clone();
        watcher.register(ended.id(), move || late.send("late").unwrap()).unwrap();
        assert_eq!(exits.recv_timeout(PROMPT).unwrap(), "late");
        assert_eq!(ended.wait().unwrap().code(), Some(3));
    }

    #[test]
    fn callbacks_run_in_order_at_the_exit_and_at_once_for_a_zombie() {
        exits_through(&ExitWatcher::start().unwrap());
    }

    /// The path without kqueue or pidfd (Linux before 5.3, a seccomp profile
    /// that denies `pidfd_open`, no descriptor left).
    #[test]
    fn the_waitid_fallback_reports_the_same_exits() {
        exits_through(&ExitWatcher::start_without_kernel_watch().unwrap());
    }

    /// A callback that panics leaves the thread watching the next child.
    #[test]
    fn a_panicking_callback_does_not_stop_the_watcher() {
        let watcher = ExitWatcher::start().unwrap();
        let mut first = Command::new("/usr/bin/env").arg("true").spawn().unwrap();
        watcher.register(first.id(), || panic!("callback panic")).unwrap();
        let mut second = Command::new("/usr/bin/env").arg("true").spawn().unwrap();
        let (sender, exited) = mpsc::channel();
        watcher.register(second.id(), move || sender.send(()).unwrap()).unwrap();
        exited.recv_timeout(PROMPT).unwrap();
        first.wait().unwrap();
        second.wait().unwrap();
    }

    /// A dropped watcher still runs the callbacks of children it watches.
    #[test]
    fn a_dropped_watcher_still_reports_its_children() {
        let watcher = ExitWatcher::start().unwrap();
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let (sender, exited) = mpsc::channel();
        watcher.register(child.id(), move || sender.send(()).unwrap()).unwrap();
        drop(watcher);
        child.kill().unwrap();
        exited.recv_timeout(PROMPT).unwrap();
        child.wait().unwrap();
    }
}
