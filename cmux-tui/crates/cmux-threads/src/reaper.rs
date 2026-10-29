//! One thread waits for every child's exit.
//!
//! A thread per child blocked in `waitpid` costs a stack and a registry row for
//! each terminal. Chromium has none on macOS: `EnsureProcessTerminated`
//! (base/process/kill_mac.cc) gives each child a `DISPATCH_SOURCE_TYPE_PROC`
//! source, and libdispatch serves every such source from one kqueue. A
//! [`Reaper`] is that kqueue on one named thread, `<label>-reaper` at Utility:
//!
//! - macOS: each child is an `EVFILT_PROC` `NOTE_EXIT` filter (`EV_ONESHOT`);
//!   the stop signal is an `EVFILT_USER` event.
//! - Linux: each child is a pidfd (`pidfd_open`, readable once the child has
//!   exited) in one epoll set; the stop signal is an eventfd. Chromium's
//!   Linux `EnsureProcessTerminated` (base/process/kill_posix.cc) still starts
//!   a `BackgroundReaper` thread per child; this does not. Where `pidfd_open`
//!   is missing (before Linux 5.3) or denied (seccomp), the child gets one
//!   `<label>-reap-wait` thread blocked in `waitid`, counted in
//!   [`ReaperStats::fallback_threads`].
//!
//! "Could not watch" is never "ended": a child whose registration fails (no
//! descriptor left, a refused `epoll_ctl` or `kevent`, a stopped thread) gets
//! the same `<label>-reap-wait` thread, and when even that thread cannot
//! start, [`Reaper::watch`] returns the completion in an [`Unwatched`] for
//! the caller's own fallback. Only a pid no wait can see (not a child of
//! this process, or reaped elsewhere) completes as ended without a wait.
//!
//! The thread only waits: it never reaps and never runs a completion. Each
//! exit becomes one [`crate::work`] item ([`Lane::System`], UserVisible,
//! [`Shutdown::BlockShutdown`]), so a slow completion never delays the next
//! child's exit. [`Reaper::watch`]'s item reaps the child (`waitpid`) and
//! hands its status to the completion; [`Reaper::watch_exited`]'s item leaves
//! the child unreaped (a zombie, `waitid(WNOWAIT)`) for a completion that must
//! act before the pid is freed (signal the child's process group) or that
//! reaps it itself. The thread waits with no timeout: an idle reaper never
//! wakes ([`ReaperStats::wakeups`]).
//!
//! macOS posts `NOTE_EXIT` just before the child turns into a zombie (xnu
//! bsd/kern/kern_exit.c `proc_exit`), so the item's wait for the zombie may
//! block for that moment; on Linux the pidfd turns readable only once the
//! child is one.
//!
//! ```ignore
//! let reaper = Reaper::new("mux", Arc::clone(&work))?;
//! if let Err(unwatched) = reaper.watch(child.id(), Box::new(move |status| record(status))) {
//!     // Nothing waits for the child: the caller's own fallback.
//!     return Err(unwatched.into_error());
//! }
//! ```

use std::collections::HashMap;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::process::ExitStatus;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel, sync_channel};

use crate::blocking::{BlockingKind, scoped_blocking_call};
use crate::qos::ThreadQos;
use crate::work::{Lane, Priority, Shutdown, Work, will_block};

/// What runs, as a work item, once a child watched with [`Reaper::watch`]
/// has ended: its reaped status, or why it could not be watched or reaped.
pub type OnExit = Box<dyn FnOnce(io::Result<ExitStatus>) + Send>;

/// What runs, as a work item, once a child watched with
/// [`Reaper::watch_exited`] has ended: true when it waits as a zombie (still
/// unreaped), false when no wait could see it (not a child of this process,
/// or reaped elsewhere). Never false for a child that still runs.
pub type OnExited = Box<dyn FnOnce(bool) + Send>;

/// A child [`Reaper::watch`] or [`Reaper::watch_exited`] could not watch:
/// neither the reaper thread nor a wait thread of its own waits for it, and
/// the child still runs as far as the reaper knows. It holds the completion,
/// never called: dropping this drops it, so the completion's own drop path
/// (a PTY guard's kill and wait) runs where the caller drops it.
pub struct Unwatched {
    error: io::Error,
    _completion: Completion,
}

