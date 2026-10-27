//! Supervised threads and tasks: a worker that fails never leaves a live
//! process serving nothing.
//!
//! Chromium's model, adapted to cmux's daemons:
//! - A browser-process thread that crashes takes the process down
//!   (`base/threading/platform_thread.h` has no restart; `content/browser/
//!   browser_main_loop.cc` treats a dead UI/IO thread as fatal), and a service
//!   process that dies is relaunched by its host with backoff
//!   (`content/browser/gpu/gpu_data_manager_impl_private.cc`,
//!   `FallBackToNextGpuMode`). Here [`Fatal`] is the default: the worker's
//!   failure is recorded and the process exits cleanly with
//!   [`SUPERVISED_FATAL_EXIT_CODE`], so the process supervisor restarts it and
//!   the journal restores state.
//! - [`Restart`] is only for workers whose state is private: each run builds
//!   its state again. Restarts back off exponentially (`net/base/backoff_entry.h`)
//!   from 100 ms to 30 s, at most 5 per minute; past that budget the worker
//!   gives up and the failure is fatal. A failure that leaves a declared shared
//!   lock poisoned is fatal at once: the shared state may be half-mutated.
//! - Every call names a [`ShutdownBehavior`], Chromium's `TaskShutdownBehavior`
//!   (`base/task/task_traits.h`).
//!
//! The [`Supervisor`] is built once by the process's composition root with a
//! [`FailureSink`] ([`ExitProcess`] in production) and passed to the code that
//! starts workers. It keeps a handle to every live worker for
//! [`Supervisor::shutdown`].

use std::any::Any;
use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock, PoisonError, RwLock};
use std::thread::Thread;
use std::time::{Duration, Instant};

use crate::Fields;

/// Exit status of a process ended by a fatal supervised failure (`EX_SOFTWARE`).
pub const SUPERVISED_FATAL_EXIT_CODE: i32 = 70;

/// The default failure policy: a failure is recorded and ends the process.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Fatal;

/// Restart the worker after a failure, for workers whose state is private.
///
/// Built only through [`Restart::state_private`], so every call site
/// declares that a run rebuilds everything it owns.
#[derive(Clone)]
pub struct Restart {
    initial_backoff: Duration,
    max_backoff: Duration,
    max_restarts: usize,
    window: Duration,
    shared: Vec<Arc<dyn PoisonProbe>>,
}

impl Restart {
    /// Backoff 100 ms doubling to 30 s, at most 5 restarts per minute.
    pub fn state_private() -> Self {
        Self {
            initial_backoff: Duration::from_millis(100),
            max_backoff: Duration::from_secs(30),
            max_restarts: 5,
            window: Duration::from_secs(60),
            shared: Vec::new(),
        }
    }

    /// The first restart waits `initial`; each next one doubles, up to `max`.
    #[must_use]
    pub fn backoff(mut self, initial: Duration, max: Duration) -> Self {
        self.initial_backoff = initial;
        self.max_backoff = max.max(initial);
        self
    }

    /// At most `restarts` restarts in any `window`; one more failure is fatal.
    #[must_use]
    pub fn budget(mut self, restarts: usize, window: Duration) -> Self {
        self.max_restarts = restarts;
        self.window = window;
        self
    }

    /// A shared lock the worker touches: a failure that leaves it poisoned is
    /// fatal instead of restarted.
    #[must_use]
    pub fn shares<P: PoisonProbe + 'static>(mut self, lock: Arc<P>) -> Self {
        self.shared.push(lock);
        self
    }
}

impl fmt::Debug for Restart {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Restart")
            .field("initial_backoff", &self.initial_backoff)
            .field("max_backoff", &self.max_backoff)
            .field("max_restarts", &self.max_restarts)
            .field("window", &self.window)
            .field("shared_locks", &self.shared.len())
            .finish()
    }
}

/// A lock whose poison flag the supervisor reads after a failure.
pub trait PoisonProbe: Send + Sync {
    fn is_poisoned(&self) -> bool;
}

impl<T: ?Sized + Send> PoisonProbe for Mutex<T> {
    fn is_poisoned(&self) -> bool {
        Mutex::is_poisoned(self)
    }
}

