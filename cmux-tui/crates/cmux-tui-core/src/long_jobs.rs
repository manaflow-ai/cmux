//! Long jobs: every slow job that blocks something is visible
//! (`plans/cmux-next/long-jobs-DESIGN.md`).
//!
//! A job that can take longer than about a second and that blocks, delays or
//! slows something a person can do registers here with [`LongJobs::start`].
//! The returned [`LongJobGuard`] reports progress (`done`/`total`, a
//! `detail`, or a heartbeat) and ends the job when it drops. Updates are
//! atomic stores; one publisher thread coalesces them:
//!
//! - the status file `long-jobs.json` in the owner's session directory
//!   ([`LongJobs::install_status_file`]), written with a temporary file and a
//!   rename at most once per second and removed when no job runs. `server
//!   ensure` reads it while the owner's socket still parks connections;
//! - the listeners ([`LongJobs::subscribe`]), at most four times per second:
//!   the socket's `jobs.changed` event.
//!
//! A job shows once it has run for [`VISIBLE_AFTER`]: the many quick runs of
//! a step that is only sometimes slow (a registry open, a maintenance tick)
//! never reach a listener or the file.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;

/// The status file's name, in the owner's session state directory.
pub const STATUS_FILE: &str = "long-jobs.json";
/// The status file's format version.
pub const STATUS_FILE_VERSION: u64 = 1;
/// A job younger than this is not published.
pub const VISIBLE_AFTER: Duration = Duration::from_secs(1);
/// Least time between two listener notifications (four per second).
const EVENT_INTERVAL: Duration = Duration::from_millis(250);
/// Least time between two status file writes.
const FILE_INTERVAL: Duration = Duration::from_secs(1);

/// What a running job blocks, delays or slows (the wire's `blocks` values).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Blocks {
    /// The owner does not accept clients yet.
    Startup,
    Terminals,
    Workspaces,
    History,
    /// Quitting now loses or repeats work.
    Quit,
    /// Background only, still shown.
    None,
}

/// One job as it goes on the wire, into the status file and to listeners.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LongJob {
    pub id: String,
    pub kind: &'static str,
    pub title: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub done: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit: Option<&'static str>,
    pub started_ms: u64,
    pub updated_ms: u64,
    pub blocks: Vec<Blocks>,
    pub cancellable: bool,
}

/// `done`/`total` not set.
const UNSET: u64 = u64::MAX;

struct JobState {
    id: String,
    kind: &'static str,
    title: &'static str,
    blocks: Vec<Blocks>,
    unit: Mutex<Option<&'static str>>,
    started: Instant,
    started_ms: u64,
    updated_ms: AtomicU64,
    done: AtomicU64,
    total: AtomicU64,
    detail: Mutex<Option<String>>,
}

impl JobState {
    fn touch(&self) {
        self.updated_ms.store(unix_ms().max(self.started_ms), Ordering::Release);
        // A job too young to show changes nothing published: the publisher
        // wakes for it at its visibility time.
        if self.started.elapsed() >= visible_after() {
            registry().mark_dirty();
        }
    }

    fn snapshot(&self) -> LongJob {
        let optional = |value: u64| (value != UNSET).then_some(value);
        LongJob {
            id: self.id.clone(),
            kind: self.kind,
            title: self.title,
            detail: self.detail.lock().unwrap_or_else(PoisonError::into_inner).clone(),
            done: optional(self.done.load(Ordering::Acquire)),
            total: optional(self.total.load(Ordering::Acquire)),
            unit: *self.unit.lock().unwrap_or_else(PoisonError::into_inner),
            started_ms: self.started_ms,
            updated_ms: self.updated_ms.load(Ordering::Acquire),
            blocks: self.blocks.clone(),
            cancellable: false,
        }
    }
}

/// A listener of the published job list.
pub type JobsListener = Arc<dyn Fn(&[LongJob]) + Send + Sync>;

#[derive(Default)]
struct Sinks {
    status_dir: Option<PathBuf>,
    listeners: Vec<(u64, JobsListener)>,
    next_listener: u64,
}

struct Registry {
    jobs: Mutex<Vec<Arc<JobState>>>,
    next_id: AtomicU64,
    /// A published value may have changed since the last publish.
    dirty: AtomicBool,
    /// The publisher waits for a change with nothing scheduled: only then
    /// does a change notify it. While a publish is deferred (rate limits)
    /// it sleeps until the due time and reads every change then.
    idle: AtomicBool,
    /// The earliest moment a young job becomes visible.
    wake_at: Mutex<Option<Instant>>,
    wake: Mutex<()>,
    changed: Condvar,
    sinks: Mutex<Sinks>,
    publisher: OnceLock<()>,
}

