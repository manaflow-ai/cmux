//! The sources, their baselines and what one scan reports ([`Core`], no
//! thread, testable on its own), and the one background thread that watches
//! every source and scans it on schedule ([`CookieSync`]).

use crate::baseline;
use crate::diff::diff;
use crate::fingerprint::{Fingerprint, Scan, ScanError, fingerprint, sidecar};
use crate::schedule::Scheduler;
use notify::event::{EventKind, MetadataKind, ModifyKind};
use notify::{RecursiveMode, Watcher};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// A copy that changed under the read can look malformed; it is read again
/// this many times in a row before the source is reported `failed`.
const READ_ATTEMPTS: u32 = 3;

/// One browser profile's cookie store.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Source {
    /// The app's name for it, e.g. `chrome:Default`.
    pub id: String,
    /// Its `Cookies` database file, as the app's detector found it.
    pub database: PathBuf,
}

/// What the app starts the sync with.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Config {
    /// Where the baselines are kept (the app's own state directory).
    pub state_dir: PathBuf,
    /// Quiet time after a file event before a scan.
    #[serde(default = "default_debounce_ms")]
    pub debounce_ms: u64,
    /// Least time between two scans of one source.
    #[serde(default = "default_min_interval_ms")]
    pub min_interval_ms: u64,
    pub sources: Vec<Source>,
}

fn default_debounce_ms() -> u64 {
    2000
}

fn default_min_interval_ms() -> u64 {
    30_000
}

impl Config {
    /// The config in `bytes` (JSON); none unless the state directory and
    /// every database are absolute paths and every id is non-empty and unique.
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let config: Self = serde_json::from_slice(bytes).ok()?;
        let mut ids = BTreeSet::new();
        let valid = config.state_dir.is_absolute()
            && config.sources.iter().all(|source| {
                !source.id.is_empty()
                    && ids.insert(source.id.as_str())
                    && source.database.is_absolute()
                    && source.database.file_name().is_some()
            });
        drop(ids);
        valid.then_some(config)
    }
}

/// Why a source was scanned.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    /// The check at start: did the store change while the app was closed.
    Launch,
    /// A file event.
    Watch,
    /// The first scan of a source with no saved baseline: it becomes the baseline.
    Baseline,
}

/// What one scan tells the app (the callback's JSON).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Report {
    /// These domains differ from the baseline: re-import them, then commit.
    Changed {
        source: String,
        changed: Vec<String>,
        removed: Vec<String>,
        rows: u64,
        hosts: u64,
        scan_ms: f64,
        cpu_ms: Option<f64>,
        reason: Reason,
    },
    /// Read, and nothing differs from the baseline (cost numbers only).
    Scanned {
        source: String,
        rows: u64,
        hosts: u64,
        scan_ms: f64,
        cpu_ms: Option<f64>,
        reason: Reason,
    },
    /// The database is gone; the source is no longer watched.
    Gone { source: String },
    /// The database cannot be read as a cookie store (or its baseline not
    /// saved); the source is no longer watched. `reason` is short and holds
    /// no path or value.
    Failed { source: String, reason: String },
}

/// What one scan cost.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cost {
    /// Wall time to copy, read and hash.
    pub scan_ms: f64,
    /// The scanning thread's CPU time, where the platform has it.
    pub cpu_ms: Option<f64>,
}

/// Reads `database`, again when the copy looked malformed, and what it cost.
pub fn measure(database: &Path) -> (Result<Scan, ScanError>, Cost) {
    let cpu = thread_cpu();
    let wall = Instant::now();
    let mut outcome = fingerprint(database);
    for _ in 1..READ_ATTEMPTS {
        if !matches!(outcome, Err(ScanError::Unreadable(_))) {
            break;
        }
        outcome = fingerprint(database);
    }
    let cpu_ms = cpu.zip(thread_cpu()).map(|(start, end)| millis(end.saturating_sub(start)));
    (outcome, Cost { scan_ms: millis(wall.elapsed()), cpu_ms })
}

fn millis(duration: Duration) -> f64 {
    (duration.as_secs_f64() * 1_000_000.0).round() / 1000.0
}

/// This thread's CPU time.
#[cfg(unix)]
fn thread_cpu() -> Option<Duration> {
    // SAFETY: an all-zero timespec is a valid value.
    let mut time: libc::timespec = unsafe { std::mem::zeroed() };
    // SAFETY: `time` is a valid, writable timespec.
    if unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &raw mut time) } != 0 {
        return None;
    }
    Some(Duration::new(u64::try_from(time.tv_sec).ok()?, u32::try_from(time.tv_nsec).ok()?))
}

#[cfg(not(unix))]
fn thread_cpu() -> Option<Duration> {
    None
}

#[derive(Debug)]
struct State {
    source: Source,
    baseline: Option<Fingerprint>,
    /// The last reported fingerprint that differs from the baseline, saved
    /// as the baseline by `commit`.
    pending: Option<Fingerprint>,
    active: bool,
}

