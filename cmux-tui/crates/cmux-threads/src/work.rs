//! Work lanes: blocking work off request and echo threads, by kind, at a stated priority.
//!
//! The daemon twin of the app's `BackgroundWork` (CmuxNextWakeups). Every item states a [`Priority`]
//! (Chrome's `TaskPriority`), a [`Lane`] (Chrome's `MayBlock`, split by kind) and a [`Shutdown`]
//! behavior (Chrome's `TaskShutdownBehavior`), as in base/task/task_traits.h.
//!
//! - **Admission.** A lane runs at most `limit(priority)` items at once, counted over every priority:
//!   Files 4/3/2/1 (UserBlocking/UserVisible/BestEffort/Idle), System 6/5/2/1 with one slot only
//!   UserBlocking may take (Chrome's `kDefaultMaxSystemTasks`, net/dns/host_resolver_manager.cc), Cpu
//!   the performance cores minus one (at least 2) with BestEffort at 2 and Idle at 1, User 4 for the
//!   person's UserBlocking requests only (its own lane, so they never queue behind System). So BestEffort
//!   plus Idle never hold more than 2 slots of a lane and Idle never more than 1 (Chrome's
//!   `kMaxBestEffortTasks`, base/task/thread_pool/thread_pool_impl.cc). Limits rise with priority, so
//!   a lower item never starts while a higher one waits. An item inside [`will_block`] (Chrome's
//!   `ScopedBlockingCall` with `BlockingType::WILL_BLOCK`) stops counting until it leaves, so a wait
//!   of minutes (git hooks, a remote, a lock another such item holds) never holds a slot
//!   (base/task/thread_pool/thread_group_impl.cc raises `max_tasks` for it at once).
//! - **Workers.** Each worker belongs to one priority class (UserInitiated, Utility, Background) for
//!   life and runs only that class's items. Linux cannot lower a thread's nice value without
//!   privilege, so a worker that once ran Idle work could never run UserBlocking work at nice 0; Chrome
//!   keeps separate foreground and background thread groups for the same reason
//!   (base/task/thread_pool/thread_pool_impl.cc). A Linux thread also starts at its creator's nice
//!   value, so a thread above a class's nice value (an Idle worker, a Utility caller) never starts a
//!   worker of that class itself: the [`Work`]'s launcher thread does.
//! - **Reclaim.** Workers start on demand. An idle worker waits [`WorkConfig::idle_timeout`] (30 s, as
//!   Chrome's reclaim time in thread_pool_impl.cc) while its class has more than
//!   [`WorkConfig::keep_alive`] workers (default 0) and then exits; at or below that count it waits
//!   with no timeout (thread_group_impl.cc `CanCleanupLockRequired`). An idle lane has no worker and
//!   no timer.
//! - **Delay.** [`Work::post_delayed`] holds an item on one `<label>-delay` thread until it is due
//!   (Chrome's `DelayedTaskManager`), so a retry with backoff reposts itself instead of sleeping on a
//!   thread of its own; that thread waits with no timeout while nothing is delayed (`work_delayed.rs`).
//! - **Sync primitives.** An item may block on I/O but not wait for other work: each runs under
//!   [`crate::blocking::with_sync_primitives_disallowed`], so a checked receive, join or
//!   condition-variable wait in it records a `lane-sync` site (never a panic), as Chrome's
//!   task_tracker.cc runs a task without `WithBaseSyncPrimitives()` under
//!   `ScopedDisallowBaseSyncPrimitives`.
//! - **Shutdown.** As Chrome's task_tracker.cc: [`Work::shutdown`] drops every item that has not
//!   started except [`Shutdown::BlockShutdown`] ones, refuses new ones the same way, and returns when
//!   every block item and every started [`Shutdown::SkipOnShutdown`] item has finished. It never waits
//!   for a [`Shutdown::ContinueOnShutdown`] item. Shutdown waits for block items, so it raises them,
//!   as Chrome runs BLOCK_SHUTDOWN tasks at a normal thread priority once shutdown starts: a queued
//!   block item (and one posted later) runs at [`Priority::UserBlocking`] on a foreground worker, and a
//!   block item running on a BestEffort or Idle worker gets its worker raised to UserInitiated before
//!   shutdown waits for it (on Linux only when the process may lower nice values; see `work_boost.rs`).
//!
//! ```ignore
//! let work = Work::new(WorkConfig::default())?;
//! let bytes = work.run(Priority::UserVisible, Lane::Files, Shutdown::SkipOnShutdown, move || std::fs::read(path));
//! work.post(Priority::BestEffort, Lane::Files, Shutdown::BlockShutdown, move || save(&state))?;
//! ```