fn registry() -> &'static Registry {
    static REGISTRY: OnceLock<Registry> = OnceLock::new();
    REGISTRY.get_or_init(|| Registry {
        jobs: Mutex::new(Vec::new()),
        next_id: AtomicU64::new(1),
        dirty: AtomicBool::new(false),
        idle: AtomicBool::new(false),
        wake_at: Mutex::new(None),
        wake: Mutex::new(()),
        changed: Condvar::new(),
        sinks: Mutex::new(Sinks::default()),
        publisher: OnceLock::new(),
    })
}

impl Registry {
    /// Notes a change. A heartbeat is one atomic swap: the publisher is
    /// woken only for the first change after it went idle.
    fn mark_dirty(&self) {
        if !self.dirty.swap(true, Ordering::SeqCst) && self.idle.load(Ordering::SeqCst) {
            self.notify();
        }
        self.start_publisher();
    }

    /// Asks the publisher to look again at `at` (a young job's visibility).
    fn wake_at(&self, at: Instant) {
        {
            let mut wake_at = self.wake_at.lock().unwrap_or_else(PoisonError::into_inner);
            if wake_at.is_some_and(|earlier| earlier <= at) {
                return;
            }
            *wake_at = Some(at);
        }
        // An idle publisher waits without a timer: it has to take this one.
        if self.idle.load(Ordering::SeqCst) {
            self.notify();
        }
        self.start_publisher();
    }

    fn notify(&self) {
        // Taken so a publisher between its check and its wait gets the
        // notification.
        drop(self.wake.lock().unwrap_or_else(PoisonError::into_inner));
        self.changed.notify_one();
    }

    fn start_publisher(&self) {
        self.publisher.get_or_init(|| {
            if let Err(error) =
                std::thread::Builder::new().name("cmux-long-jobs".into()).spawn(publish_loop)
            {
                eprintln!("cmux-tui: long jobs: no publisher thread: {error}");
            }
        });
    }

    /// The visible jobs, oldest first, and when the next young job becomes
    /// visible.
    fn visible(&self, now: Instant) -> (Vec<LongJob>, Option<Instant>) {
        let after = visible_after();
        let jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut next = None::<Instant>;
        let mut visible = Vec::new();
        for job in jobs.iter() {
            let shows_at = job.started + after;
            if shows_at <= now {
                visible.push(job.snapshot());
            } else {
                next = Some(next.map_or(shows_at, |next| next.min(shows_at)));
            }
        }
        (visible, next)
    }
}

fn visible_after() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var("CMUX_TUI_TEST_LONG_JOBS_VISIBLE_AFTER_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return Duration::from_millis(ms);
    }
    VISIBLE_AFTER
}

/// Milliseconds since the Unix epoch.
pub fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
}

/// The process-wide long-jobs registry.
pub struct LongJobs;

impl LongJobs {
    /// Registers a job of `kind` (a stable dotted id; the app localizes by
    /// it) with its English `title`. The job ends when the guard drops.
    pub fn start(kind: &'static str, title: &'static str, blocks: &[Blocks]) -> LongJobGuard {
        let registry = registry();
        let started_ms = unix_ms();
        let sequence = registry.next_id.fetch_add(1, Ordering::Relaxed);
        let short = kind.rsplit('.').next().unwrap_or(kind);
        let state = Arc::new(JobState {
            id: format!("{short}:{}-{sequence}", started_ms / 1000),
            kind,
            title,
            blocks: blocks.to_vec(),
            unit: Mutex::new(None),
            started: Instant::now(),
            started_ms,
            updated_ms: AtomicU64::new(started_ms),
            done: AtomicU64::new(UNSET),
            total: AtomicU64::new(UNSET),
            detail: Mutex::new(None),
        });
        registry.jobs.lock().unwrap_or_else(PoisonError::into_inner).push(state.clone());
        // Published once it has run `visible_after`, not now: most jobs end
        // before that.
        registry.wake_at(state.started + visible_after());
        LongJobGuard { state }
    }

    /// The visible jobs now, oldest first (`jobs.list`).
    pub fn snapshot() -> Vec<LongJob> {
        registry().visible(Instant::now()).0
    }

