//! Work lanes: blocking work off request and echo threads, by kind, at a stated priority.
//!
//! The daemon twin of the app's `BackgroundWork` (CmuxNextWakeups). Every item states a [`Priority`]
//! (Chrome's `TaskPriority`), a [`Lane`] (Chrome's `MayBlock`, split by kind) and a [`Shutdown`]
//! behavior (Chrome's `TaskShutdownBehavior`), as in base/task/task_traits.h.
//!
//! - **Admission.** A lane runs at most `limit(priority)` items at once, counted over every priority:
//!   Files 4/3/2/1 (UserBlocking/UserVisible/BestEffort/Idle), System 6 with one slot only UserBlocking
//!   may take (Chrome's `kDefaultMaxSystemTasks`, net/dns/host_resolver_manager.cc), Cpu the
//!   performance cores minus one. Limits rise with priority, so a lower item never starts while a
//!   higher one waits.
//! - **Workers.** Each worker belongs to one priority class (UserInitiated, Utility, Background) for
//!   life and runs only that class's items. Linux cannot lower a thread's nice value without
//!   privilege, so a worker that once ran Idle work could never run UserBlocking work at nice 0; Chrome
//!   keeps separate foreground and background thread groups for the same reason
//!   (base/task/thread_pool/thread_pool_impl.cc).
//! - **Reclaim.** Workers start on demand. An idle worker waits [`WorkConfig::idle_timeout`] (30 s, as
//!   Chrome's reclaim time in thread_pool_impl.cc) while its class has more than
//!   [`WorkConfig::keep_alive`] workers (default 0) and then exits; at or below that count it waits
//!   with no timeout (thread_group_impl.cc `CanCleanupLockRequired`). An idle lane has no thread and no
//!   timer.
//! - **Shutdown.** [`Work::shutdown`] drops every item that has not started except
//!   [`Shutdown::BlockShutdown`] ones, refuses new ones the same way, and returns when every block item
//!   has run. It never waits for a started skip item (task_tracker.cc waits for those; cmux does not).
//!
//! ```ignore
//! let work = Work::new(WorkConfig::default());
//! let bytes = work.run(Priority::UserVisible, Lane::Files, Shutdown::SkipOnShutdown, move || std::fs::read(path));
//! work.post(Priority::BestEffort, Lane::Files, Shutdown::BlockShutdown, move || save(&state))?;
//! ```

use std::collections::VecDeque;
use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc::{self, Receiver, SyncSender, TryRecvError};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use crate::qos::ThreadQos;

/// How much a person waits for an item, as Chrome's `base::TaskPriority` plus `idle`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Priority {
    /// Nobody waits and it may wait without limit: indexing, prefetch, cleanup. Runs at Background.
    Idle,
    /// Nobody waits now: saves, the journal, automation. Runs at Utility.
    BestEffort,
    /// Its result shows on screen soon. Runs at UserInitiated.
    UserVisible,
    /// A person waits for it now: the result of a key, a click or an open. Runs at UserInitiated.
    UserBlocking,
}

impl Priority {
    /// Every priority, lowest first.
    pub const ALL: [Priority; 4] =
        [Priority::Idle, Priority::BestEffort, Priority::UserVisible, Priority::UserBlocking];

    fn index(self) -> usize {
        self as usize
    }

    fn class(self) -> WorkerClass {
        match self {
            Priority::UserBlocking | Priority::UserVisible => WorkerClass::Foreground,
            Priority::BestEffort => WorkerClass::BestEffort,
            Priority::Idle => WorkerClass::Idle,
        }
    }
}

/// What [`Work::shutdown`] does with an item, as Chrome's `TaskShutdownBehavior`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Shutdown {
    /// Dropped if it has not started (a [`Work::run`] caller gets [`WorkError::Dropped`]); a started
    /// one is not waited for. Reads and anything a later start redoes.
    #[default]
    SkipOnShutdown,
    /// Shutdown waits for it, queued or running: one short save whose loss loses a person's data.
    BlockShutdown,
}

/// The kind of blocking work an item does. Each lane has its own limits and workers, so a slow disk
/// never delays a DNS lookup and a long parse never delays a file read.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Lane {
    /// Disk I/O: reads, writes, directory listings, file-backed loads and saves.
    Files,
    /// System calls that wait on something outside the process (`getaddrinfo`, keychain, launchd).
    System,
    /// CPU-bound work too long for a request thread. It must not block.
    Cpu,
}