use std::cell::RefCell;
use std::collections::VecDeque;
use std::fmt;
use std::io;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
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
    /// one is not waited for. Work whose half-done state is harmless: prefetch, probes.
    ContinueOnShutdown,
    /// Dropped if it has not started; shutdown waits for a started one. Reads and anything a later
    /// start redoes.
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
    /// Work a person waits on now that may block (a SQLite commit, a file, a terminal host): the
    /// requests of the person's own connection, at [`Priority::UserBlocking`]. A lane of its own, so
    /// input from the person never queues behind automation's or background blocking work on
    /// [`Lane::System`] (the person's queue goes first, as Chrome's `kUserInput` queue). Nothing else
    /// posts here.
    User,
}

impl Lane {
    /// Every lane.
    pub const ALL: [Lane; 4] = [Lane::Files, Lane::System, Lane::Cpu, Lane::User];

    fn index(self) -> usize {
        self as usize
    }

    fn short_name(self) -> &'static str {
        match self {
            Lane::Files => "files",
            Lane::System => "sys",
            Lane::Cpu => "cpu",
            Lane::User => "user",
        }
    }

    /// How many items may run on this lane, over every priority, before an item of `priority` waits.
    fn limits(self, cpu_width: usize) -> [usize; 4] {
        match self {
            Lane::Files => [1, 2, 3, 4],
            Lane::System => [1, 2, 5, 6],
            Lane::Cpu => {
                let width = cpu_width.max(2);
                [1, 2.min(width - 1), width, width]
            }
            // Only UserBlocking items are posted; the lower limits keep the lane's rules (they rise
            // with priority, best effort and idle at most 2 and 1) for an item posted there by mistake.
            Lane::User => [1, 2, 2, 4],
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
    /// Thread name prefix: workers are `<label>-<lane>-<fg|be|idle>`, the launcher `<label>-launch`
    /// (Linux keeps 15 bytes).
    pub label: String,
    /// How many [`Lane::Cpu`] items run at once; at least 2, so one slot is never BestEffort or Idle.
    pub cpu_width: usize,
    /// How long an idle worker above [`keep_alive`](Self::keep_alive) waits before it exits.
    pub idle_timeout: Duration,
    /// Workers per lane and class that wait with no timeout instead of exiting.
    pub keep_alive: usize,
    /// Starts every worker and the launcher thread.
    pub spawner: Spawner,
}

impl Default for WorkConfig {
    fn default() -> Self {
        WorkConfig {
            label: "work".to_owned(),
            cpu_width: default_cpu_width(),
            idle_timeout: Duration::from_secs(30),
            keep_alive: 0,
            spawner: Spawner::default(),
        }
    }
}

/// A thread body handed to a [`Spawner`].
pub type ThreadBody = Box<dyn FnOnce() + Send>;

type SpawnFn = dyn Fn(String, ThreadQos, ThreadBody) -> io::Result<()> + Send + Sync;

/// Starts a detached thread named `name` at `qos`: [`crate::spawn::spawn`] by default, a stand-in
/// that fails in tests.
#[derive(Clone)]
pub struct Spawner(Arc<SpawnFn>);

impl Spawner {
    pub fn new(
        spawn: impl Fn(String, ThreadQos, ThreadBody) -> io::Result<()> + Send + Sync + 'static,
    ) -> Spawner {
        Spawner(Arc::new(spawn))
    }

    fn spawn(&self, name: String, qos: ThreadQos, body: ThreadBody) -> io::Result<()> {
        (self.0)(name, qos, body)
    }
}

impl Default for Spawner {
    fn default() -> Self {
        // The handle is dropped: the thread is detached and leaves nothing to join.
        Spawner::new(|name, qos, body| crate::spawn::spawn(name, qos, body).map(drop))
    }
}

impl fmt::Debug for Spawner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Spawner")
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
    /// It never ran: shutdown dropped or refused it, or no worker thread could be started for it.
    Dropped,
    /// Its body panicked (the daemon's panic hook has logged it).
    Panicked,
}