impl Unwatched {
    /// Why no wait could be set up.
    pub fn error(&self) -> &io::Error {
        &self.error
    }

    /// The error, dropping the completion uncalled.
    pub fn into_error(self) -> io::Error {
        self.error
    }
}

impl std::fmt::Debug for Unwatched {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Unwatched").field("error", &self.error).finish_non_exhaustive()
    }
}

impl std::fmt::Display for Unwatched {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "the child's exit is not watched: {}", self.error)
    }
}

impl std::error::Error for Unwatched {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.error)
    }
}

/// Counters of one [`Reaper`], for `server.threads` and tests.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReaperStats {
    /// Children whose exit the thread waits for now.
    pub watching: u64,
    /// Exits handed to a work item since the reaper started.
    pub exits: u64,
    /// Times the thread's wait returned (an exit event, the stop signal or an
    /// interrupted wait). An idle reaper adds none.
    pub wakeups: u64,
    /// Children that got their own wait thread because no pidfd could be
    /// opened (Linux only).
    pub fallback_threads: u64,
}

/// Waits for the exits of the children handed to [`Reaper::watch`] and
/// [`Reaper::watch_exited`] on one thread. Build one per process at the
/// composition root and pass it by reference; tests build their own.
/// Dropping it stops the thread; a child still watched then has its
/// completion dropped without a call.
pub struct Reaper {
    shared: Arc<Shared>,
    watches: Sender<(u64, Watch)>,
}

/// Registers child `pid` with the thread's poller under `token`.
type Register = fn(&sys::Events, libc::pid_t, u64) -> io::Result<sys::Added>;

/// Starts a named Utility thread that runs its body.
type SpawnThread = fn(String, Box<dyn FnOnce() + Send>) -> io::Result<()>;

/// The calls a test replaces to force a registration or thread failure.
#[derive(Clone, Copy)]
struct Seams {
    register: Register,
    spawn: SpawnThread,
}

impl Seams {
    const SYSTEM: Seams = Seams {
        register: |events, pid, token| events.add_child(pid, token),
        spawn: |name, body| crate::spawn::spawn(name, ThreadQos::Utility, body).map(drop),
    };
}

struct Shared {
    label: String,
    work: Arc<Work>,
    seams: Seams,
    events: sys::Events,
    stopping: AtomicBool,
    next_token: AtomicU64,
    watching: AtomicU64,
    exits: AtomicU64,
    wakeups: AtomicU64,
    fallback_threads: AtomicU64,
}

/// A child the thread waits for, keyed by its registration token.
struct Watch {
    pid: libc::pid_t,
    completion: Completion,
    /// The registration's descriptor (Linux: the pidfd in the epoll set);
    /// dropping it removes the registration.
    _registration: sys::Registration,
}

/// The completion of one watched child.
enum Completion {
    /// Reap the child and pass its status.
    Reap(OnExit),
    /// Leave the child a zombie for the completion.
    Exited(OnExited),
}

impl Completion {
    /// Runs the completion for child `pid`, which has ended.
    fn complete(self, pid: libc::pid_t) {
        match self {
            Completion::Reap(on_exit) => on_exit(reap_ended(pid)),
            Completion::Exited(on_exited) => on_exited(wait_zombie(pid)),
        }
    }

    /// Runs the completion for a pid no wait can see (`error`, ECHILD):
    /// nothing is left to reap.
    fn unwaitable(self, error: io::Error) {
        match self {
            Completion::Reap(on_exit) => on_exit(Err(error)),
            Completion::Exited(on_exited) => on_exited(false),
        }
    }
}

impl Reaper {
    /// Starts thread `<label>-reaper` at Utility. Completions run on `work`.
    pub fn new(label: &str, work: Arc<Work>) -> io::Result<Reaper> {
        Reaper::with_seams(label, work, Seams::SYSTEM)
    }