    /// Calls `listener` with the visible jobs whenever they change, at most
    /// four times per second, from the publisher thread. The listener stays
    /// until the returned subscription drops.
    pub fn subscribe(listener: JobsListener) -> JobsSubscription {
        let registry = registry();
        let id = {
            let mut sinks = registry.sinks.lock().unwrap_or_else(PoisonError::into_inner);
            sinks.next_listener += 1;
            let id = sinks.next_listener;
            sinks.listeners.push((id, listener));
            id
        };
        registry.start_publisher();
        JobsSubscription { id }
    }

    /// Publishes the status file into `session_dir` from now on. A file an
    /// earlier owner left there is removed first: only the process that holds
    /// the session socket installs this.
    pub fn install_status_file(session_dir: &Path) {
        let registry = registry();
        let _ = std::fs::remove_file(session_dir.join(STATUS_FILE));
        registry.sinks.lock().unwrap_or_else(PoisonError::into_inner).status_dir =
            Some(session_dir.to_path_buf());
        registry.mark_dirty();
    }

    /// Stops the status file and removes it: the owner serves now, and
    /// clients read the jobs on the socket (`jobs-list`, `jobs-changed`).
    pub fn stop_status_file() {
        let registry = registry();
        registry.sinks.lock().unwrap_or_else(PoisonError::into_inner).status_dir = None;
        registry.mark_dirty();
    }
}

/// Keeps a [`LongJobs::subscribe`] listener registered.
pub struct JobsSubscription {
    id: u64,
}

impl Drop for JobsSubscription {
    fn drop(&mut self) {
        registry()
            .sinks
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .listeners
            .retain(|(id, _)| *id != self.id);
    }
}

/// A running job. Progress setters are cheap; dropping it ends the job.
pub struct LongJobGuard {
    state: Arc<JobState>,
}

impl LongJobGuard {
    /// The unit of `done` and `total` (`segments`, `tables`, `rows`).
    #[must_use]
    pub fn unit(self, unit: &'static str) -> Self {
        *self.state.unit.lock().unwrap_or_else(PoisonError::into_inner) = Some(unit);
        self
    }

    pub fn set_total(&self, total: u64) {
        self.state.total.store(total.min(UNSET - 1), Ordering::Release);
        self.state.touch();
    }

    pub fn set_done(&self, done: u64) {
        self.state.done.store(done.min(UNSET - 1), Ordering::Release);
        self.state.touch();
    }

    /// `done` plus `count` (from zero when unset).
    pub fn advance(&self, count: u64) {
        let _ = self.state.done.fetch_update(Ordering::AcqRel, Ordering::Acquire, |done| {
            Some(if done == UNSET { count } else { done.saturating_add(count).min(UNSET - 1) })
        });
        self.state.touch();
    }

    pub fn set_progress(&self, done: u64, total: u64) {
        self.state.total.store(total.min(UNSET - 1), Ordering::Release);
        self.set_done(done);
    }

    pub fn set_detail(&self, detail: impl Into<String>) {
        *self.state.detail.lock().unwrap_or_else(PoisonError::into_inner) = Some(detail.into());
        self.state.touch();
    }

    /// One step of a list of `total` named steps: `done` is the step's index.
    pub fn step(&self, index: u64, total: u64, name: &str) {
        *self.state.detail.lock().unwrap_or_else(PoisonError::into_inner) = Some(name.to_string());
        self.set_progress(index, total);
    }

    /// The job is alive and working (no countable progress).
    pub fn heartbeat(&self) {
        self.state.touch();
    }

    /// A heartbeat-only handle for code that cannot borrow the guard (a
    /// SQLite progress handler).
    pub fn heartbeat_handle(&self) -> JobHeartbeat {
        JobHeartbeat { state: self.state.clone() }
    }

    /// Beats this job from SQLite while a statement on `connection` runs
    /// (every `steps` virtual machine steps), so one long statement does not
    /// read as a stalled job. The handler is cleared when the returned scope
    /// drops; it replaces any handler the connection had. SQLite runs
    /// `PRAGMA integrity_check` and `quick_check` in one step, so they
    /// never beat: chunk them (one table per statement) and beat
    /// between the chunks.
    pub fn beat_during_sqlite<'c>(
        &self,
        connection: &'c rusqlite::Connection,
    ) -> SqliteHeartbeat<'c> {
        let beat = self.heartbeat_handle();
        let installed = connection
            .progress_handler(
                SQLITE_HEARTBEAT_STEPS,
                Some(move || {
                    beat.beat();
                    false
                }),
            )
            .is_ok();
        SqliteHeartbeat { connection, installed }
    }
}

