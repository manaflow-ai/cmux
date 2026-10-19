//! The event loop of a shared terminal host (`shared_host.rs`): one poller
//! thread and a small pool of workers, instead of six threads per terminal.
//!
//! The poller (kqueue on macOS, epoll on Linux; the design of
//! `cmux-mux2/src/unix/mux2d_poll.rs`) watches every terminal's PTY master,
//! listener, accept waker, client sockets and bootstrap socket, plus child
//! exits (EVFILT_PROC, pidfd) and timers. Registrations are one-shot: an
//! event runs its handler once, as a pool job, and the handler re-arms the
//! descriptor when it wants the next event. So the host code that used to run
//! on a dedicated thread per terminal runs unchanged, one readiness at a
//! time, on whichever worker is free.
//!
//! The pool keeps `core` workers (the parse workers) and starts more only
//! while every worker is busy: a job may still block (a PTY write to a
//! program that reads no input, a client that reads slowly), exactly where
//! its dedicated thread blocked before. Extra workers end after two idle
//! seconds. An idle shared host therefore runs its control thread, the
//! signal writer, the poller and the core workers, whatever its terminal
//! count.
//!
//! [`SerialJob`] keeps one terminal's work in order: jobs of one serial
//! queue never run at once, and a wake while it runs makes it run again.

use std::collections::{BinaryHeap, HashMap, VecDeque};
use std::io;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

type Job = Box<dyn FnOnce() + Send>;
type Handler = Box<dyn FnOnce() + Send>;

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// How long an extra worker waits for a job before it ends.
const EXTRA_WORKER_IDLE: Duration = Duration::from_secs(2);
/// No more workers than this, whatever blocks: a bound, not a target.
const MAX_WORKERS: usize = 1024;

static EXECUTOR: OnceLock<&'static Executor> = OnceLock::new();

/// The shared host's executor; `None` in every other process (one-terminal
/// hosts keep their threads).
pub(crate) fn executor() -> Option<&'static Executor> {
    EXECUTOR.get().copied()
}

/// Start the executor of this shared host, once.
pub(crate) fn start(core: usize) -> io::Result<&'static Executor> {
    if let Some(executor) = executor() {
        return Ok(executor);
    }
    let executor: &'static Executor = Box::leak(Box::new(Executor {
        poller: Poller::new()?,
        handlers: Mutex::new(HashMap::new()),
        timers: Mutex::new(BinaryHeap::new()),
        next_token: AtomicU64::new(1),
        pool: Pool {
            state: Mutex::new(PoolState::default()),
            ready: Condvar::new(),
            core: core.max(1),
        },
    }));
    let _ = EXECUTOR.set(executor);
    std::thread::Builder::new()
        .name("terminal-host-poller".into())
        .spawn(move || executor.run_poller())?;
    for _ in 0..executor.pool.core {
        executor.pool.spawn_worker(true)?;
    }
    Ok(executor)
}

pub(crate) struct Executor {
    poller: Poller,
    handlers: Mutex<HashMap<u64, Handler>>,
    timers: Mutex<BinaryHeap<std::cmp::Reverse<(Instant, u64)>>>,
    next_token: AtomicU64,
    pool: Pool,
}

impl Executor {
    fn token(&'static self) -> u64 {
        self.next_token.fetch_add(1, Ordering::Relaxed)
    }

    /// Run `job` on a worker.
    pub(crate) fn submit(&'static self, job: impl FnOnce() + Send + 'static) {
        self.pool.submit(Box::new(job));
    }

    /// Run `handler` (as a job) once `fd` is readable, hung up or failed.
    /// One-shot: call again for the next event. `fd` must stay open until
    /// the handler ran or [`Executor::forget`] dropped it.
    pub(crate) fn on_readable(
        &'static self,
        fd: RawFd,
        handler: impl FnOnce() + Send + 'static,
    ) -> io::Result<u64> {
        let token = self.token();
        lock(&self.handlers).insert(token, Box::new(handler));
        if let Err(error) = self.poller.arm_read(fd, token) {
            lock(&self.handlers).remove(&token);
            return Err(error);
        }
        Ok(token)
    }

    /// Drop a pending handler (a re-arm replaces its registration).
    pub(crate) fn forget_handler(&'static self, token: u64) {
        lock(&self.handlers).remove(&token);
    }

    /// Drop a pending readiness handler of `fd` (its descriptor closes).
    pub(crate) fn forget(&'static self, fd: RawFd, token: u64) {
        lock(&self.handlers).remove(&token);
        self.poller.disarm_read(fd);
    }