impl<T: ?Sized + Send + Sync> PoisonProbe for RwLock<T> {
    fn is_poisoned(&self) -> bool {
        RwLock::is_poisoned(self)
    }
}

/// What [`Supervisor::shutdown`] does with a worker (`base::TaskShutdownBehavior`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShutdownBehavior {
    /// CONTINUE_ON_SHUTDOWN: shutdown neither stops nor waits for it; it runs
    /// (and restarts) until the process exits.
    Continue,
    /// SKIP_ON_SHUTDOWN: no run starts after shutdown begins. A thread is asked
    /// to stop; a task is aborted at its next await. Shutdown does not wait.
    Skip,
    /// BLOCK_SHUTDOWN: shutdown asks it to stop and waits up to `deadline` for
    /// it to return (a journal flush). A worker past it is named in
    /// [`ShutdownReport::late`].
    Block { deadline: Duration },
}

/// Why a run ended badly.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    /// The body panicked; the panic hook already logged it.
    Panicked { message: String },
    /// The body returned an error.
    Errored { error: String },
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Panicked { message } => write!(f, "panicked: {message}"),
            Self::Errored { error } => write!(f, "returned an error: {error}"),
        }
    }
}

/// Why a failure ends the process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FatalReason {
    /// The worker's policy is [`Fatal`].
    Failed(Failure),
    /// [`Restart`] used its whole budget and the worker failed again.
    GaveUp { restarts: usize, window: Duration, last: Failure },
    /// The failure left a shared lock declared with [`Restart::shares`] poisoned.
    Poisoned(Failure),
}

/// One fatal supervised failure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FatalReport {
    pub worker: String,
    pub reason: FatalReason,
}

impl fmt::Display for FatalReport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let worker = &self.worker;
        match &self.reason {
            FatalReason::Failed(failure) => write!(f, "supervised worker {worker} {failure}"),
            FatalReason::GaveUp { restarts, window, last } => write!(
                f,
                "supervised worker {worker} gave up after {restarts} restarts in {window:?}; last {last}"
            ),
            FatalReason::Poisoned(failure) => {
                write!(f, "supervised worker {worker} {failure} with a shared lock poisoned")
            }
        }
    }
}

/// Where supervised failures go. [`ExitProcess`] in production; tests record.
pub trait FailureSink: Send + Sync + 'static {
    /// A [`Restart`] worker failed and runs again after `backoff`.
    fn restarting(&self, worker: &str, failure: &Failure, backoff: Duration) {
        eprintln!("cmux supervisor: {worker} {failure}; restarting in {backoff:?}");
    }

    /// The failure is fatal. Production ends the process here; if this
    /// returns, the worker ends and is not restarted.
    fn fatal(&self, report: &FatalReport);
}

/// Production sink: append one line to the panic log, flush stdio, then end
/// the process with [`SUPERVISED_FATAL_EXIT_CODE`] so the process supervisor
/// restarts it.
pub struct ExitProcess {
    log: Option<PathBuf>,
    fields: Fields,
    exit: fn(i32),
}

impl ExitProcess {
    /// `log` is the [`crate::install`] path; `fields` the same process fields.
    /// `exit` ends the process: the binary owns its lifetime, so its
    /// composition root passes `|code| std::process::exit(code)`.
    pub fn new(log: Option<PathBuf>, fields: Fields, exit: fn(i32)) -> Self {
        Self { log, fields, exit }
    }

    /// The panic-log line for `report`: `kind` is `"supervised_exit"`.
    pub fn record(&self, report: &FatalReport) -> serde_json::Value {
        let thread = std::thread::current().name().unwrap_or("unnamed").to_string();
        let mut line =
            crate::record(&self.fields, &report.to_string(), "", &thread, false, String::new());
        if let serde_json::Value::Object(map) = &mut line {
            map.insert("kind".into(), "supervised_exit".into());
            map.insert("worker".into(), report.worker.clone().into());
            let keys = crate::crash_keys::snapshot();
            if !keys.is_empty() {
                map.insert("crash_keys".into(), keys.to_json());
            }
        }
        line
    }
}

impl FailureSink for ExitProcess {
    fn fatal(&self, report: &FatalReport) {
        use std::io::Write;
        if let Some(log) = &self.log {
            crate::append(log, &self.record(report));
        }
        eprintln!("cmux supervisor: {report}; exiting");
        let _ = std::io::stdout().flush();
        let _ = std::io::stderr().flush();
        (self.exit)(SUPERVISED_FATAL_EXIT_CODE);
    }
}