    fn with_seams(label: &str, work: Arc<Work>, seams: Seams) -> io::Result<Reaper> {
        let shared = Arc::new(Shared {
            label: label.to_owned(),
            work,
            seams,
            events: sys::Events::new()?,
            stopping: AtomicBool::new(false),
            next_token: AtomicU64::new(0),
            watching: AtomicU64::new(0),
            exits: AtomicU64::new(0),
            wakeups: AtomicU64::new(0),
            fallback_threads: AtomicU64::new(0),
        });
        let (watches, registered) = channel();
        let thread_shared = Arc::clone(&shared);
        crate::spawn::spawn(format!("{label}-reaper"), ThreadQos::Utility, move || {
            run(&thread_shared, &registered);
        })?;
        Ok(Reaper { shared, watches })
    }

    /// Waits for child `pid` to end, then reaps it and runs `on_exit` with
    /// its status as a work item. `pid` must be a child of this process that
    /// nothing else waits for. A child that already ended is reaped at once;
    /// a pid no wait can see gets `on_exit(Err(ECHILD))`. Never blocks.
    ///
    /// # Errors
    ///
    /// [`Unwatched`] when nothing could be set up to wait for the child (no
    /// registration and no wait thread): `on_exit` is never called.
    pub fn watch(&self, pid: u32, on_exit: OnExit) -> Result<(), Unwatched> {
        self.add(pid, Completion::Reap(on_exit))
    }

    /// Waits for child `pid` to end, then runs `on_exited` as a work item
    /// with the child still unreaped: the completion may signal the child's
    /// process group (the pid is still taken) and reaps it (its owner's
    /// `Child::wait` returns at once) or leaves that to its owner. A pid no
    /// wait can see gets `on_exited(false)`. Never blocks.
    ///
    /// # Errors
    ///
    /// [`Unwatched`] as for [`Reaper::watch`]: `on_exited` is never called.
    pub fn watch_exited(&self, pid: u32, on_exited: OnExited) -> Result<(), Unwatched> {
        self.add(pid, Completion::Exited(on_exited))
    }

    /// The counters now.
    pub fn stats(&self) -> ReaperStats {
        let load = |counter: &AtomicU64| counter.load(Ordering::Relaxed);
        ReaperStats {
            watching: load(&self.shared.watching),
            exits: load(&self.shared.exits),
            wakeups: load(&self.shared.wakeups),
            fallback_threads: load(&self.shared.fallback_threads),
        }
    }

    fn add(&self, pid: u32, completion: Completion) -> Result<(), Unwatched> {
        let Ok(pid) = libc::pid_t::try_from(pid) else {
            let error = io::Error::from_raw_os_error(libc::ESRCH);
            return Err(Unwatched { error, _completion: completion });
        };
        // kqueue and pidfd watch any process; only a child can be reaped, so
        // a pid no wait sees (ECHILD) would never complete: it ended for us.
        if let Err(error) = child_status(pid) {
            self.shared.unwaitable(error, completion);
            return Ok(());
        }
        let token = self.shared.next_token.fetch_add(1, Ordering::Relaxed);
        let registered = (self.shared.seams.register)(&self.shared.events, pid, token);
        match registered {
            Ok(sys::Added::Watching(registration)) => {
                self.shared.watching.fetch_add(1, Ordering::Relaxed);
                let watch = Watch { pid, completion, _registration: registration };
                // The thread reads its channel until this reaper drops (a
                // poller error included), so only a panicked thread refuses.
                let Err(unsent) = self.watches.send((token, watch)) else { return Ok(()) };
                self.shared.watching.fetch_sub(1, Ordering::Relaxed);
                let (_, Watch { completion, .. }) = unsent.0;
                self.shared.wait_on_own_thread(pid, completion)
            }
            Ok(sys::Added::Exited) => {
                self.shared.ended(pid, completion);
                Ok(())
            }
            Ok(sys::Added::Unsupported) => self.shared.wait_on_own_thread(pid, completion),
            // Not watched is not ended: the child may still run.
            Err(error) => {
                eprintln!("cmux-threads: no exit event for child {pid} ({error}); a wait thread");
                self.shared.wait_on_own_thread(pid, completion)
            }
        }
    }
}