    /// Run `handler` (as a job) once `pid`, a child of this process, has
    /// ended (it stays unreaped). Err: the exit cannot be watched (the
    /// caller waits another way).
    pub(crate) fn on_exit(
        &'static self,
        pid: libc::pid_t,
        handler: impl FnOnce() + Send + 'static,
    ) -> io::Result<()> {
        let token = self.token();
        lock(&self.handlers).insert(token, Box::new(handler));
        match self.poller.watch_exit(pid, token) {
            Ok(()) => Ok(()),
            Err(error) => {
                lock(&self.handlers).remove(&token);
                Err(error)
            }
        }
    }

    /// Run `handler` (as a job) at `deadline`.
    pub(crate) fn at(&'static self, deadline: Instant, handler: impl FnOnce() + Send + 'static) {
        let token = self.token();
        lock(&self.handlers).insert(token, Box::new(handler));
        let earliest = {
            let mut timers = lock(&self.timers);
            let earliest = timers.peek().is_none_or(|top| deadline < top.0.0);
            timers.push(std::cmp::Reverse((deadline, token)));
            earliest
        };
        if earliest {
            self.poller.wake();
        }
    }

    fn fire(&'static self, token: u64) {
        if let Some(handler) = lock(&self.handlers).remove(&token) {
            self.pool.submit(handler);
        }
    }

    fn run_poller(&'static self) {
        let mut events = Vec::new();
        loop {
            let now = Instant::now();
            let timeout = {
                let mut timers = lock(&self.timers);
                while let Some(top) = timers.peek()
                    && top.0.0 <= now
                {
                    let std::cmp::Reverse((_, token)) = timers.pop().expect("peeked timer");
                    events.push(token);
                }
                timers.peek().map(|top| top.0.0.saturating_duration_since(now))
            };
            for token in events.drain(..) {
                self.fire(token);
            }
            if self.poller.wait(timeout, &mut events).is_err() {
                // A failed wait (EINTR is retried inside) must not spin.
                std::thread::sleep(Duration::from_millis(10));
            }
            for token in events.drain(..) {
                self.fire(token);
            }
        }
    }
}

#[derive(Default)]
struct PoolState {
    jobs: VecDeque<Job>,
    workers: usize,
    idle: usize,
}

struct Pool {
    state: Mutex<PoolState>,
    ready: Condvar,
    /// Workers that never end: the parse workers.
    core: usize,
}

impl Pool {
    fn submit(&'static self, job: Job) {
        let spawn = {
            let mut state = lock(&self.state);
            state.jobs.push_back(job);
            // Every worker is busy (or blocked): start one more, so a job
            // that blocks never holds up the others.
            state.idle < state.jobs.len() && state.workers < MAX_WORKERS
        };
        if spawn && self.spawn_worker(false).is_err() {
            // The running workers take the job when one is free.
        }
        self.ready.notify_one();
    }

    fn spawn_worker(&'static self, core: bool) -> io::Result<()> {
        lock(&self.state).workers += 1;
        let started = std::thread::Builder::new()
            .name(if core { "terminal-host-worker" } else { "terminal-host-extra" }.into())
            .spawn(move || self.run_worker(core));
        if let Err(error) = started {
            lock(&self.state).workers -= 1;
            return Err(error);
        }
        Ok(())
    }

    fn run_worker(&'static self, core: bool) {
        let mut state = lock(&self.state);
        loop {
            if let Some(job) = state.jobs.pop_front() {
                drop(state);
                // A job's panic ends only that job; the host code it runs
                // attributes and handles its own failures.
                let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
                state = lock(&self.state);
                continue;
            }
            state.idle += 1;
            if core {
                state = self.ready.wait(state).unwrap_or_else(PoisonError::into_inner);
                state.idle -= 1;
            } else {
                let (next, timeout) = self
                    .ready
                    .wait_timeout(state, EXTRA_WORKER_IDLE)
                    .unwrap_or_else(PoisonError::into_inner);
                state = next;
                state.idle -= 1;
                if timeout.timed_out() && state.jobs.is_empty() {
                    state.workers -= 1;
                    return;
                }
            }
        }
    }
}

/// One terminal's ordered work: `wake` runs `task` on a worker unless it
/// is queued or running already; a wake while it runs makes it run once
/// more. `task` runs until it returns false (its work is done for good).
pub(crate) struct SerialJob {
    state: Mutex<SerialState>,
    task: Mutex<Option<Box<dyn FnMut() -> bool + Send>>>,
}

#[derive(Default)]
struct SerialState {
    queued: bool,
    running: bool,
    again: bool,
}