/// What a body returns: `()` or `Result<(), E>`; an `Err` is a [`Failure`].
pub trait WorkerOutcome {
    fn into_failure(self) -> Option<Failure>;
}

impl WorkerOutcome for () {
    fn into_failure(self) -> Option<Failure> {
        None
    }
}

impl<E: fmt::Display> WorkerOutcome for Result<(), E> {
    fn into_failure(self) -> Option<Failure> {
        self.err().map(|error| Failure::Errored { error: error.to_string() })
    }
}

/// Why a worker did not start.
#[derive(Debug)]
pub enum SuperviseError {
    /// [`Supervisor::shutdown`] already began.
    ShuttingDown,
    /// The OS refused the thread.
    Spawn(std::io::Error),
    /// `supervise_task` ran outside a tokio runtime.
    NoRuntime,
}

impl fmt::Display for SuperviseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ShuttingDown => f.write_str("the supervisor is shutting down"),
            Self::Spawn(error) => write!(f, "thread did not start: {error}"),
            Self::NoRuntime => f.write_str("no tokio runtime on this thread"),
        }
    }
}

impl std::error::Error for SuperviseError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Spawn(error) => Some(error),
            Self::ShuttingDown | Self::NoRuntime => None,
        }
    }
}

/// Workers that missed their [`ShutdownBehavior::Block`] deadline.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ShutdownReport {
    pub late: Vec<String>,
}

/// Owns the live workers of one process. Cheap to clone.
#[derive(Clone)]
pub struct Supervisor {
    inner: Arc<Inner>,
}

struct Inner {
    sink: Arc<dyn FailureSink>,
    stopping: AtomicBool,
    next_id: AtomicU64,
    // Held only to insert, remove or drain an entry; never across a wait.
    workers: Mutex<HashMap<u64, Entry>>,
}

struct Entry {
    name: String,
    shutdown: ShutdownBehavior,
    stop: Arc<StopState>,
    // Taken by shutdown to wait for a Block worker.
    done: Option<mpsc::Receiver<()>>,
}

impl Supervisor {
    pub fn new(sink: Arc<dyn FailureSink>) -> Self {
        Self {
            inner: Arc::new(Inner {
                sink,
                stopping: AtomicBool::new(false),
                next_id: AtomicU64::new(0),
                workers: Mutex::new(HashMap::new()),
            }),
        }
    }

    /// Run `body` once on a new thread named `name`. A panic or an `Err` is
    /// fatal unless a stop was asked.
    pub fn supervise_thread<F, O>(
        &self,
        name: impl Into<String>,
        _policy: Fatal,
        shutdown: ShutdownBehavior,
        body: F,
    ) -> Result<WorkerHandle, SuperviseError>
    where
        F: FnOnce(&StopToken) -> O + Send + 'static,
        O: WorkerOutcome,
    {
        let mut body = Some(body);
        self.spawn_thread(name.into(), None, shutdown, move |stop| match body.take() {
            Some(body) => run_caught(|| body(stop)),
            None => None,
        })
    }

    /// Run `body` on a new thread named `name`, again after each failure under
    /// `policy`. Each call of `body` builds the worker's state from scratch.
    pub fn supervise_thread_restarting<F, O>(
        &self,
        name: impl Into<String>,
        policy: Restart,
        shutdown: ShutdownBehavior,
        mut body: F,
    ) -> Result<WorkerHandle, SuperviseError>
    where
        F: FnMut(&StopToken) -> O + Send + 'static,
        O: WorkerOutcome,
    {
        self.spawn_thread(name.into(), Some(policy), shutdown, move |stop| {
            run_caught(|| body(stop))
        })
    }