impl fmt::Display for WorkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            WorkError::Dropped => "work item dropped before it ran",
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
    /// Block items still queued or running, plus started skip items still running, when the deadline
    /// passed (0 without a deadline).
    pub unfinished: usize,
}

/// A snapshot of one lane, for `server.threads` and tests.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LaneStats {
    pub lane: Lane,
    /// Items waiting for admission.
    pub pending: usize,
    /// Items admitted: running or handed to a worker.
    pub running: usize,
    /// Running items inside [`will_block`], which no limit counts.
    pub blocked: usize,
    /// Live worker threads.
    pub workers: usize,
    /// Live workers not running an item.
    pub idle_workers: usize,
    /// Items the lane accepted from [`Work::post`] or [`Work::run`], refused ones not counted.
    pub posted: u64,
    pub workers_started: u64,
    pub workers_exited: u64,
    /// Times a worker woke from its wait, for an item, a timeout or spuriously.
    pub wakeups: u64,
    pub spawn_failures: u64,
    /// Items whose body panicked, [`Work::post`] and [`Work::run`] ones alike.
    pub panics: u64,
    /// Block items running on a BestEffort or Idle worker whose worker shutdown raised.
    pub shutdown_raises: u64,
    /// Such items whose raise the kernel or the Linux nice rule refused.
    pub shutdown_raise_refusals: u64,
}

/// Blocking work lanes. Build one per process and pass it by reference; tests build their own.
pub struct Work {
    lanes: [Arc<LaneShared>; 4],
    /// Items posted with a delay, until they are due ([`Work::post_delayed`]).
    delayed: delayed::Delayed,
}

impl Work {
    /// Builds the lanes. On Linux it also starts the launcher thread, which keeps the calling thread's
    /// nice value: build the `Work` on a thread at the process's base nice (the composition root).
    pub fn new(config: WorkConfig) -> io::Result<Work> {
        Work::with_booster(config, boost::Booster::system())
    }