impl SerialJob {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self { state: Mutex::new(SerialState::default()), task: Mutex::new(None) })
    }

    /// Install the task and run it once.
    pub(crate) fn install(
        self: &Arc<Self>,
        executor: &'static Executor,
        task: impl FnMut() -> bool + Send + 'static,
    ) {
        *lock(&self.task) = Some(Box::new(task));
        self.wake(executor);
    }

    pub(crate) fn wake(self: &Arc<Self>, executor: &'static Executor) {
        {
            let mut state = lock(&self.state);
            if state.running {
                state.again = true;
                return;
            }
            if state.queued {
                return;
            }
            state.queued = true;
        }
        let job = self.clone();
        executor.submit(move || job.run());
    }

    fn run(&self) {
        {
            let mut state = lock(&self.state);
            state.queued = false;
            state.running = true;
            state.again = false;
        }
        loop {
            let more = {
                let mut task = lock(&self.task);
                match task.as_mut() {
                    // The panic is the task's own; it ends the task.
                    Some(run) => std::panic::catch_unwind(std::panic::AssertUnwindSafe(run))
                        .unwrap_or_default(),
                    None => true,
                }
            };
            if !more {
                lock(&self.task).take();
            }
            let mut state = lock(&self.state);
            if state.again && more {
                state.again = false;
                continue;
            }
            state.running = false;
            return;
        }
    }
}

// ---------------------------------------------------------------- macOS ----

#[cfg(target_os = "macos")]
struct Poller {
    kq: RawFd,
}

#[cfg(target_os = "macos")]
impl Poller {
    fn new() -> io::Result<Self> {
        // SAFETY: kqueue has no preconditions; the descriptor is ours.
        let kq = unsafe { libc::kqueue() };
        if kq < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: close-on-exec on our own descriptor.
        unsafe { libc::fcntl(kq, libc::F_SETFD, libc::FD_CLOEXEC) };
        let poller = Self { kq };
        poller.change(0, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0, 0)?;
        Ok(poller)
    }

    fn change(
        &self,
        ident: usize,
        filter: i16,
        flags: u16,
        fflags: u32,
        token: u64,
    ) -> io::Result<()> {
        // SAFETY: a zeroed kevent is valid; one change, no event list.
        unsafe {
            let mut event: libc::kevent = std::mem::zeroed();
            event.ident = ident;
            event.filter = filter;
            event.flags = flags;
            event.fflags = fflags;
            event.udata = token as usize as *mut libc::c_void;
            if libc::kevent(self.kq, &event, 1, std::ptr::null_mut(), 0, std::ptr::null()) < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(())
    }

    fn arm_read(&self, fd: RawFd, token: u64) -> io::Result<()> {
        let ident = usize::try_from(fd).map_err(|_| io::Error::from_raw_os_error(libc::EBADF))?;
        self.change(ident, libc::EVFILT_READ, libc::EV_ADD | libc::EV_ONESHOT, 0, token)
    }

    fn disarm_read(&self, fd: RawFd) {
        if let Ok(ident) = usize::try_from(fd) {
            let _ = self.change(ident, libc::EVFILT_READ, libc::EV_DELETE, 0, 0);
        }
    }

    fn watch_exit(&self, pid: libc::pid_t, token: u64) -> io::Result<()> {
        let ident = usize::try_from(pid).map_err(|_| io::Error::from_raw_os_error(libc::ESRCH))?;
        self.change(
            ident,
            libc::EVFILT_PROC,
            libc::EV_ADD | libc::EV_ONESHOT,
            libc::NOTE_EXIT,
            token,
        )
    }

    fn wake(&self) {
        let _ = self.change(0, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER, 0);
    }

    fn wait(&self, timeout: Option<Duration>, out: &mut Vec<u64>) -> io::Result<()> {
        // SAFETY: zeroed kevents are valid out-buffers.
        let mut events: [libc::kevent; 64] = unsafe { std::mem::zeroed() };
        let spec = timeout.map(|timeout| libc::timespec {
            tv_sec: timeout.as_secs().min(i64::MAX as u64) as libc::time_t,
            tv_nsec: libc::c_long::from(timeout.subsec_nanos() as i32),
        });
        let spec_ptr = spec.as_ref().map_or(std::ptr::null(), std::ptr::from_ref);
        // SAFETY: the event buffer holds 64 entries; spec outlives the call.
        let count = unsafe {
            libc::kevent(self.kq, std::ptr::null(), 0, events.as_mut_ptr(), 64, spec_ptr)
        };
        if count < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::Interrupted { Ok(()) } else { Err(error) };
        }
        for event in &events[..count as usize] {
            if event.filter != libc::EVFILT_USER {
                out.push(event.udata as usize as u64);
            }
        }
        Ok(())
    }
}

// ---------------------------------------------------------------- Linux ----

#[cfg(target_os = "linux")]
const WAKE_TOKEN: u64 = 0;

#[cfg(target_os = "linux")]
struct Poller {
    epoll: RawFd,
    wake_fd: RawFd,
    /// Descriptors added once (EPOLL_CTL_ADD), re-armed with MOD after.
    known: Mutex<std::collections::HashSet<RawFd>>,
    /// pidfd -> token of a watched child exit.
    pidfds: Mutex<HashMap<u64, RawFd>>,
}