impl Drop for Reaper {
    fn drop(&mut self) {
        self.shared.stopping.store(true, Ordering::Release);
        if let Err(error) = self.shared.events.wake() {
            eprintln!("cmux-threads: could not stop the reaper thread: {error}");
        }
    }
}

impl Shared {
    /// Child `pid` has ended (or is ending): a work item completes it.
    fn ended(&self, pid: libc::pid_t, completion: Completion) {
        self.exits.fetch_add(1, Ordering::Relaxed);
        self.post(Box::new(move || completion.complete(pid)));
    }

    /// No wait sees `pid` (`error`): a work item completes it as ended.
    fn unwaitable(&self, error: io::Error, completion: Completion) {
        self.post(Box::new(move || completion.unwaitable(error)));
    }

    /// The child has no exit event: thread `<label>-reap-wait` blocks in
    /// `waitid` until it is a zombie, then hands it to a work item as an exit
    /// event would. The completion reaches the thread only once it runs, so
    /// a thread that cannot start hands it back in the [`Unwatched`].
    fn wait_on_own_thread(
        self: &Arc<Self>,
        pid: libc::pid_t,
        completion: Completion,
    ) -> Result<(), Unwatched> {
        let (handoff, handed) = sync_channel::<Completion>(1);
        let shared = Arc::clone(self);
        let body: Box<dyn FnOnce() + Send> = Box::new(move || {
            wait_zombie(pid);
            if let Ok(completion) = handed.recv() {
                shared.ended(pid, completion);
            }
        });
        if let Err(error) = (self.seams.spawn)(format!("{}-reap-wait", self.label), body) {
            return Err(Unwatched { error, _completion: completion });
        }
        self.fallback_threads.fetch_add(1, Ordering::Relaxed);
        // The thread keeps `handed` until it receives, and the one-slot
        // channel is empty: the send neither blocks nor fails.
        handoff
            .send(completion)
            .map_err(|unsent| Unwatched { error: thread_gone(), _completion: unsent.0 })
    }

    fn post(&self, item: Box<dyn FnOnce() + Send>) {
        // A block item is accepted after shutdown too (work.rs `submit`), so
        // no exit is lost to a daemon that is stopping.
        let _ = self.work.post(Priority::UserVisible, Lane::System, Shutdown::BlockShutdown, item);
    }
}

fn thread_gone() -> io::Error {
    io::Error::other("the wait thread ended before it took its child")
}

/// The thread: waits for exit events and hands each to a work item.
fn run(shared: &Arc<Shared>, registered: &Receiver<(u64, Watch)>) {
    let mut watches: HashMap<u64, Watch> = HashMap::new();
    let mut ended = Vec::new();
    while !shared.stopping.load(Ordering::Acquire) {
        ended.clear();
        if let Err(error) = shared.events.wait(&mut ended) {
            eprintln!("cmux-threads: the reaper's poller failed ({error}); wait threads take over");
            hand_off_after_poller_error(shared, watches, registered);
            return;
        }
        shared.wakeups.fetch_add(1, Ordering::Relaxed);
        for token in ended.drain(..) {
            let Some(watch) = take_watch(&mut watches, registered, token) else { continue };
            shared.watching.fetch_sub(1, Ordering::Relaxed);
            let Watch { pid, completion, .. } = watch;
            shared.ended(pid, completion);
        }
    }
}

/// The poller failed: no exit event comes any more. Every watched child,
/// and every one registered until the reaper drops, gets a wait thread, so
/// none is lost; where even that thread cannot start, a work item waits
/// for it ([`will_block`]: it holds no lane slot while it waits).
fn hand_off_after_poller_error(
    shared: &Arc<Shared>,
    watches: HashMap<u64, Watch>,
    registered: &Receiver<(u64, Watch)>,
) {
    let pending = watches.into_values().chain(registered.iter().map(|(_, watch)| watch));
    for Watch { pid, completion, .. } in pending {
        shared.watching.fetch_sub(1, Ordering::Relaxed);
        if let Err(unwatched) = shared.wait_on_own_thread(pid, completion) {
            let Unwatched { _completion: completion, .. } = unwatched;
            let waiter = Arc::clone(shared);
            shared.post(Box::new(move || {
                wait_zombie(pid);
                waiter.exits.fetch_add(1, Ordering::Relaxed);
                completion.complete(pid);
            }));
        }
    }
}