impl Lane {
    /// Every lane.
    pub const ALL: [Lane; 3] = [Lane::Files, Lane::System, Lane::Cpu];

    fn index(self) -> usize {
        self as usize
    }

    fn short_name(self) -> &'static str {
        match self {
            Lane::Files => "files",
            Lane::System => "sys",
            Lane::Cpu => "cpu",
        }
    }

    /// How many items may run on this lane, over every priority, before an item of `priority` waits.
    fn limits(self, cpu_width: usize) -> [usize; 4] {
        match self {
            Lane::Files => [1, 2, 3, 4],
            Lane::System => [5, 5, 5, 6],
            Lane::Cpu => [cpu_width.max(1); 4],
        }
    }
}

impl fmt::Display for Lane {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.short_name())
    }
}

/// The QoS a worker runs at for life. Linux cannot lower nice, so classes never share a worker.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WorkerClass {
    Foreground,
    BestEffort,
    Idle,
}

impl WorkerClass {
    const ALL: [WorkerClass; 3] =
        [WorkerClass::Foreground, WorkerClass::BestEffort, WorkerClass::Idle];

    fn index(self) -> usize {
        self as usize
    }

    fn qos(self) -> ThreadQos {
        match self {
            WorkerClass::Foreground => ThreadQos::UserInitiated,
            WorkerClass::BestEffort => ThreadQos::Utility,
            WorkerClass::Idle => ThreadQos::Background,
        }
    }

    fn short_name(self) -> &'static str {
        match self {
            WorkerClass::Foreground => "fg",
            WorkerClass::BestEffort => "be",
            WorkerClass::Idle => "idle",
        }
    }
}

/// Settings of one [`Work`]; one per process, built at the daemon's composition root.
#[derive(Clone, Debug)]
pub struct WorkConfig {
    /// Thread name prefix: workers are `<label>-<lane>-<fg|be|idle>` (Linux keeps 15 bytes).
    pub label: String,
    /// How many [`Lane::Cpu`] items run at once.
    pub cpu_width: usize,
    /// How long an idle worker above [`keep_alive`](Self::keep_alive) waits before it exits.
    pub idle_timeout: Duration,
    /// Workers per lane and class that wait with no timeout instead of exiting.
    pub keep_alive: usize,
}

impl Default for WorkConfig {
    fn default() -> Self {
        WorkConfig {
            label: "work".to_owned(),
            cpu_width: default_cpu_width(),
            idle_timeout: Duration::from_secs(30),
            keep_alive: 0,
        }
    }
}

/// The performance cores minus one (at least one), so CPU work always leaves a core to the request
/// and echo threads.
pub fn default_cpu_width() -> usize {
    performance_cores().saturating_sub(1).max(1)
}

#[cfg(target_os = "macos")]
fn performance_cores() -> usize {
    let mut cores: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    // SAFETY: the name is NUL-terminated, `cores` and `size` are live, writable and sized for a c_int.
    let status = unsafe {
        libc::sysctlbyname(
            c"hw.perflevel0.logicalcpu".as_ptr(),
            (&raw mut cores).cast(),
            &raw mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if status == 0 && cores > 0 {
        return cores as usize;
    }
    std::thread::available_parallelism().map_or(1, usize::from)
}

#[cfg(not(target_os = "macos"))]
fn performance_cores() -> usize {
    std::thread::available_parallelism().map_or(1, usize::from)
}

/// Why a [`Pending`] item gave no value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorkError {
    /// It never ran: shutdown dropped it or refused it.
    Dropped,
    /// Its body panicked (the daemon's panic hook has logged it).
    Panicked,
}

impl fmt::Display for WorkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            WorkError::Dropped => "work item dropped at shutdown",
            WorkError::Panicked => "work item panicked",
        })
    }
}

impl std::error::Error for WorkError {}

/// [`Work::post`] refused an item: shutdown has started and it is not a block item.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Refused;

impl fmt::Display for Refused {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("work refused after shutdown")
    }
}

impl std::error::Error for Refused {}

/// The result of a [`Work::run`] item.
#[must_use = "a run item's result is only read through its Pending"]
pub struct Pending<T> {
    result: Receiver<Result<T, WorkError>>,
}