/// SQLite virtual machine steps between two heartbeats of a statement.
pub const SQLITE_HEARTBEAT_STEPS: std::ffi::c_int = 100_000;

/// Clears the progress handler [`LongJobGuard::beat_during_sqlite`] set.
pub struct SqliteHeartbeat<'c> {
    connection: &'c rusqlite::Connection,
    installed: bool,
}

impl Drop for SqliteHeartbeat<'_> {
    fn drop(&mut self) {
        if self.installed {
            let _ = self.connection.progress_handler(0, None::<fn() -> bool>);
        }
    }
}

/// See [`LongJobGuard::heartbeat_handle`].
#[derive(Clone)]
pub struct JobHeartbeat {
    state: Arc<JobState>,
}

impl JobHeartbeat {
    pub fn beat(&self) {
        // At most one store per millisecond tick matters; the dirty flag is
        // set once per publish.
        self.state.touch();
    }
}

impl Drop for LongJobGuard {
    fn drop(&mut self) {
        let registry = registry();
        registry
            .jobs
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|job| !Arc::ptr_eq(job, &self.state));
        if self.state.started.elapsed() >= visible_after() {
            registry.mark_dirty();
        }
    }
}

#[derive(Default)]
struct Published {
    at: Option<Instant>,
    jobs: Option<Vec<LongJob>>,
}

impl Published {
    /// `Ok(true)` when `jobs` differs and the interval since the last publish
    /// passed; `Err(due)` when it differs but must wait until `due`.
    fn due(&self, jobs: &[LongJob], interval: Duration, now: Instant) -> Result<bool, Instant> {
        if self.jobs.as_deref() == Some(jobs) {
            return Ok(false);
        }
        match self.at {
            Some(at) if now < at + interval => Err(at + interval),
            _ => Ok(true),
        }
    }
}

fn publish_loop() {
    let registry = registry();
    let mut events = Published::default();
    let mut file = Published { at: None, jobs: Some(Vec::new()) };
    let mut file_dir: Option<PathBuf> = None;
    // A publish the rate limits put off: the publisher sleeps until then and
    // ignores changes, which that publish reads.
    let mut deferred: Option<Instant> = None;
    loop {
        {
            let mut wake = registry.wake.lock().unwrap_or_else(PoisonError::into_inner);
            loop {
                let now = Instant::now();
                if let Some(due) = deferred {
                    if now >= due {
                        break;
                    }
                    wake = registry
                        .changed
                        .wait_timeout(wake, due - now)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0;
                    continue;
                }
                registry.idle.store(true, Ordering::SeqCst);
                if registry.dirty.load(Ordering::SeqCst) {
                    break;
                }
                let wake_at = *registry.wake_at.lock().unwrap_or_else(PoisonError::into_inner);
                match wake_at {
                    Some(at) if now >= at => break,
                    Some(at) => {
                        wake = registry
                            .changed
                            .wait_timeout(wake, at - now)
                            .unwrap_or_else(PoisonError::into_inner)
                            .0;
                    }
                    None => {
                        wake = registry.changed.wait(wake).unwrap_or_else(PoisonError::into_inner);
                    }
                }
            }
            registry.idle.store(false, Ordering::SeqCst);
        }
        registry.dirty.store(false, Ordering::SeqCst);
        deferred = None;
        let now = Instant::now();
        {
            let mut wake_at = registry.wake_at.lock().unwrap_or_else(PoisonError::into_inner);
            if wake_at.is_some_and(|at| at <= now) {
                *wake_at = None;
            }
        }
        let (jobs, shows_next) = registry.visible(now);
        if let Some(at) = shows_next {
            let mut wake_at = registry.wake_at.lock().unwrap_or_else(PoisonError::into_inner);
            *wake_at = Some(wake_at.map_or(at, |earlier| earlier.min(at)));
        }
        let (listeners, status_dir) = {
            let sinks = registry.sinks.lock().unwrap_or_else(PoisonError::into_inner);
            (
                sinks.listeners.iter().map(|(_, listener)| listener.clone()).collect::<Vec<_>>(),
                sinks.status_dir.clone(),
            )
        };
        if status_dir != file_dir {
            // The file of a directory this process no longer publishes to
            // goes; a new one starts without a file.
            if let Some(old) = file_dir.as_deref() {
                let _ = write_status_file(old, &[]);
            }
            file = Published { at: None, jobs: Some(Vec::new()) };
            file_dir = status_dir;
        }
        let mut later = |due: Instant| {
            deferred = Some(deferred.map_or(due, |next| next.min(due)));
        };
        match events.due(&jobs, EVENT_INTERVAL, now) {
            Ok(true) => {
                for listener in &listeners {
                    listener(&jobs);
                }
                events = Published { at: Some(now), jobs: Some(jobs.clone()) };
            }
            Ok(false) => {}
            Err(due) => later(due),
        }
        if let Some(dir) = file_dir.as_deref() {
            match file.due(&jobs, FILE_INTERVAL, now) {
                Ok(true) => {
                    if let Err(error) = write_status_file(dir, &jobs) {
                        eprintln!("cmux-tui: long jobs: status file not written: {error}");
                    }
                    file = Published { at: Some(now), jobs: Some(jobs) };
                }
                Ok(false) => {}
                Err(due) => later(due),
            }
        }
    }
}