/// The watch registered under `token`. Its registrar sends it right after
/// the kernel accepted the registration, so the exit event can come first:
/// then this waits for that message.
fn take_watch(
    watches: &mut HashMap<u64, Watch>,
    registered: &Receiver<(u64, Watch)>,
    token: u64,
) -> Option<Watch> {
    while let Ok((sent, watch)) = registered.try_recv() {
        watches.insert(sent, watch);
    }
    if let Some(watch) = watches.remove(&token) {
        return Some(watch);
    }
    while let Ok((sent, watch)) = registered.recv() {
        if sent == token {
            return Some(watch);
        }
        watches.insert(sent, watch);
    }
    None
}

/// Reaps `pid` after its exit event: at once on Linux, after the moment it
/// takes to become a zombie on macOS.
fn reap_ended(pid: libc::pid_t) -> io::Result<ExitStatus> {
    if let Some(status) = waitpid(pid, libc::WNOHANG)? {
        return Ok(status);
    }
    will_block(|| scoped_blocking_call(BlockingKind::ProcessWait, || waitpid(pid, 0)))?
        .ok_or_else(|| io::Error::other("waitpid returned no status"))
}

/// Whether `pid` is an unreaped child of this process, without waiting or
/// reaping (`waitid(WEXITED | WNOHANG | WNOWAIT)`): ECHILD when it is not.
fn child_status(pid: libc::pid_t) -> io::Result<()> {
    loop {
        // SAFETY: a zeroed siginfo_t is valid output storage.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let flags = libc::WEXITED | libc::WNOHANG | libc::WNOWAIT;
        // SAFETY: waitid writes one siginfo_t and returns at once (WNOHANG);
        // WNOWAIT leaves the child waitable.
        if unsafe { libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, flags) } == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

/// Blocks until child `pid` waits as a zombie, without reaping it
/// (`waitid(WEXITED | WNOWAIT)`); false when no wait can see it. On a work
/// item the wait holds no lane slot ([`will_block`]).
fn wait_zombie(pid: libc::pid_t) -> bool {
    will_block(|| scoped_blocking_call(BlockingKind::ProcessWait, || zombie(pid)))
}

fn zombie(pid: libc::pid_t) -> bool {
    loop {
        // SAFETY: a zeroed siginfo_t is valid output storage.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: waitid writes one siginfo_t; WNOWAIT leaves the child
        // waitable.
        let done = unsafe {
            libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT)
        };
        if done == 0 {
            return true;
        }
        if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            return false;
        }
    }
}