impl<T> Pending<T> {
    /// Waits for the item. This blocks: never call it on a request or echo thread.
    pub fn wait(self) -> Result<T, WorkError> {
        self.result.recv().unwrap_or(Err(WorkError::Dropped))
    }

    /// The item's result if it has finished or was dropped, without waiting.
    pub fn try_wait(&self) -> Option<Result<T, WorkError>> {
        match self.result.try_recv() {
            Ok(result) => Some(result),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => Some(Err(WorkError::Dropped)),
        }
    }
}

/// What [`Work::shutdown`] did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ShutdownReport {
    /// Items that had not started and will never run.
    pub dropped: usize,
    /// Block items still queued or running when the deadline passed (0 without a deadline).
    pub unfinished_block: usize,
}

/// A snapshot of one lane, for `server.threads` and tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LaneStats {
    pub lane: Lane,
    /// Items waiting for admission.
    pub pending: usize,
    /// Items admitted: running or handed to a worker.
    pub running: usize,
    /// Live worker threads.
    pub workers: usize,
    /// Live workers not running an item.
    pub idle_workers: usize,
    pub workers_started: u64,
    pub workers_exited: u64,
    /// Times a worker woke from its wait, for an item, a timeout or spuriously.
    pub wakeups: u64,
    pub spawn_failures: u64,
    pub panics: u64,
}

/// Blocking work lanes. Build one per process and pass it by reference; tests build their own.
pub struct Work {
    lanes: [Arc<LaneShared>; 3],
}

impl Work {
    pub fn new(config: WorkConfig) -> Work {
        let config = Arc::new(config);
        Work { lanes: Lane::ALL.map(|lane| Arc::new(LaneShared::new(lane, Arc::clone(&config)))) }
    }

    /// Queues `body` on `lane` at `priority` and returns at once.
    pub fn post<F>(
        &self,
        priority: Priority,
        lane: Lane,
        shutdown: Shutdown,
        body: F,
    ) -> Result<(), Refused>
    where
        F: FnOnce() + Send + 'static,
    {
        self.lanes[lane.index()].submit(Job { body: Box::new(body), priority, shutdown })
    }

    /// Queues `body` on `lane` at `priority`; its result arrives through the returned [`Pending`]. A
    /// refused or dropped item resolves to [`WorkError::Dropped`].
    pub fn run<T, F>(
        &self,
        priority: Priority,
        lane: Lane,
        shutdown: Shutdown,
        body: F,
    ) -> Pending<T>
    where
        T: Send + 'static,
        F: FnOnce() -> T + Send + 'static,
    {
        let (sender, result) = mpsc::sync_channel(1);
        // A refused item drops `sender`, which resolves the Pending to Dropped.
        let _ = self.post(priority, lane, shutdown, move || deliver(&sender, body));
        Pending { result }
    }

    /// Starts shutdown and waits for every block item. See [`Work::shutdown_until`].
    pub fn shutdown(&self) -> ShutdownReport {
        self.shutdown_inner(None)
    }

    /// Drops every item that has not started except block items, refuses new ones the same way, wakes
    /// idle workers so they exit, and waits until every block item has run or `deadline` passes.
    pub fn shutdown_until(&self, deadline: Instant) -> ShutdownReport {
        self.shutdown_inner(Some(deadline))
    }

    fn shutdown_inner(&self, deadline: Option<Instant>) -> ShutdownReport {
        // Dropped bodies (and the senders of their Pendings) are dropped outside every lock, before the
        // wait, so their callers learn at once.
        let dropped = self.lanes.iter().flat_map(|lane| lane.close()).count();
        ShutdownReport {
            dropped,
            unfinished_block: self.lanes.iter().map(|lane| lane.wait_drained(deadline)).sum(),
        }
    }

    /// One row per lane.
    pub fn stats(&self) -> [LaneStats; 3] {
        self.lanes.each_ref().map(|lane| lane.stats())
    }
}

impl Drop for Work {
    /// Queued items still run; workers then exit at once instead of waiting for more.
    fn drop(&mut self) {
        for lane in &self.lanes {
            lane.release();
        }
    }
}

fn deliver<T, F: FnOnce() -> T>(sender: &SyncSender<Result<T, WorkError>>, body: F) {
    let result = catch_unwind(AssertUnwindSafe(body)).map_err(|_| WorkError::Panicked);
    // The caller may have dropped its Pending; nobody reads the result then.
    let _ = sender.send(result);
}

