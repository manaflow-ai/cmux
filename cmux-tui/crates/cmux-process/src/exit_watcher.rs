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
//! The watcher never reaps: a callback that gets [`ChildExit::Exited`] sees
//! a child that waits as a zombie, so its pid is still its own (a signal to
//! its group cannot reach a reused pid), and reaps it itself (`Child::wait`,
//! which no longer blocks then) or leaves that to whoever owns the child.
//! macOS posts `NOTE_EXIT` just before the child turns into a zombie (xnu
//! `bsd/kern/kern_exit.c` `proc_exit`), so there the thread waits for the
//! zombie (`waitid(WNOWAIT)`) before it runs the callbacks, as
//! `WaitForChildToDie` waits after its `kevent`.
//!
//! "Could not watch" is never "ended": a registered callback runs exactly
//! once, with [`ChildExit::Unwatched`] when neither a kernel event nor a
//! `waitid` thread waits for the child (or the thread stopped), so the
//! caller's own fallback still runs.

use std::collections::HashMap;
use std::io;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, OnceLock, mpsc};

use cmux_threads::ThreadQos;

/// The thread's label in the thread registry and threading-model.md.
const THREAD_NAME: &str = "child-exit";

/// What a registered callback learns about its child.
#[derive(Debug)]
pub enum ChildExit {
    /// The child ended and waits as a zombie: a reap returns at once (or
    /// fails with ECHILD when its owner already reaped it).
    Exited,
    /// Nothing waits for the child's exit (no kernel event and no `waitid`
    /// thread, or the watcher stopped): it may still run. The caller's own
    /// fallback decides.
    Unwatched(io::Error),
}

/// Run on the `child-exit` thread once the child ended. It must not block:
/// it sends, signals, or reaps the ended child (which returns at once).
type Callback = Box<dyn FnOnce(ChildExit) + Send + 'static>;

/// A registered callback. Dropped without a call (the thread stopped with
/// it), it runs with [`ChildExit::Unwatched`], so it always runs once.
struct Pending(Option<Callback>);

impl Pending {
    fn new(callback: Callback) -> Self {
        Self(Some(callback))
    }

    /// A panicking callback must not end the thread every other child's exit
    /// depends on.
    fn call(mut self, exit: ChildExit) {
        if let Some(callback) = self.0.take() {
            let _ = catch_unwind(AssertUnwindSafe(move || callback(exit)));
        }
    }

    /// For a registration that fails in [`ExitWatcher::register`]: its
    /// caller hears the error there, so the callback never runs.
    fn disarm(mut self) {
        self.0 = None;
    }
}

impl Drop for Pending {
    fn drop(&mut self) {
        if let Some(callback) = self.0.take() {
            let stopped = io::Error::other("the child-exit watcher stopped");
            let _ = catch_unwind(AssertUnwindSafe(move || callback(ChildExit::Unwatched(stopped))));
        }
    }
}

enum Request {
    Watch(u32, Pending),
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

/// Sets up the kernel event of one child.
type WatchKernel = fn(&sys::Poller, u32) -> io::Result<sys::KernelWatch>;

/// Starts the `waitid` thread of one child, which reports to the watcher.
type SpawnWaitid = fn(u32, mpsc::Sender<u32>, Arc<sys::Waker>) -> io::Result<()>;

/// The calls a test replaces to force the fallback or a failed watch.
#[derive(Clone, Copy)]
struct Seams {
    kernel_watch: WatchKernel,
    waitid_thread: SpawnWaitid,
}

impl Seams {
    const SYSTEM: Self = Self { kernel_watch: sys::Poller::watch, waitid_thread: spawn_waitid };
}

impl ExitWatcher {
    /// Start a `child-exit` thread of its own (tests; the daemon uses
    /// [`ExitWatcher::process`]).
    pub fn start() -> io::Result<Self> {
        Self::start_with(Seams::SYSTEM)
    }