/// Every source's baseline and what a scan of it reports.
#[derive(Debug)]
pub struct Core {
    state_dir: PathBuf,
    states: Vec<State>,
}

impl Core {
    /// The sources of `config`, each with its saved baseline.
    pub fn new(config: &Config) -> Self {
        let states = config
            .sources
            .iter()
            .map(|source| State {
                baseline: baseline::load(&config.state_dir, &source.id),
                source: source.clone(),
                pending: None,
                active: true,
            })
            .collect();
        Self { state_dir: config.state_dir.clone(), states }
    }

    pub fn len(&self) -> usize {
        self.states.len()
    }

    pub fn is_empty(&self) -> bool {
        self.states.is_empty()
    }

    /// The database of source `index` while it is watched.
    pub fn database(&self, index: usize) -> Option<&Path> {
        self.states
            .get(index)
            .filter(|state| state.active)
            .map(|state| state.source.database.as_path())
    }

    /// Reads source `index` and reports it (none once it stopped).
    pub fn check(&mut self, index: usize, reason: Reason) -> Option<Report> {
        let database = self.database(index)?.to_path_buf();
        let (outcome, cost) = measure(&database);
        self.apply(index, outcome, cost, reason)
    }

    /// What a read of source `index` reports, and its new state: a store with
    /// no baseline takes this read as its baseline (saved), a difference from
    /// the baseline is pending until `commit`, a missing or unreadable store
    /// stops the source.
    pub fn apply(
        &mut self,
        index: usize,
        outcome: Result<Scan, ScanError>,
        cost: Cost,
        reason: Reason,
    ) -> Option<Report> {
        let state_dir = self.state_dir.clone();
        let state = self.states.get_mut(index).filter(|state| state.active)?;
        let source = state.source.id.clone();
        let scan = match outcome {
            Ok(scan) => scan,
            Err(ScanError::Missing) => {
                state.active = false;
                return Some(Report::Gone { source });
            }
            Err(ScanError::Unreadable(reason)) => {
                state.active = false;
                return Some(Report::Failed { source, reason });
            }
        };
        let rows = scan.rows;
        let hosts = u64::try_from(scan.fingerprint.len()).unwrap_or(u64::MAX);
        let (scan_ms, cpu_ms) = (cost.scan_ms, cost.cpu_ms);
        let Some(base) = &state.baseline else {
            if let Err(error) = baseline::save(&state_dir, &source, &scan.fingerprint) {
                state.active = false;
                return Some(Report::Failed { source, reason: format!("state: {}", error.kind()) });
            }
            state.baseline = Some(scan.fingerprint);
            return Some(Report::Scanned {
                source,
                rows,
                hosts,
                scan_ms,
                cpu_ms,
                reason: Reason::Baseline,
            });
        };
        let difference = diff(base, &scan.fingerprint);
        if difference.is_empty() {
            state.pending = None;
            return Some(Report::Scanned { source, rows, hosts, scan_ms, cpu_ms, reason });
        }
        state.pending = Some(scan.fingerprint);
        Some(Report::Changed {
            source,
            changed: difference.changed,
            removed: difference.removed,
            rows,
            hosts,
            scan_ms,
            cpu_ms,
            reason,
        })
    }

    /// The app imported the last change reported for `id`: it becomes the
    /// baseline (saved). False when `id` is unknown, nothing is pending, or
    /// the baseline could not be saved (then the change stays pending and is
    /// reported again).
    pub fn commit(&mut self, id: &str) -> bool {
        let Some(state) = self.states.iter_mut().find(|state| state.source.id == id) else {
            return false;
        };
        let Some(pending) = state.pending.take() else { return false };
        if baseline::save(&self.state_dir, id, &pending).is_err() {
            state.pending = Some(pending);
            return false;
        }
        state.baseline = Some(pending);
        true
    }
}

/// Receives each report on the sync's thread.
pub type Sink = Box<dyn FnMut(&Report) + Send>;

enum Message {
    File(notify::Result<notify::Event>),
    Stop,
}

/// The running sync: one thread watching every source. Dropping it stops
/// the thread and waits for it.
pub struct CookieSync {
    core: Arc<Mutex<Core>>,
    messages: Sender<Message>,
    thread: Option<JoinHandle<()>>,
}

impl CookieSync {
    /// Starts the thread: it checks every source once (the launch check),
    /// then scans a source after its database changes.
    pub fn start(config: Config, sink: Sink) -> io::Result<Self> {
        let core = Arc::new(Mutex::new(Core::new(&config)));
        let (messages, inbox) = mpsc::channel();
        let thread_core = Arc::clone(&core);
        let events = messages.clone();
        let thread = std::thread::Builder::new()
            .name("cmux-cookie-sync".to_owned())
            .spawn(move || run(&config, &thread_core, &events, &inbox, sink))?;
        Ok(Self { core, messages, thread: Some(thread) })
    }

    /// See [`Core::commit`].
    pub fn commit(&self, id: &str) -> bool {
        lock(&self.core).commit(id)
    }
}