    /// Stop every worker: none restarts; [`ShutdownBehavior::Block`] workers are
    /// waited for up to their deadlines. Blocks the calling thread; call it from
    /// the process's main thread, not a runtime worker.
    pub fn shutdown(&self) -> ShutdownReport {
        let started = Instant::now();
        self.inner.stopping.store(true, Ordering::SeqCst);
        let mut blocking = Vec::new();
        for entry in self.lock_workers().values_mut() {
            if entry.shutdown != ShutdownBehavior::Continue {
                entry.stop.wake();
            }
            if let (ShutdownBehavior::Block { deadline }, Some(done)) =
                (entry.shutdown, entry.done.take())
            {
                blocking.push((entry.name.clone(), deadline, done));
            }
        }
        let mut report = ShutdownReport::default();
        for (name, deadline, done) in blocking {
            let remaining = deadline.saturating_sub(started.elapsed());
            // wakeup-allow: deadline the one Block deadline of shutdown; it wakes on the worker's done channel.
            if let Err(mpsc::RecvTimeoutError::Timeout) = done.recv_timeout(remaining) {
                report.late.push(name);
            }
        }
        report
    }

    /// Names of the workers still running, after shutdown too.
    pub fn live_workers(&self) -> Vec<String> {
        let mut names: Vec<String> =
            self.lock_workers().values().map(|entry| entry.name.clone()).collect();
        names.sort();
        names
    }