    fn start_with(seams: Seams) -> io::Result<Self> {
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
            seams,
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
    ///
    /// `Ok`: `on_exit` runs exactly once, with [`ChildExit::Exited`], or
    /// with [`ChildExit::Unwatched`] when the exit cannot be watched. `Err`:
    /// the watcher stopped, and `on_exit` never runs.
    pub fn register(
        &self,
        pid: u32,
        on_exit: impl FnOnce(ChildExit) + Send + 'static,
    ) -> io::Result<()> {
        if let Err(mpsc::SendError(request)) =
            self.requests.send(Request::Watch(pid, Pending::new(Box::new(on_exit))))
        {
            if let Request::Watch(_, pending) = request {
                pending.disarm();
            }
            return Err(io::Error::other("the child-exit watcher stopped"));
        }
        // The request is queued, so `on_exit` runs once either way: a failed
        // wake leaves it to the thread's next wake (or its stop, Unwatched).
        let _ = self.waker.wake();
        Ok(())
    }

    /// A watcher that never uses the kernel's per-process event (kqueue or
    /// pidfd), so every child takes the `waitid` thread fallback.
    #[cfg(test)]
    pub(crate) fn start_without_kernel_watch() -> io::Result<Self> {
        Self::start_with(Seams { kernel_watch: no_kernel_watch, ..Seams::SYSTEM })
    }

    /// A watcher with neither a kernel event nor a `waitid` thread: no
    /// child's exit can be watched.
    #[cfg(test)]
    pub(crate) fn start_unable_to_watch() -> io::Result<Self> {
        Self::start_with(Seams { kernel_watch: no_kernel_watch, waitid_thread: no_waitid_thread })
    }
}

/// No descriptor left for a pidfd or a refused `kevent`.
#[cfg(test)]
fn no_kernel_watch(_: &sys::Poller, _: u32) -> io::Result<sys::KernelWatch> {
    Err(io::Error::from_raw_os_error(libc::EMFILE))
}

/// No thread left.
#[cfg(test)]
fn no_waitid_thread(_: u32, _: mpsc::Sender<u32>, _: Arc<sys::Waker>) -> io::Result<()> {
    Err(io::Error::from_raw_os_error(libc::EAGAIN))
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
    callbacks: Vec<Pending>,
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
    seams: Seams,
}

impl Watches {
    fn run(&mut self) {
        let mut events = Vec::new();
        while !(self.stopping && self.watches.is_empty()) {
            if let Err(error) = self.poller.wait(&mut events) {
                // The kqueue or epoll set itself failed: nothing can wake
                // this thread again. Every callback hears it, and dropping
                // the inbox fails later registrations instead of losing them.
                self.unwatch_all(&error);
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
                    sys::Event::Exit(pid) => {
                        sys::wait_for_zombie(pid);
                        self.fire(pid);
                    }
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

    fn watch(&mut self, pid: u32, callback: Pending) {
        if let Some(watch) = self.watches.get_mut(&pid) {
            watch.callbacks.push(callback);
            return;
        }
        match (self.seams.kernel_watch)(&self.poller, pid) {
            Ok(kernel) => {
                self.watches
                    .insert(pid, Watch { _kernel: Some(kernel), callbacks: vec![callback] });
            }
            // A zombie (macOS: `EV_ADD` of an exiting process fails with
            // ESRCH) or a pid that is gone: only the zombie is left to wait for.
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {
                sys::wait_for_zombie(pid);
                callback.call(ChildExit::Exited);
            }
            // Linux before 5.3 or a seccomp profile without `pidfd_open`,
            // no descriptor left, or a refused `kevent` / `epoll_ctl`: a
            // thread blocked in `waitid` for this child, which reports
            // through `exits`.
            Err(_) => {
                match (self.seams.waitid_thread)(pid, self.exited.clone(), self.poller.waker()) {
                    Ok(()) => {
                        let watch = Watch { _kernel: None, callbacks: vec![callback] };
                        self.watches.insert(pid, watch);
                    }
                    Err(error) => callback.call(ChildExit::Unwatched(error)),
                }
            }
        }
    }

    fn fire(&mut self, pid: u32) {
        let Some(watch) = self.watches.remove(&pid) else { return };
        for callback in watch.callbacks {
            callback.call(ChildExit::Exited);
        }
    }

    /// The thread cannot wait any more: every callback, watched or queued,
    /// runs with [`ChildExit::Unwatched`].
    fn unwatch_all(&mut self, error: &io::Error) {
        let unwatched = || ChildExit::Unwatched(io::Error::new(error.kind(), error.to_string()));
        for (_, watch) in self.watches.drain() {
            for callback in watch.callbacks {
                callback.call(unwatched());
            }
        }
        while let Ok(request) = self.inbox.try_recv() {
            if let Request::Watch(_, callback) = request {
                callback.call(unwatched());
            }
        }
    }
}

/// A thread blocked in `waitid(WEXITED | WNOWAIT)` until `pid` ends (without
/// reaping it), which then reports the exit to the watcher: the wait where
/// the kernel gives no per-process event.
fn spawn_waitid(pid: u32, exited: mpsc::Sender<u32>, waker: Arc<sys::Waker>) -> io::Result<()> {
    cmux_threads::spawn("child-exit-waitid", ThreadQos::Utility, move || {
        wait_until_waitable(pid);
        if exited.send(pid).is_ok() {
            let _ = waker.wake();
        }
    })
    .map(drop)
}

/// Blocks until child `pid` waits as a zombie, without reaping it
/// (`waitid(WEXITED | WNOWAIT)`); returns at once (ECHILD) for a pid that is
/// not, or no longer, an unreaped child of this process.
fn wait_until_waitable(pid: u32) {
    loop {
        // SAFETY: zeroed siginfo_t is valid output storage.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: waitid writes one siginfo_t; WNOWAIT leaves the child
        // to its owner's wait.
        let result = unsafe {
            libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT)
        };
        if result == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return;
        }
    }
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

    /// `proc_exit` posts `NOTE_EXIT` (and fails a late `EV_ADD` with ESRCH)
    /// before the child is a zombie: wait for that moment, so a callback's
    /// `try_wait` sees the status (Chrome's `WaitForChildToDie` waits too).
    pub(super) fn wait_for_zombie(pid: u32) {
        super::wait_until_waitable(pid);
    }

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

    /// A pidfd turns readable only once its child is a zombie, and
    /// `pidfd_open` fails with ESRCH only for a reaped pid: nothing to wait.
    pub(super) fn wait_for_zombie(_pid: u32) {}

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

    pub(super) fn wait_for_zombie(_pid: u32) {}

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

    use super::{ChildExit, ExitWatcher};
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

    /// A callback that sends `label` for an exit, and panics (a lost
    /// message) for an unwatched child.
    fn on_exit(
        sender: &mpsc::Sender<&'static str>,
        label: &'static str,
    ) -> impl FnOnce(ChildExit) + Send + use<> {
        let sender = sender.clone();
        move |exit| {
            assert!(matches!(exit, ChildExit::Exited), "{label}: {exit:?}");
            sender.send(label).unwrap();
        }
    }

    fn exits_through(watcher: &ExitWatcher) {
        // A running child: its callback waits for its exit.
        let mut running = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let (sender, exits) = mpsc::channel();
        watcher.register(running.id(), on_exit(&sender, "first")).unwrap();
        watcher.register(running.id(), on_exit(&sender, "second")).unwrap();
        assert!(exits.recv_timeout(Duration::from_millis(200)).is_err(), "fired for a live child");
        assert!(running.try_wait().unwrap().is_none(), "the watcher reaped the child");
        running.kill().unwrap();
        assert_eq!(exits.recv_timeout(PROMPT).unwrap(), "first");
        assert_eq!(exits.recv_timeout(PROMPT).unwrap(), "second");
        assert!(running.try_wait().unwrap().is_some(), "the owner reaps after the callback");

        // A child that ended before its registration: its callback runs at once.
        let mut ended = Command::new("/bin/sh").args(["-c", "exit 3"]).spawn().unwrap();
        wait_until_zombie(ended.id());
        watcher.register(ended.id(), on_exit(&sender, "late")).unwrap();
        assert_eq!(exits.recv_timeout(PROMPT).unwrap(), "late");
        assert_eq!(ended.wait().unwrap().code(), Some(3));
    }

    /// Every `Exited` callback finds its child waitable: a `try_wait` in the
    /// callback (the journal plugin's, cmux-host's) gets the status. macOS
    /// posts `NOTE_EXIT` before the child is a zombie, so without the
    /// watcher's wait for the zombie some of these see `None`.
    fn every_callback_sees_a_waitable_child(watcher: &ExitWatcher) {
        const CHILDREN: usize = 64;
        let (sender, reaped) = mpsc::channel();
        for _ in 0..CHILDREN {
            let mut child = Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
            let sender = sender.clone();
            watcher
                .register(child.id(), move |exit| {
                    let waitable = matches!(exit, ChildExit::Exited)
                        && matches!(child.try_wait(), Ok(Some(_)));
                    if !waitable {
                        // Not lost: the test reaps it after the assertion.
                        let _ = child.wait();
                    }
                    sender.send(waitable).unwrap();
                })
                .unwrap();
        }
        for _ in 0..CHILDREN {
            assert!(reaped.recv_timeout(PROMPT).unwrap(), "a callback ran before the zombie");
        }
    }

    #[test]
    fn callbacks_run_in_order_at_the_exit_and_at_once_for_a_zombie() {
        exits_through(&ExitWatcher::start().unwrap());
    }

    #[test]
    fn a_kernel_exit_event_reaches_the_callback_only_once_the_child_is_waitable() {
        every_callback_sees_a_waitable_child(&ExitWatcher::start().unwrap());
    }

    /// The path without kqueue or pidfd (Linux before 5.3, a seccomp profile
    /// that denies `pidfd_open`, no descriptor left).
    #[test]
    fn the_waitid_fallback_reports_the_same_exits() {
        let watcher = ExitWatcher::start_without_kernel_watch().unwrap();
        exits_through(&watcher);
        every_callback_sees_a_waitable_child(&watcher);
    }

    /// No kernel event and no `waitid` thread: the callback hears that the
    /// child is not watched (it is not dropped, and not told it ended), so
    /// the caller's own fallback runs.
    #[test]
    fn a_child_nothing_can_watch_is_reported_unwatched_not_ended() {
        let watcher = ExitWatcher::start_unable_to_watch().unwrap();
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let (sender, outcome) = mpsc::channel();
        watcher.register(child.id(), move |exit| sender.send(exit).unwrap()).unwrap();
        match outcome.recv_timeout(PROMPT).unwrap() {
            ChildExit::Unwatched(error) => assert_eq!(error.raw_os_error(), Some(libc::EAGAIN)),
            ChildExit::Exited => panic!("a running child was reported ended"),
        }
        assert!(child.try_wait().unwrap().is_none(), "the child still runs");
        child.kill().unwrap();
        child.wait().unwrap();
    }

    /// A callback that panics leaves the thread watching the next child.
    #[test]
    fn a_panicking_callback_does_not_stop_the_watcher() {
        let watcher = ExitWatcher::start().unwrap();
        let mut first = Command::new("/usr/bin/env").arg("true").spawn().unwrap();
        watcher.register(first.id(), |_| panic!("callback panic")).unwrap();
        let mut second = Command::new("/usr/bin/env").arg("true").spawn().unwrap();
        let (sender, exited) = mpsc::channel();
        watcher.register(second.id(), on_exit(&sender, "second")).unwrap();
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
        watcher.register(child.id(), on_exit(&sender, "child")).unwrap();
        drop(watcher);
        child.kill().unwrap();
        exited.recv_timeout(PROMPT).unwrap();
        child.wait().unwrap();
    }
}