impl Drop for CookieSync {
    fn drop(&mut self) {
        let _ = self.messages.send(Message::Stop);
        if let Some(thread) = self.thread.take()
            && thread.thread().id() != std::thread::current().id()
        {
            let _ = thread.join();
        }
    }
}

fn lock(core: &Mutex<Core>) -> MutexGuard<'_, Core> {
    core.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Which file events belong to which source: a source's directory (as
/// given and resolved; FSEvents reports resolved paths) and its database's
/// file names (`Cookies`, `Cookies-journal`, `Cookies-wal`; not `-shm`).
struct Routes {
    sources: Vec<(BTreeSet<PathBuf>, BTreeSet<OsString>)>,
}

impl Routes {
    fn new(sources: &[Source]) -> Self {
        let sources = sources
            .iter()
            .map(|source| {
                let mut dirs = BTreeSet::new();
                if let Some(dir) = source.database.parent() {
                    dirs.insert(dir.to_path_buf());
                    if let Ok(resolved) = std::fs::canonicalize(dir) {
                        dirs.insert(resolved);
                    }
                }
                let names = ["", "-journal", "-wal"]
                    .iter()
                    .filter_map(|suffix| {
                        sidecar(&source.database, suffix).file_name().map(OsString::from)
                    })
                    .collect();
                (dirs, names)
            })
            .collect();
        Self { sources }
    }

    fn matches(&self, path: &Path) -> Vec<usize> {
        let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else { return Vec::new() };
        self.sources
            .iter()
            .enumerate()
            .filter(|(_, (dirs, names))| dirs.contains(dir) && names.contains(name))
            .map(|(index, _)| index)
            .collect()
    }
}

/// A write, create, rename or delete; not a read or an access-time touch
/// (the scan's own read of the file must not schedule another scan).
fn is_change(kind: &EventKind) -> bool {
    match kind {
        EventKind::Create(_) | EventKind::Remove(_) | EventKind::Any => true,
        EventKind::Modify(ModifyKind::Metadata(MetadataKind::AccessTime)) => false,
        EventKind::Modify(_) => true,
        EventKind::Access(_) | EventKind::Other => false,
    }
}

/// The thread: the launch check, then one scan per due source until `Stop`.
/// It waits on its channel (file events, the stop) with no timer unless a
/// scan is due.
fn run(
    config: &Config,
    core: &Mutex<Core>,
    events: &Sender<Message>,
    inbox: &Receiver<Message>,
    mut sink: Sink,
) {
    let started = Instant::now();
    let routes = Routes::new(&config.sources);
    let events = events.clone();
    let mut watcher = notify::recommended_watcher(move |event| {
        let _ = events.send(Message::File(event));
    })
    .ok();
    // directory -> the sources watched through it.
    let mut watched: BTreeMap<PathBuf, BTreeSet<usize>> = BTreeMap::new();
    for (index, source) in config.sources.iter().enumerate() {
        if let Some(dir) = source.database.parent() {
            watched.entry(dir.to_path_buf()).or_default().insert(index);
        }
    }
    if let Some(watcher) = watcher.as_mut() {
        for dir in watched.keys() {
            let _ = watcher.watch(dir, RecursiveMode::NonRecursive);
        }
    }
    let mut schedule = Scheduler::new(
        config.sources.len(),
        Duration::from_millis(config.debounce_ms),
        Duration::from_millis(config.min_interval_ms),
    );
    let mut scan = |index: usize, reason: Reason, schedule: &mut Scheduler| {
        let database = lock(core).database(index).map(Path::to_path_buf);
        let Some(database) = database else { return };
        let (outcome, cost) = measure(&database);
        let (report, active) = {
            let mut core = lock(core);
            let report = core.apply(index, outcome, cost, reason);
            (report, core.database(index).is_some())
        };
        schedule.scanned(index, started.elapsed());
        if !active {
            schedule.remove(index);
            if let Some(dir) = database.parent()
                && let Some(sources) = watched.get_mut(dir)
            {
                sources.remove(&index);
                if sources.is_empty() {
                    watched.remove(dir);
                    if let Some(watcher) = watcher.as_mut() {
                        let _ = watcher.unwatch(dir);
                    }
                }
            }
        }
        if let Some(report) = report {
            sink(&report);
        }
    };
    for index in 0..config.sources.len() {
        scan(index, Reason::Launch, &mut schedule);
    }
    loop {
        let message = match schedule.next_due() {
            Some(at) => match inbox.recv_timeout(at.saturating_sub(started.elapsed())) {
                Ok(message) => Some(message),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => break,
            },
            None => match inbox.recv() {
                Ok(message) => Some(message),
                Err(_) => break,
            },
        };
        match message {
            Some(Message::Stop) => break,
            Some(Message::File(Ok(event))) if is_change(&event.kind) => {
                for path in &event.paths {
                    for index in routes.matches(path) {
                        schedule.event(index, started.elapsed());
                    }
                }
            }
            Some(Message::File(_)) | None => {}
        }
        for index in schedule.due(started.elapsed()) {
            scan(index, Reason::Watch, &mut schedule);
        }
    }
}