struct Job {
    body: Box<dyn FnOnce() + Send>,
    priority: Priority,
    shutdown: Shutdown,
}

#[derive(Default)]
struct ClassWorkers {
    live: usize,
    /// Live workers not running an item: waiting, or started and not yet at their first look.
    idle: usize,
    /// Workers inside a condvar wait.
    waiting: usize,
}

struct LaneState {
    pending: [VecDeque<Job>; 4],
    /// Admitted items per worker class, each with a worker that will take it.
    ready: [VecDeque<Job>; 3],
    /// Admitted items: in `ready` or running.
    running: usize,
    workers: [ClassWorkers; 3],
    /// Block items accepted and not yet finished.
    blocking: usize,
    closed: bool,
    released: bool,
    workers_started: u64,
    workers_exited: u64,
    wakeups: u64,
    spawn_failures: u64,
    panics: u64,
}

struct LaneShared {
    lane: Lane,
    limits: [usize; 4],
    config: Arc<WorkConfig>,
    // Lock carve-out: a short critical section over the queues and counters; no I/O, no item body and
    // no thread spawn runs under it.
    state: Mutex<LaneState>,
    ready_signal: [Condvar; 3],
    drained: Condvar,
}

impl LaneShared {
    fn new(lane: Lane, config: Arc<WorkConfig>) -> LaneShared {
        LaneShared {
            lane,
            limits: lane.limits(config.cpu_width),
            config,
            state: Mutex::new(LaneState {
                pending: Default::default(),
                ready: Default::default(),
                running: 0,
                workers: Default::default(),
                blocking: 0,
                closed: false,
                released: false,
                workers_started: 0,
                workers_exited: 0,
                wakeups: 0,
                spawn_failures: 0,
                panics: 0,
            }),
            ready_signal: [Condvar::new(), Condvar::new(), Condvar::new()],
            drained: Condvar::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, LaneState> {
        // Item bodies never run under the lock, so a poisoned lock still holds consistent state.
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn submit(self: &Arc<Self>, job: Job) -> Result<(), Refused> {
        let mut state = self.lock();
        if state.closed && job.shutdown != Shutdown::BlockShutdown {
            drop(state);
            drop(job);
            return Err(Refused);
        }
        if job.shutdown == Shutdown::BlockShutdown {
            state.blocking += 1;
        }
        state.pending[job.priority.index()].push_back(job);
        let starts = self.admit(&mut state);
        drop(state);
        self.start_workers(starts);
        Ok(())
    }

    /// Moves pending items, highest priority first, to their class's ready list while the lane is under
    /// their limit; wakes waiting workers for them and returns how many workers each class must start.
    fn admit(&self, state: &mut LaneState) -> [usize; 3] {
        let mut admitted = [0usize; 3];
        for priority in Priority::ALL.into_iter().rev() {
            while state.running < self.limits[priority.index()] {
                let Some(job) = state.pending[priority.index()].pop_front() else { break };
                let class = priority.class().index();
                state.running += 1;
                state.ready[class].push_back(job);
                admitted[class] += 1;
            }
        }
        let mut starts = [0usize; 3];
        for class in WorkerClass::ALL.map(WorkerClass::index) {
            for _ in 0..admitted[class].min(state.workers[class].waiting) {
                self.ready_signal[class].notify_one();
            }
            let missing = state.ready[class].len().saturating_sub(state.workers[class].idle);
            state.workers[class].live += missing;
            state.workers[class].idle += missing;
            starts[class] = missing;
        }
        starts
    }

    /// Starts the workers `admit` counted. They are counted live and idle already.
    fn start_workers(self: &Arc<Self>, starts: [usize; 3]) {
        for class in WorkerClass::ALL {
            for _ in 0..starts[class.index()] {
                let name = format!(
                    "{}-{}-{}",
                    self.config.label,
                    self.lane.short_name(),
                    class.short_name()
                );
                let lane = Arc::clone(self);
                // Detached: a worker that exits leaves nothing to join.
                if crate::spawn::spawn(name, class.qos(), move || lane.worker(class)).is_err() {
                    let mut state = self.lock();
                    state.workers[class.index()].live -= 1;
                    state.workers[class.index()].idle -= 1;
                    state.spawn_failures += 1;
                } else {
                    self.lock().workers_started += 1;
                }
            }
        }
    }

    fn worker(self: Arc<Self>, class: WorkerClass) {
        let index = class.index();
        let mut state = self.lock();
        let mut idle_deadline: Option<Instant> = None;
        loop {
            if let Some(job) = state.ready[index].pop_front() {
                state.workers[index].idle -= 1;
                drop(state);
                let blocks = job.shutdown == Shutdown::BlockShutdown;
                let panicked = catch_unwind(AssertUnwindSafe(job.body)).is_err();
                state = self.lock();
                state.panics += u64::from(panicked);
                state.running -= 1;
                state.workers[index].idle += 1;
                if blocks {
                    state.blocking -= 1;
                    if state.blocking == 0 {
                        self.drained.notify_all();
                    }
                }
                let starts = self.admit(&mut state);
                if starts != [0; 3] {
                    drop(state);
                    self.start_workers(starts);
                    state = self.lock();
                }
                idle_deadline = None;
                continue;
            }
            if state.closed || state.released {
                break;
            }
            state.workers[index].waiting += 1;
            if state.workers[index].live > self.config.keep_alive {
                let deadline =
                    *idle_deadline.get_or_insert_with(|| Instant::now() + self.config.idle_timeout);
                let Some(left) =
                    deadline.checked_duration_since(Instant::now()).filter(|left| !left.is_zero())
                else {
                    state.workers[index].waiting -= 1;
                    break;
                };
                state = self.ready_signal[index]
                    .wait_timeout(state, left)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
            } else {
                idle_deadline = None;
                state =
                    self.ready_signal[index].wait(state).unwrap_or_else(PoisonError::into_inner);
            }
            state.workers[index].waiting -= 1;
            state.wakeups += 1;
        }
        state.workers[index].live -= 1;
        state.workers[index].idle -= 1;
        state.workers_exited += 1;
    }

    /// Closes the lane and returns the items shutdown drops; wakes waiting workers so they exit.
    fn close(self: &Arc<Self>) -> Vec<Job> {
        let mut state = self.lock();
        state.closed = true;
        let mut dropped = Vec::new();
        for list in &mut state.pending {
            let (keep, drop): (VecDeque<Job>, VecDeque<Job>) =
                list.drain(..).partition(|job| job.shutdown == Shutdown::BlockShutdown);
            *list = keep;
            dropped.extend(drop);
        }
        let mut unadmitted = 0;
        for list in &mut state.ready {
            let (keep, drop): (VecDeque<Job>, VecDeque<Job>) =
                list.drain(..).partition(|job| job.shutdown == Shutdown::BlockShutdown);
            *list = keep;
            unadmitted += drop.len();
            dropped.extend(drop);
        }
        state.running -= unadmitted;
        for signal in &self.ready_signal {
            signal.notify_all();
        }
        let starts = self.admit(&mut state);
        drop(state);
        self.start_workers(starts);
        dropped
    }

    /// Waits until no block item is left or `deadline` passes; returns how many are left.
    fn wait_drained(&self, deadline: Option<Instant>) -> usize {
        let mut state = self.lock();
        while state.blocking > 0 {
            match deadline {
                None => state = self.drained.wait(state).unwrap_or_else(PoisonError::into_inner),
                Some(deadline) => {
                    let Some(left) = deadline
                        .checked_duration_since(Instant::now())
                        .filter(|left| !left.is_zero())
                    else {
                        break;
                    };
                    state = self
                        .drained
                        .wait_timeout(state, left)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
            }
        }
        state.blocking
    }

    fn release(&self) {
        let mut state = self.lock();
        state.released = true;
        for signal in &self.ready_signal {
            signal.notify_all();
        }
    }

    fn stats(&self) -> LaneStats {
        let state = self.lock();
        LaneStats {
            lane: self.lane,
            pending: state.pending.iter().map(VecDeque::len).sum(),
            running: state.running,
            workers: state.workers.iter().map(|class| class.live).sum(),
            idle_workers: state.workers.iter().map(|class| class.idle).sum(),
            workers_started: state.workers_started,
            workers_exited: state.workers_exited,
            wakeups: state.wakeups,
            spawn_failures: state.spawn_failures,
            panics: state.panics,
        }
    }
}

#[cfg(test)]
#[path = "work_tests.rs"]
mod tests;