    /// [`Work::new`] with the seam that raises a running block item's worker at shutdown; tests
    /// count its raises and ends.
    fn with_booster(config: WorkConfig, booster: boost::Booster) -> io::Result<Work> {
        let config = Arc::new(config);
        let launcher = Launcher::start(&config)?.map(Arc::new);
        Ok(Work {
            delayed: delayed::Delayed::new(Arc::clone(&config), launcher.clone()),
            lanes: Lane::ALL.map(|lane| {
                Arc::new(LaneShared::new(
                    lane,
                    Arc::clone(&config),
                    launcher.clone(),
                    booster.clone(),
                ))
            }),
        })
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

    /// Queues `body` on `lane` at `priority` once `delay` has passed and returns at once, as Chrome's
    /// `PostDelayedTask` (base/task/thread_pool/delayed_task_manager.cc). A retry reposts itself this
    /// way instead of sleeping on a thread between tries. A delayed item never blocks shutdown: with a
    /// delay, [`Shutdown::BlockShutdown`] is [`Shutdown::SkipOnShutdown`], shutdown drops a waiting
    /// item and refuses a new one, as Chrome refuses a delayed task once shutdown has started
    /// (base/task/thread_pool/task_tracker.cc `WillPostTask`). A zero delay is [`Work::post`].
    pub fn post_delayed<F>(
        &self,
        delay: Duration,
        priority: Priority,
        lane: Lane,
        shutdown: Shutdown,
        body: F,
    ) -> Result<(), Refused>
    where
        F: FnOnce() + Send + 'static,
    {
        let job = Job { body: Box::new(body), priority, shutdown };
        let lane = &self.lanes[lane.index()];
        if delay.is_zero() {
            return lane.submit(job);
        }
        self.delayed.post(delay, lane, job)
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

    /// Starts shutdown and waits for every awaited item. See [`Work::shutdown_until`].
    pub fn shutdown(&self) -> ShutdownReport {
        self.shutdown_inner(None)
    }

    /// Drops every item that has not started except block items, refuses new ones the same way, wakes
    /// idle workers so they exit, and waits until every block item and every started skip item has
    /// finished or `deadline` passes.
    pub fn shutdown_until(&self, deadline: Instant) -> ShutdownReport {
        self.shutdown_inner(Some(deadline))
    }

    fn shutdown_inner(&self, deadline: Option<Instant>) -> ShutdownReport {
        // Dropped bodies (and the senders of their Pendings) are dropped outside every lock, before the
        // wait, so their callers learn at once.
        let dropped =
            self.delayed.close().len() + self.lanes.iter().flat_map(|lane| lane.close()).count();
        ShutdownReport {
            dropped,
            unfinished: self.lanes.iter().map(|lane| lane.wait_drained(deadline)).sum(),
        }
    }

    /// One row per lane.
    pub fn stats(&self) -> [LaneStats; 4] {
        self.lanes.each_ref().map(|lane| lane.stats())
    }

    /// Items posted with [`Work::post_delayed`] still waiting for their delay.
    pub fn delayed_pending(&self) -> usize {
        self.delayed.pending()
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

/// Items of one lane that may be inside [`will_block`] at once; past it an item keeps its slot.
/// Chrome caps a thread group's growth the same way (`kMaxNumberOfWorkers`, thread_group_impl.cc).
const MAX_BLOCKED: usize = 64;

thread_local! {
    /// The lane of the item this worker runs, outside [`will_block`]; `None` on other threads.
    static CURRENT_LANE: RefCell<Option<Arc<LaneShared>>> = const { RefCell::new(None) };
}

/// Runs `f`, a call that waits a long or unbounded time on something outside the process: a child
/// process that runs the user's hooks, a remote, a lock another such call holds. Chrome's
/// `ScopedBlockingCall(BlockingType::WILL_BLOCK)` (base/threading/scoped_blocking_call.h): on a work
/// item, the item stops counting against its lane's limits while `f` runs, so the lane may admit
/// one more item, and counts again after. Anywhere else (and nested) it only runs `f`.
pub fn will_block<R>(f: impl FnOnce() -> R) -> R {
    let Some(lane) = CURRENT_LANE.with(RefCell::take) else { return f() };
    let counted = lane.enter_blocked();
    let _leave = LeaveBlocked { lane: Some(lane), counted };
    f()
}

/// Ends a [`will_block`] scope, unwinding included.
struct LeaveBlocked {
    lane: Option<Arc<LaneShared>>,
    counted: bool,
}

impl Drop for LeaveBlocked {
    fn drop(&mut self) {
        let Some(lane) = self.lane.take() else { return };
        if self.counted {
            lane.lock().blocked -= 1;
        }
        CURRENT_LANE.with(|current| *current.borrow_mut() = Some(lane));
    }
}

/// Sends the body's result. A panic is sent as [`WorkError::Panicked`] and raised again, so the worker
/// counts it as it counts a [`Work::post`] item's.
fn deliver<T, F: FnOnce() -> T>(sender: &SyncSender<Result<T, WorkError>>, body: F) {
    // The caller may have dropped its Pending; nobody reads the result then.
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => {
            let _ = sender.send(Ok(value));
        }
        Err(payload) => {
            let _ = sender.send(Err(WorkError::Panicked));
            resume_unwind(payload);
        }
    }
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
    /// Running items inside `will_block`: admission does not count them.
    blocked: usize,
    workers: [ClassWorkers; 3],
    /// Items shutdown waits for: block items from acceptance and skip items from their start, until
    /// they finish.
    awaited: usize,
    closed: bool,
    released: bool,
    posted: u64,
    workers_started: u64,
    workers_exited: u64,
    wakeups: u64,
    spawn_failures: u64,
    panics: u64,
    /// Block items running on a BestEffort or Idle worker: the ones shutdown raises.
    raises: boost::Raises,
}

struct LaneShared {
    lane: Lane,
    limits: [usize; 4],
    config: Arc<WorkConfig>,
    launcher: Option<Arc<Launcher>>,
    /// Raises the worker of a running block item at shutdown.
    booster: boost::Booster,
    // Lock carve-out: a short critical section over the queues and counters; no I/O, no item body and
    // no thread spawn runs under it.
    state: Mutex<LaneState>,
    ready_signal: [Condvar; 3],
    drained: Condvar,
}

impl LaneShared {
    fn new(
        lane: Lane,
        config: Arc<WorkConfig>,
        launcher: Option<Arc<Launcher>>,
        booster: boost::Booster,
    ) -> LaneShared {
        LaneShared {
            lane,
            limits: lane.limits(config.cpu_width),
            config,
            launcher,
            booster,
            state: Mutex::new(LaneState {
                pending: Default::default(),
                ready: Default::default(),
                running: 0,
                blocked: 0,
                workers: Default::default(),
                awaited: 0,
                closed: false,
                released: false,
                posted: 0,
                workers_started: 0,
                workers_exited: 0,
                wakeups: 0,
                spawn_failures: 0,
                panics: 0,
                raises: boost::Raises::default(),
            }),
            ready_signal: [Condvar::new(), Condvar::new(), Condvar::new()],
            drained: Condvar::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, LaneState> {
        // Item bodies never run under the lock, so a poisoned lock still holds consistent state.
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn submit(self: &Arc<Self>, mut job: Job) -> Result<(), Refused> {
        let mut state = self.lock();
        if state.closed && job.shutdown != Shutdown::BlockShutdown {
            drop(state);
            drop(job);
            return Err(Refused);
        }
        state.posted += 1;
        if job.shutdown == Shutdown::BlockShutdown {
            state.awaited += 1;
            // Shutdown waits for it: it runs on a foreground worker.
            if state.closed {
                job.priority = Priority::UserBlocking;
            }
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
            while state.running < self.limits[priority.index()] + state.blocked {
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

    /// Starts the workers `admit` counted, through the launcher when this thread's nice value is above
    /// the class's. They are counted live and idle already.
    fn start_workers(self: &Arc<Self>, starts: [usize; 3]) {
        for class in WorkerClass::ALL {
            let count = starts[class.index()];
            if count == 0 {
                continue;
            }
            let launcher = self.launcher.as_ref().filter(|_| !can_start_at(class.qos()));
            for _ in 0..count {
                let Some(launcher) = launcher else {
                    self.spawn_worker(class);
                    continue;
                };
                if let Err(mpsc::SendError(launch)) =
                    launcher.requests.send(Launch::Worker { lane: Arc::clone(self), class })
                {
                    // The launcher is gone only if it panicked: start the worker here, at this
                    // thread's nice value, rather than strand its item.
                    launch.start();
                }
            }
        }
    }

    /// Starts one worker of `class`, counted live and idle already; on failure gives its item back.
    fn spawn_worker(self: &Arc<Self>, class: WorkerClass) {
        let name =
            format!("{}-{}-{}", self.config.label, self.lane.short_name(), class.short_name());
        let lane = Arc::clone(self);
        let started =
            self.config.spawner.spawn(name, class.qos(), Box::new(move || lane.worker(class)));
        let mut state = self.lock();
        let dropped = match started {
            Ok(()) => {
                state.workers_started += 1;
                Vec::new()
            }
            Err(_) => self.worker_not_started(&mut state, class),
        };
        drop(state);
        // Dropped bodies (and the senders of their Pendings) are dropped outside the lock.
        drop(dropped);
    }

    /// Stops counting the calling item against the lane's limits (see [`will_block`]) and admits
    /// what that lets start; false when [`MAX_BLOCKED`] items are already out of the count.
    fn enter_blocked(self: &Arc<Self>) -> bool {
        let mut state = self.lock();
        if state.blocked >= MAX_BLOCKED {
            return false;
        }
        state.blocked += 1;
        let starts = self.admit(&mut state);
        drop(state);
        self.start_workers(starts);
        true
    }

    /// A worker `admit` counted did not start. Items of its class that no live worker will take go
    /// back to the front of their pending lists, where the next finished item admits them again. When
    /// no item runs nothing would, so every pending item is dropped (and returned, to drop unlocked).
    fn worker_not_started(&self, state: &mut LaneState, class: WorkerClass) -> Vec<Job> {
        let index = class.index();
        state.workers[index].live -= 1;
        state.workers[index].idle -= 1;
        state.spawn_failures += 1;
        let uncovered = state.ready[index].len().saturating_sub(state.workers[index].idle);
        for _ in 0..uncovered {
            let Some(job) = state.ready[index].pop_back() else { break };
            state.running -= 1;
            state.pending[job.priority.index()].push_front(job);
        }
        if state.running > 0 {
            return Vec::new();
        }
        let dropped: Vec<Job> = state.pending.iter_mut().flat_map(|list| list.drain(..)).collect();
        let blocks = dropped.iter().filter(|job| job.shutdown == Shutdown::BlockShutdown).count();
        state.awaited -= blocks;
        if blocks > 0 && state.awaited == 0 {
            self.drained.notify_all();
        }
        dropped
    }

    fn worker(self: Arc<Self>, class: WorkerClass) {
        let index = class.index();
        let mut state = self.lock();
        let mut idle_deadline: Option<Instant> = None;
        loop {
            if let Some(job) = state.ready[index].pop_front() {
                state.workers[index].idle -= 1;
                // Shutdown waits for a block item from its acceptance and for a skip item from now.
                let awaited = job.shutdown != Shutdown::ContinueOnShutdown;
                if job.shutdown == Shutdown::SkipOnShutdown {
                    state.awaited += 1;
                }
                // A block item below the foreground class is tracked, so shutdown can raise this worker.
                let raisable = (job.shutdown == Shutdown::BlockShutdown
                    && class != WorkerClass::Foreground)
                    .then(|| {
                        let closed = state.closed;
                        state.raises.track(boost::Target::current(), closed, &self.booster)
                    });
                drop(state);
                CURRENT_LANE.with(|current| *current.borrow_mut() = Some(Arc::clone(&self)));
                // Chrome's task_tracker.cc runs a task without WithBaseSyncPrimitives() under
                // ScopedDisallowBaseSyncPrimitives: an item may block on I/O, and a wait for other work
                // in it is a lane-sync site.
                let body = job.body;
                let panicked = crate::blocking::with_sync_primitives_disallowed(|| {
                    catch_unwind(AssertUnwindSafe(body)).is_err()
                });
                CURRENT_LANE.with(|current| current.borrow_mut().take());
                state = self.lock();
                if let Some(end) = raisable.and_then(|id| state.raises.untrack(id)) {
                    drop(state);
                    end(class.qos());
                    state = self.lock();
                }
                state.panics += u64::from(panicked);
                state.running -= 1;
                state.workers[index].idle += 1;
                if awaited {
                    state.awaited -= 1;
                    if state.awaited == 0 {
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
                // wakeup-allow: deadline the idle worker's one exit deadline (set at its first idle wait); work ends the wait first
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
    /// Raises the block items it keeps: queued ones (and admitted ones no BestEffort or Idle worker
    /// took yet) move to the UserBlocking list, highest priority first and in order within one, and
    /// each one running on a BestEffort or Idle worker gets that worker raised once.
    fn close(self: &Arc<Self>) -> Vec<Job> {
        let mut state = self.lock();
        state.closed = true;
        let mut dropped = Vec::new();
        let mut unadmitted = 0;
        // Items admitted to a BestEffort or Idle worker that has not taken them go back to the front
        // of their own priority's queue (they were admitted before the queued ones), so the merge
        // below keeps highest priority first.
        for class in [WorkerClass::BestEffort, WorkerClass::Idle] {
            let admitted = std::mem::take(&mut state.ready[class.index()]);
            unadmitted += admitted.len();
            for job in admitted.into_iter().rev() {
                state.pending[job.priority.index()].push_front(job);
            }
        }
        let foreground = WorkerClass::Foreground.index();
        let (keep, refused): (VecDeque<Job>, VecDeque<Job>) = state.ready[foreground]
            .drain(..)
            .partition(|job| job.shutdown == Shutdown::BlockShutdown);
        state.ready[foreground] = keep;
        unadmitted += refused.len();
        dropped.extend(refused);
        state.running -= unadmitted;
        let mut raised = VecDeque::new();
        for priority in Priority::ALL.into_iter().rev() {
            let (keep, drop): (VecDeque<Job>, VecDeque<Job>) = state.pending[priority.index()]
                .drain(..)
                .partition(|job| job.shutdown == Shutdown::BlockShutdown);
            raised.extend(keep);
            dropped.extend(drop);
        }
        for job in &mut raised {
            job.priority = Priority::UserBlocking;
        }
        state.pending[Priority::UserBlocking.index()] = raised;
        state.raises.raise_all(&self.booster);
        for signal in &self.ready_signal {
            signal.notify_all();
        }
        let starts = self.admit(&mut state);
        drop(state);
        self.start_workers(starts);
        dropped
    }

    /// Waits until no awaited item is left or `deadline` passes; returns how many are left.
    fn wait_drained(&self, deadline: Option<Instant>) -> usize {
        let mut state = self.lock();
        while state.awaited > 0 {
            match deadline {
                None => state = self.drained.wait(state).unwrap_or_else(PoisonError::into_inner),
                Some(deadline) => {
                    let Some(left) = deadline
                        .checked_duration_since(Instant::now())
                        .filter(|left| !left.is_zero())
                    else {
                        break;
                    };
                    // wakeup-allow: deadline the caller's one bound on the drain; the last job's end ends the wait first
                    state = self
                        .drained
                        .wait_timeout(state, left)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                }
            }
        }
        state.awaited
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
            blocked: state.blocked,
            workers: state.workers.iter().map(|class| class.live).sum(),
            idle_workers: state.workers.iter().map(|class| class.idle).sum(),
            posted: state.posted,
            workers_started: state.workers_started,
            workers_exited: state.workers_exited,
            wakeups: state.wakeups,
            spawn_failures: state.spawn_failures,
            panics: state.panics,
            shutdown_raises: state.raises.raised,
            shutdown_raise_refusals: state.raises.refused,
        }
    }
}

#[path = "work_boost.rs"]
mod boost;

#[path = "work_delayed.rs"]
mod delayed;

#[path = "work_launcher.rs"]
mod launcher;
use launcher::{Launch, Launcher, can_start_at};

#[cfg(test)]
#[path = "work_tests.rs"]
mod tests;