    fn lock_workers(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Entry>> {
        // No critical section can panic part-way, so a poisoned map is intact.
        self.inner.workers.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn register(
        &self,
        name: &str,
        shutdown: ShutdownBehavior,
    ) -> Result<(Arc<StopState>, DoneGuard), SuperviseError> {
        let stop = Arc::new(StopState {
            requested: AtomicBool::new(false),
            thread: OnceLock::new(),
            #[cfg(feature = "tokio")]
            cancel: tokio_util::sync::CancellationToken::new(),
        });
        let (done_tx, done) = mpsc::channel();
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        {
            let mut workers = self.lock_workers();
            // Checked under the map's lock: shutdown sets the flag before it
            // drains, so an entry inserted here is always drained or refused.
            if self.inner.stopping.load(Ordering::SeqCst) {
                return Err(SuperviseError::ShuttingDown);
            }
            workers.insert(
                id,
                Entry {
                    name: name.to_string(),
                    shutdown,
                    stop: Arc::clone(&stop),
                    done: Some(done),
                },
            );
        }
        let guard = DoneGuard { supervisor: Arc::downgrade(&self.inner), id, _done: done_tx };
        Ok((stop, guard))
    }

    fn spawn_thread(
        &self,
        name: String,
        restart: Option<Restart>,
        shutdown: ShutdownBehavior,
        mut run_once: impl FnMut(&StopToken) -> Option<Failure> + Send + 'static,
    ) -> Result<WorkerHandle, SuperviseError> {
        let (stop, guard) = self.register(&name, shutdown)?;
        let sink = Arc::clone(&self.inner.sink);
        let token = StopToken { state: Arc::clone(&stop) };
        let worker = name.clone();
        // supervise-allow: the supervisor's own thread; its registry entry (done channel) is the handle.
        let spawned = std::thread::Builder::new().name(name.clone()).spawn(move || {
            let _guard = guard;
            let _ = token.state.thread.set(std::thread::current());
            let mut budget = restart.map(Budget::new);
            loop {
                let run_started = Instant::now();
                let Some(failure) = run_once(&token) else { return };
                match decide(&worker, budget.as_mut(), failure, token.is_stopped(), run_started) {
                    Decision::End => return,
                    Decision::Fatal(report) => return sink.fatal(&report),
                    Decision::Restart(backoff, failure) => {
                        sink.restarting(&worker, &failure, backoff);
                        // wakeup-allow: backoff the restart backoff after a failure; a stop request unparks it.
                        if token.wait_timeout(backoff) {
                            return;
                        }
                    }
                }
            }
        });
        // On a spawn error the dropped closure's DoneGuard removes the entry.
        match spawned {
            Ok(_detached) => Ok(WorkerHandle { name, stop }),
            Err(error) => Err(SuperviseError::Spawn(error)),
        }
    }
}

#[cfg(feature = "tokio")]
impl Supervisor {
    /// Run the future `body` makes once on the current tokio runtime. A panic
    /// in `body` or its future, or an `Err`, is fatal unless a stop was asked.
    pub fn supervise_task<F, Fut>(
        &self,
        name: impl Into<String>,
        _policy: Fatal,
        shutdown: ShutdownBehavior,
        body: F,
    ) -> Result<WorkerHandle, SuperviseError>
    where
        F: FnOnce(StopToken) -> Fut + Send + 'static,
        Fut: Future + Send + 'static,
        Fut::Output: WorkerOutcome + Send + 'static,
    {
        let mut body = Some(body);
        self.spawn_task(name.into(), None, shutdown, move |stop| body.take().map(|body| body(stop)))
    }

    /// Run the future `body` makes on the current tokio runtime, and a new
    /// one after each failure under `policy`.
    pub fn supervise_task_restarting<F, Fut>(
        &self,
        name: impl Into<String>,
        policy: Restart,
        shutdown: ShutdownBehavior,
        mut body: F,
    ) -> Result<WorkerHandle, SuperviseError>
    where
        F: FnMut(StopToken) -> Fut + Send + 'static,
        Fut: Future + Send + 'static,
        Fut::Output: WorkerOutcome + Send + 'static,
    {
        self.spawn_task(name.into(), Some(policy), shutdown, move |stop| Some(body(stop)))
    }

    fn spawn_task<Fut>(
        &self,
        name: String,
        restart: Option<Restart>,
        shutdown: ShutdownBehavior,
        mut make: impl FnMut(StopToken) -> Option<Fut> + Send + 'static,
    ) -> Result<WorkerHandle, SuperviseError>
    where
        Fut: Future + Send + 'static,
        Fut::Output: WorkerOutcome + Send + 'static,
    {
        let runtime =
            tokio::runtime::Handle::try_current().map_err(|_| SuperviseError::NoRuntime)?;
        let (stop, guard) = self.register(&name, shutdown)?;
        let sink = Arc::clone(&self.inner.sink);
        let token = StopToken { state: Arc::clone(&stop) };
        let worker = name.clone();
        let inner_runtime = runtime.clone();
        // supervise-allow: the supervisor's own monitor; its registry entry (done channel) is the handle.
        let _monitor = runtime.spawn(async move {
            let _guard = guard;
            let mut budget = restart.map(Budget::new);
            loop {
                let run_started = Instant::now();
                // The body's code before its future is part of the run: a
                // panic there is a failure like one inside the future.
                let failure = match catch_unwind(AssertUnwindSafe(|| make(token.clone()))) {
                    Ok(None) => return,
                    Err(payload) => Some(Failure::Panicked { message: payload_text(&*payload) }),
                    Ok(Some(fut)) => {
                        let mut run = inner_runtime.spawn(fut);
                        let joined = if shutdown == ShutdownBehavior::Skip {
                            tokio::select! {
                                joined = &mut run => joined,
                                () = token.cancelled() => {
                                    run.abort();
                                    let _ = run.await;
                                    return;
                                }
                            }
                        } else {
                            run.await
                        };
                        match joined {
                            Ok(outcome) => outcome.into_failure(),
                            Err(error) if error.is_panic() => Some(Failure::Panicked {
                                message: payload_text(&*error.into_panic()),
                            }),
                            // Cancelled: the runtime is shutting down.
                            Err(_) => return,
                        }
                    }
                };
                let Some(failure) = failure else { return };
                match decide(&worker, budget.as_mut(), failure, token.is_stopped(), run_started) {
                    Decision::End => return,
                    Decision::Fatal(report) => return sink.fatal(&report),
                    Decision::Restart(backoff, failure) => {
                        sink.restarting(&worker, &failure, backoff);
                        tokio::select! {
                            // wakeup-allow: backoff the restart backoff after a failure; a stop request cancels it.
                            () = tokio::time::sleep(backoff) => {}
                            () = token.cancelled() => return,
                        }
                    }
                }
            }
        });
        Ok(WorkerHandle { name, stop })
    }
}

/// A live worker. Dropping it leaves the worker running under the supervisor.
pub struct WorkerHandle {
    name: String,
    stop: Arc<StopState>,
}

impl WorkerHandle {
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Ask this worker to stop; it is not restarted after its run ends.
    pub fn stop(&self) {
        self.stop.wake();
    }
}

/// The body's view of stop requests (its own handle's or shutdown's).
#[derive(Clone)]
pub struct StopToken {
    state: Arc<StopState>,
}

impl StopToken {
    pub fn is_stopped(&self) -> bool {
        self.state.is_stopped()
    }

    /// Wait up to `timeout`; `true` once a stop is requested. Only on the
    /// supervised thread itself (it parks that thread); a task awaits
    /// [`StopToken::cancelled`] instead.
    pub fn wait_timeout(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if self.is_stopped() {
                return true;
            }
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            std::thread::park_timeout(deadline - now);
        }
    }

    /// Resolves once a stop is requested.
    #[cfg(feature = "tokio")]
    pub async fn cancelled(&self) {
        if self.is_stopped() {
            return;
        }
        self.state.cancel.cancelled().await;
    }
}

struct StopState {
    requested: AtomicBool,
    thread: OnceLock<Thread>,
    #[cfg(feature = "tokio")]
    cancel: tokio_util::sync::CancellationToken,
}

impl StopState {
    fn is_stopped(&self) -> bool {
        self.requested.load(Ordering::SeqCst)
    }