/// `waitpid(pid, flags)`, retried on EINTR: `None` when `WNOHANG` found the
/// child still running.
fn waitpid(pid: libc::pid_t, flags: libc::c_int) -> io::Result<Option<ExitStatus>> {
    use std::os::unix::process::ExitStatusExt;
    loop {
        let mut raw = 0;
        // SAFETY: waitpid writes one int for a child of this process.
        let reaped = unsafe { libc::waitpid(pid, &mut raw, flags) };
        if reaped == pid {
            return Ok(Some(ExitStatus::from_raw(raw)));
        }
        if reaped == 0 {
            return Ok(None);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

/// Takes ownership of a descriptor a system call just returned.
fn owned(raw: libc::c_int) -> io::Result<OwnedFd> {
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a new descriptor the caller just got and owns.
    Ok(unsafe { OwnedFd::from_raw_fd(raw) })
}

#[cfg(target_vendor = "apple")]
mod sys {
    use super::*;

    /// The stop signal's `EVFILT_USER` ident.
    const WAKE: libc::uintptr_t = 0;

    /// A kqueue filter needs no descriptor of its own.
    pub(super) type Registration = ();

    pub(super) enum Added {
        /// The kernel reports the exit later.
        Watching(Registration),
        /// The child had already exited: complete it now.
        Exited,
        /// Every macOS child has an exit event.
        #[allow(dead_code)]
        Unsupported,
    }

    pub(super) struct Events {
        queue: OwnedFd,
    }

    impl Events {
        pub(super) fn new() -> io::Result<Events> {
            // SAFETY: kqueue takes no arguments.
            let queue = owned(unsafe { libc::kqueue() })?;
            let events = Events { queue };
            events.change(event(WAKE, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0, 0))?;
            Ok(events)
        }

        /// Registers `NOTE_EXIT` of `pid` under `token`.
        pub(super) fn add_child(&self, pid: libc::pid_t, token: u64) -> io::Result<Added> {
            let flags = libc::EV_ADD | libc::EV_ONESHOT;
            let ident = pid as libc::uintptr_t;
            match self.change(event(ident, libc::EVFILT_PROC, flags, libc::NOTE_EXIT, token)) {
                Ok(()) => Ok(Added::Watching(())),
                // Exited before the registration: its status waits to be reaped.
                Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Ok(Added::Exited),
                Err(error) => Err(error),
            }
        }

        /// Fires the stop signal.
        pub(super) fn wake(&self) -> io::Result<()> {
            self.change(event(WAKE, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER, 0))
        }

        /// Blocks until an event arrives; pushes the token of each ended child.
        pub(super) fn wait(&self, ended: &mut Vec<u64>) -> io::Result<()> {
            // SAFETY: zeroed kevents are valid output storage.
            let mut out: [libc::kevent; 16] = unsafe { std::mem::zeroed() };
            // SAFETY: no changes in, at most 16 events out, no timeout.
            let n = unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    out.as_mut_ptr(),
                    out.len() as libc::c_int,
                    std::ptr::null(),
                )
            };
            if n < 0 {
                let error = io::Error::last_os_error();
                return if error.kind() == io::ErrorKind::Interrupted {
                    Ok(())
                } else {
                    Err(error)
                };
            }
            for event in &out[..n as usize] {
                if event.filter == libc::EVFILT_PROC {
                    ended.push(event.udata as usize as u64);
                }
            }
            Ok(())
        }

        /// Applies one change and reads its receipt (`EV_RECEIPT`), so no
        /// pending event is taken off the queue here.
        fn change(&self, mut change: libc::kevent) -> io::Result<()> {
            change.flags |= libc::EV_RECEIPT;
            let none = libc::timespec { tv_sec: 0, tv_nsec: 0 };
            loop {
                // SAFETY: zeroed kevent is valid output storage.
                let mut receipt: libc::kevent = unsafe { std::mem::zeroed() };
                // SAFETY: one change in, its receipt out, a zero timeout.
                let n = unsafe {
                    libc::kevent(self.queue.as_raw_fd(), &change, 1, &mut receipt, 1, &none)
                };
                if n < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                if n == 1 && receipt.flags & libc::EV_ERROR != 0 && receipt.data != 0 {
                    return Err(io::Error::from_raw_os_error(receipt.data as i32));
                }
                return Ok(());
            }
        }
    }

    fn event(
        ident: libc::uintptr_t,
        filter: i16,
        flags: u16,
        fflags: u32,
        token: u64,
    ) -> libc::kevent {
        libc::kevent {
            ident,
            filter,
            flags,
            fflags,
            data: 0,
            udata: token as usize as *mut libc::c_void,
        }
    }
}

#[cfg(target_os = "linux")]
mod sys {
    use super::*;

    /// The stop signal's epoll token; child tokens count up from 0.
    const WAKE: u64 = u64::MAX;

    /// The child's pidfd, in the epoll set until it closes.
    pub(super) type Registration = OwnedFd;

    pub(super) enum Added {
        /// The pidfd turns readable at the exit.
        Watching(Registration),
        /// A zombie's pidfd is readable at once, so a Linux child is always
        /// watched.
        #[allow(dead_code)]
        Exited,
        /// No pidfd (before Linux 5.3, or denied).
        Unsupported,
    }

    pub(super) struct Events {
        epoll: OwnedFd,
        wake: OwnedFd,
    }

    impl Events {
        pub(super) fn new() -> io::Result<Events> {
            // SAFETY: epoll_create1 takes a flag only.
            let epoll = owned(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) })?;
            // SAFETY: eventfd takes an initial value and flags only.
            let wake = owned(unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) })?;
            let events = Events { epoll, wake };
            events.add(events.wake.as_raw_fd(), libc::EPOLLIN as u32, WAKE)?;
            Ok(events)
        }

        /// Opens a pidfd of `pid` and adds it under `token`.
        pub(super) fn add_child(&self, pid: libc::pid_t, token: u64) -> io::Result<Added> {
            // SAFETY: pidfd_open takes a pid and flags only.
            let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
            let pidfd = match owned(raw as libc::c_int) {
                Ok(pidfd) => pidfd,
                Err(error)
                    if matches!(
                        error.raw_os_error(),
                        Some(libc::ENOSYS) | Some(libc::EPERM) | Some(libc::EACCES)
                    ) =>
                {
                    return Ok(Added::Unsupported);
                }
                Err(error) => return Err(error),
            };
            let interest = (libc::EPOLLIN | libc::EPOLLONESHOT) as u32;
            self.add(pidfd.as_raw_fd(), interest, token)?;
            Ok(Added::Watching(pidfd))
        }

        /// Fires the stop signal.
        pub(super) fn wake(&self) -> io::Result<()> {
            let one = 1u64.to_ne_bytes();
            // SAFETY: writes 8 bytes from a live buffer to the eventfd.
            let written = unsafe { libc::write(self.wake.as_raw_fd(), one.as_ptr().cast(), 8) };
            if written < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }

        /// Blocks until an event arrives; pushes the token of each ended child.
        pub(super) fn wait(&self, ended: &mut Vec<u64>) -> io::Result<()> {
            // SAFETY: zeroed epoll_events are valid output storage.
            let mut out: [libc::epoll_event; 16] = unsafe { std::mem::zeroed() };
            // SAFETY: at most 16 events out, no timeout.
            let n = unsafe {
                libc::epoll_wait(self.epoll.as_raw_fd(), out.as_mut_ptr(), out.len() as i32, -1)
            };
            if n < 0 {
                let error = io::Error::last_os_error();
                return if error.kind() == io::ErrorKind::Interrupted {
                    Ok(())
                } else {
                    Err(error)
                };
            }
            for event in &out[..n as usize] {
                let token = event.u64;
                if token != WAKE {
                    ended.push(token);
                }
            }
            Ok(())
        }

        fn add(&self, fd: libc::c_int, interest: u32, token: u64) -> io::Result<()> {
            let mut event = libc::epoll_event { events: interest, u64: token };
            // SAFETY: a live event for a descriptor the caller owns.
            let added = unsafe {
                libc::epoll_ctl(self.epoll.as_raw_fd(), libc::EPOLL_CTL_ADD, fd, &mut event)
            };
            if added < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }
    }
}

/// Other unix systems have no exit event here: each child gets its own wait
/// thread.
#[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
mod sys {
    use super::*;

    pub(super) type Registration = ();

    pub(super) enum Added {
        #[allow(dead_code)]
        Watching(Registration),
        #[allow(dead_code)]
        Exited,
        Unsupported,
    }

    pub(super) struct Events;

    impl Events {
        pub(super) fn new() -> io::Result<Events> {
            Ok(Events)
        }

        pub(super) fn add_child(&self, _pid: libc::pid_t, _token: u64) -> io::Result<Added> {
            Ok(Added::Unsupported)
        }

        pub(super) fn wake(&self) -> io::Result<()> {
            Ok(())
        }

        pub(super) fn wait(&self, _ended: &mut Vec<u64>) -> io::Result<()> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "no exit events"))
        }
    }
}

#[cfg(test)]
#[path = "reaper_tests.rs"]
mod tests;