#[cfg(target_os = "linux")]
impl Poller {
    fn new() -> io::Result<Self> {
        // SAFETY: plain system calls that create descriptors we own.
        let epoll = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
        if epoll < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: as above.
        let wake_fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if wake_fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut event = libc::epoll_event { events: libc::EPOLLIN as u32, u64: WAKE_TOKEN };
        // SAFETY: registering our eventfd with a valid event.
        if unsafe { libc::epoll_ctl(epoll, libc::EPOLL_CTL_ADD, wake_fd, &mut event) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            epoll,
            wake_fd,
            known: Mutex::new(std::collections::HashSet::new()),
            pidfds: Mutex::new(HashMap::new()),
        })
    }

    fn arm_read(&self, fd: RawFd, token: u64) -> io::Result<()> {
        let mut event = libc::epoll_event {
            events: (libc::EPOLLIN | libc::EPOLLRDHUP | libc::EPOLLONESHOT) as u32,
            u64: token,
        };
        let mut known = lock(&self.known);
        let op = if known.contains(&fd) { libc::EPOLL_CTL_MOD } else { libc::EPOLL_CTL_ADD };
        // SAFETY: a valid event for a descriptor the caller keeps open.
        let mut result = unsafe { libc::epoll_ctl(self.epoll, op, fd, &mut event) };
        if result < 0 {
            // The other operation: the descriptor was closed and reused, or
            // added by another path.
            let retry =
                if op == libc::EPOLL_CTL_MOD { libc::EPOLL_CTL_ADD } else { libc::EPOLL_CTL_MOD };
            // SAFETY: as above.
            result = unsafe { libc::epoll_ctl(self.epoll, retry, fd, &mut event) };
        }
        if result < 0 {
            return Err(io::Error::last_os_error());
        }
        known.insert(fd);
        Ok(())
    }

    fn disarm_read(&self, fd: RawFd) {
        if lock(&self.known).remove(&fd) {
            // SAFETY: removing a registration; a null event is allowed.
            unsafe { libc::epoll_ctl(self.epoll, libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut()) };
        }
    }

    fn watch_exit(&self, pid: libc::pid_t, token: u64) -> io::Result<()> {
        // SAFETY: pidfd_open takes a pid and flags.
        let pidfd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        if pidfd < 0 {
            return Err(io::Error::last_os_error());
        }
        let pidfd = pidfd as RawFd;
        // SAFETY: close-on-exec on our own descriptor.
        unsafe { libc::fcntl(pidfd, libc::F_SETFD, libc::FD_CLOEXEC) };
        let mut event =
            libc::epoll_event { events: (libc::EPOLLIN | libc::EPOLLONESHOT) as u32, u64: token };
        // SAFETY: registering our own pidfd.
        if unsafe { libc::epoll_ctl(self.epoll, libc::EPOLL_CTL_ADD, pidfd, &mut event) } < 0 {
            let error = io::Error::last_os_error();
            // SAFETY: closing our own pidfd.
            unsafe { libc::close(pidfd) };
            return Err(error);
        }
        lock(&self.pidfds).insert(token, pidfd);
        Ok(())
    }

    fn wake(&self) {
        let one = 1u64;
        // SAFETY: an 8-byte write to our eventfd.
        unsafe { libc::write(self.wake_fd, (&raw const one).cast(), 8) };
    }

    fn wait(&self, timeout: Option<Duration>, out: &mut Vec<u64>) -> io::Result<()> {
        let mut events = [libc::epoll_event { events: 0, u64: 0 }; 64];
        let millis = timeout.map_or(-1, |timeout| {
            // Round up, so a timer never fires a millisecond early.
            libc::c_int::try_from(timeout.as_micros().div_ceil(1000)).unwrap_or(libc::c_int::MAX)
        });
        // SAFETY: the event buffer holds 64 entries.
        let count = unsafe { libc::epoll_wait(self.epoll, events.as_mut_ptr(), 64, millis) };
        if count < 0 {
            let error = io::Error::last_os_error();
            return if error.kind() == io::ErrorKind::Interrupted { Ok(()) } else { Err(error) };
        }
        for event in &events[..count as usize] {
            let token = event.u64;
            if token == WAKE_TOKEN {
                let mut value = 0u64;
                // SAFETY: an 8-byte read from our eventfd.
                unsafe { libc::read(self.wake_fd, (&raw mut value).cast(), 8) };
                continue;
            }
            if let Some(pidfd) = lock(&self.pidfds).remove(&token) {
                // SAFETY: the pidfd is ours; its one event arrived.
                unsafe {
                    libc::epoll_ctl(self.epoll, libc::EPOLL_CTL_DEL, pidfd, std::ptr::null_mut());
                    libc::close(pidfd);
                }
            }
            out.push(token);
        }
        Ok(())
    }
}