    fn wake(&self) {
        self.requested.store(true, Ordering::SeqCst);
        #[cfg(feature = "tokio")]
        self.cancel.cancel();
        if let Some(thread) = self.thread.get() {
            thread.unpark();
        }
    }
}

/// Dropped when the worker ends: removes its entry and closes its done channel.
struct DoneGuard {
    supervisor: std::sync::Weak<Inner>,
    id: u64,
    _done: mpsc::Sender<()>,
}

impl Drop for DoneGuard {
    fn drop(&mut self) {
        if let Some(inner) = self.supervisor.upgrade() {
            let removed =
                inner.workers.lock().unwrap_or_else(PoisonError::into_inner).remove(&self.id);
            drop(removed);
        }
    }
}

struct Budget {
    policy: Restart,
    restarts: VecDeque<Instant>,
    next_backoff: Duration,
}

impl Budget {
    fn new(policy: Restart) -> Self {
        let next_backoff = policy.initial_backoff;
        Self { policy, restarts: VecDeque::new(), next_backoff }
    }

    /// The wait before the next run, or `None` once the budget is spent.
    fn next(&mut self, now: Instant, ran_for: Duration) -> Option<Duration> {
        while self.restarts.front().is_some_and(|at| now.duration_since(*at) >= self.policy.window)
        {
            self.restarts.pop_front();
        }
        if self.restarts.len() >= self.policy.max_restarts {
            return None;
        }
        if ran_for >= self.policy.window {
            self.next_backoff = self.policy.initial_backoff;
        }
        let backoff = self.next_backoff;
        self.next_backoff = (backoff * 2).min(self.policy.max_backoff);
        self.restarts.push_back(now);
        Some(backoff)
    }

    fn poisoned(&self) -> bool {
        self.policy.shared.iter().any(|lock| lock.is_poisoned())
    }
}

enum Decision {
    End,
    Fatal(FatalReport),
    Restart(Duration, Failure),
}

fn decide(
    worker: &str,
    budget: Option<&mut Budget>,
    failure: Failure,
    stopping: bool,
    run_started: Instant,
) -> Decision {
    let fatal = |reason| Decision::Fatal(FatalReport { worker: worker.to_string(), reason });
    if budget.as_deref().is_some_and(Budget::poisoned) {
        return fatal(FatalReason::Poisoned(failure));
    }
    // A worker asked to stop ends however its last run went, under either policy.
    if stopping {
        return Decision::End;
    }
    let Some(budget) = budget else { return fatal(FatalReason::Failed(failure)) };
    match budget.next(Instant::now(), run_started.elapsed()) {
        Some(backoff) => Decision::Restart(backoff, failure),
        None => fatal(FatalReason::GaveUp {
            restarts: budget.policy.max_restarts,
            window: budget.policy.window,
            last: failure,
        }),
    }
}

/// Run one body call, turning a panic into a [`Failure`].
///
/// `AssertUnwindSafe`: a [`Fatal`] body is never run again, and a [`Restart`]
/// body rebuilds its private state each run while shared locks are probed.
fn run_caught<O: WorkerOutcome>(body: impl FnOnce() -> O) -> Option<Failure> {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(outcome) => outcome.into_failure(),
        Err(payload) => Some(Failure::Panicked { message: payload_text(&*payload) }),
    }
}

pub(crate) fn payload_text(payload: &(dyn Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|text| (*text).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "non-text panic payload".to_string())
}

#[cfg(test)]
#[path = "supervise_tests.rs"]
mod tests;