/// The session state directory of `session` under `state_root`, where the
/// owner writes its status file.
pub fn session_dir(state_root: &Path, session: &str) -> PathBuf {
    crate::PersistentSessionStateResetter::new(state_root).session_dir(session)
}

fn write_status_file(dir: &Path, jobs: &[LongJob]) -> std::io::Result<()> {
    if !dir.is_dir() {
        // A first start: the registry open creates the directory.
        return Ok(());
    }
    let path = dir.join(STATUS_FILE);
    if jobs.is_empty() {
        return match std::fs::remove_file(&path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        };
    }
    let body = serde_json::json!({
        "version": STATUS_FILE_VERSION,
        "pid": std::process::id(),
        "updated_ms": unix_ms(),
        "jobs": jobs,
    });
    let temporary = dir.join(format!("{STATUS_FILE}.{}.tmp", std::process::id()));
    std::fs::write(&temporary, serde_json::to_vec(&body).map_err(std::io::Error::other)?)?;
    std::fs::rename(&temporary, &path).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

/// The status file as a reader (`server ensure`) sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct JobsStatus {
    pub pid: u64,
    pub updated_ms: u64,
    pub jobs: Vec<Value>,
}

impl JobsStatus {
    /// Reads `long-jobs.json` in `session_dir`; `None` when it is missing,
    /// unreadable or of another version.
    pub fn read(session_dir: &Path) -> Option<Self> {
        let bytes = std::fs::read(session_dir.join(STATUS_FILE)).ok()?;
        let value: Value = serde_json::from_slice(&bytes).ok()?;
        if value.get("version").and_then(Value::as_u64) != Some(STATUS_FILE_VERSION) {
            return None;
        }
        Some(Self {
            pid: value.get("pid").and_then(Value::as_u64)?,
            updated_ms: value.get("updated_ms").and_then(Value::as_u64).unwrap_or(0),
            jobs: value.get("jobs").and_then(Value::as_array).cloned().unwrap_or_default(),
        })
    }

    /// Whether the process that wrote the file still runs. Off Unix there
    /// is no cheap check: the writer removes the file when it serves, and
    /// the next owner removes a stale one.
    pub fn writer_alive(&self) -> bool {
        #[cfg(unix)]
        {
            let Ok(pid) = libc::pid_t::try_from(self.pid) else { return false };
            if pid <= 0 {
                return false;
            }
            // SAFETY: signal 0 only checks that the process exists.
            let result = unsafe { libc::kill(pid, 0) };
            result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
        }
        #[cfg(not(unix))]
        true
    }

    /// The jobs that block `startup`.
    pub fn startup_jobs(&self) -> impl Iterator<Item = &Value> {
        self.jobs.iter().filter(|job| {
            job.get("blocks")
                .and_then(Value::as_array)
                .is_some_and(|blocks| blocks.iter().any(|block| block == "startup"))
        })
    }

    /// Changes whenever a startup job starts, ends or reports progress.
    pub fn startup_progress_mark(&self) -> Vec<(String, u64)> {
        self.startup_jobs()
            .map(|job| {
                (
                    job.get("id").and_then(Value::as_str).unwrap_or_default().to_string(),
                    job.get("updated_ms").and_then(Value::as_u64).unwrap_or(0),
                )
            })
            .collect()
    }
}
