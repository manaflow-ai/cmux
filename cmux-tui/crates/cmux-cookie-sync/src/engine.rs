//! The sources, their baselines and what one scan reports ([`Core`], no
//! thread, testable on its own), and the one background thread that watches
//! every source and scans it on schedule ([`CookieSync`]).

use crate::baseline;
use crate::diff::{diff, domain};
use crate::fingerprint::{Fingerprint, Scan, ScanError, fingerprint};
use crate::schedule::Scheduler;
use crate::watch::{FileWatch, Stopper, Wake, refresh, sidecar, timeout};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};
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
    /// every database are absolute paths, every id is non-empty and unique,
    /// and no two sources share a database.
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        let config: Self = serde_json::from_slice(bytes).ok()?;
        let mut ids = BTreeSet::new();
        let mut databases = BTreeSet::new();
        let valid = config.state_dir.is_absolute()
            && config.sources.iter().all(|source| {
                !source.id.is_empty()
                    && ids.insert(source.id.as_str())
                    && databases.insert(source.database.as_path())
                    && source.database.is_absolute()
                    && source.database.file_name().is_some()
            });
        drop((ids, databases));
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
    /// These domains differ from the baseline: re-import them, then commit
    /// with this report's `generation`.
    Changed {
        source: String,
        generation: u64,
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
    /// The last reported fingerprint that differs from the baseline, with
    /// its report's generation; `commit` of that generation saves it as the
    /// baseline.
    pending: Option<(u64, Fingerprint)>,
    /// Every domain reported since the last commit. Each later report names
    /// them again, also one whose cookies went back to the baseline: the app
    /// may have imported the value in between.
    touched: BTreeSet<String>,
    active: bool,
}

/// Every source's baseline and what a scan of it reports.
#[derive(Debug)]
pub struct Core {
    state_dir: PathBuf,
    states: Vec<State>,
    /// The last `changed` report's generation (they count up from 1).
    generation: u64,
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
                touched: BTreeSet::new(),
                active: true,
            })
            .collect();
        Self { state_dir: config.state_dir.clone(), states, generation: 0 }
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
        if difference.is_empty() && state.touched.is_empty() {
            state.pending = None;
            return Some(Report::Scanned { source, rows, hosts, scan_ms, cpu_ms, reason });
        }
        state.touched.extend(difference.changed);
        state.touched.extend(difference.removed);
        let present: BTreeSet<&str> = scan.fingerprint.keys().map(|host| domain(host)).collect();
        let (changed, removed): (Vec<String>, Vec<String>) =
            state.touched.iter().cloned().partition(|name| present.contains(name.as_str()));
        self.generation = self.generation.saturating_add(1);
        let generation = self.generation;
        state.pending = Some((generation, scan.fingerprint));
        Some(Report::Changed {
            source,
            generation,
            changed,
            removed,
            rows,
            hosts,
            scan_ms,
            cpu_ms,
            reason,
        })
    }

    /// The app imported the `changed` report of `id` with `generation`: its
    /// fingerprint becomes the baseline (saved). False when `id` is unknown,
    /// that report is not the source's latest (a later report, which also
    /// holds its domains, is the one to commit), a later scan found the store
    /// back at the baseline, or the baseline could not be saved (then the
    /// change stays pending and is reported again).
    pub fn commit(&mut self, id: &str, generation: u64) -> bool {
        let Some(state) = self.states.iter_mut().find(|state| state.source.id == id) else {
            return false;
        };
        let Some((pending_generation, pending)) = state.pending.take() else { return false };
        if pending_generation != generation
            || baseline::save(&self.state_dir, id, &pending).is_err()
        {
            state.pending = Some((pending_generation, pending));
            return false;
        }
        state.baseline = Some(pending);
        state.touched.clear();
        true
    }
}

/// Receives each report on the sync's thread.
pub type Sink = Box<dyn FnMut(&Report) + Send>;

/// The running sync: one thread watching every source. Dropping it stops
/// the thread and waits for it.
pub struct CookieSync {
    core: Arc<Mutex<Core>>,
    stopper: Stopper,
    thread: Option<JoinHandle<()>>,
}

impl CookieSync {
    /// Starts the thread: it checks every source once (the launch check),
    /// then scans a source after its database changes.
    pub fn start(config: Config, sink: Sink) -> io::Result<Self> {
        let core = Arc::new(Mutex::new(Core::new(&config)));
        let (watch, stopper) = FileWatch::new()?;
        let thread_core = Arc::clone(&core);
        let thread = std::thread::Builder::new()
            .name("cmux-cookie-sync".to_owned())
            .spawn(move || run(&config, &thread_core, watch, sink))?;
        Ok(Self { core, stopper, thread: Some(thread) })
    }

    /// See [`Core::commit`].
    pub fn commit(&self, id: &str, generation: u64) -> bool {
        lock(&self.core).commit(id, generation)
    }
}

impl Drop for CookieSync {
    fn drop(&mut self) {
        self.stopper.stop();
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

/// Which changed file belongs to which source: the database's directory (as
/// given and resolved, in case a watcher reports resolved paths) and its
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

    /// Whether `path` is source `index`'s directory.
    fn is_dir_of(&self, index: usize, path: &Path) -> bool {
        self.sources.get(index).is_some_and(|(dirs, _)| dirs.contains(path))
    }

    /// The sources whose directory is `path` or holds it.
    fn in_dir(&self, path: &Path) -> Vec<usize> {
        self.sources
            .iter()
            .enumerate()
            .filter(|(_, (dirs, _))| {
                dirs.contains(path) || path.parent().is_some_and(|dir| dirs.contains(dir))
            })
            .map(|(index, _)| index)
            .collect()
    }
}

/// The thread: the launch check, then one scan per due source until the
/// stop. It blocks in one wait (a watched file's change, the stop) with no
/// deadline unless a scan is due.
///
/// Each source's database is watched, its `-wal` while it exists, and their
/// directory (so a new `-wal` is seen); a rollback journal comes and goes,
/// but every commit writes the database. After a delete or rename, or lost
/// events, the watches are made again on the paths; a source that is `gone`
/// or `failed` is no longer watched. A wait that cannot go on reports every
/// watched source `failed` and ends the thread.
fn run(config: &Config, core: &Mutex<Core>, mut watch: FileWatch, mut sink: Sink) {
    let started = Instant::now();
    let sources = config.sources.len();
    let databases: Vec<&Path> =
        config.sources.iter().map(|source| source.database.as_path()).collect();
    let routes = Routes::new(&config.sources);
    let mut watched: Vec<BTreeSet<PathBuf>> = vec![BTreeSet::new(); sources];
    for (database, files) in databases.iter().zip(watched.iter_mut()) {
        refresh(&mut watch, files, database, false);
    }
    let mut schedule = Scheduler::new(
        sources,
        Duration::from_millis(config.debounce_ms),
        Duration::from_millis(config.min_interval_ms),
    );
    let mut rearm: BTreeSet<usize> = BTreeSet::new();
    let scan = |index: usize,
                reason: Reason,
                schedule: &mut Scheduler,
                rearm: &mut BTreeSet<usize>,
                watch: &mut FileWatch,
                watched: &mut Vec<BTreeSet<PathBuf>>|
     -> Option<Report> {
        let database = lock(core).database(index).map(Path::to_path_buf)?;
        // Rearm before the read: a replaced file's writes during the read
        // land on the new watch and schedule the next scan.
        if let Some(files) = watched.get_mut(index) {
            refresh(watch, files, &database, rearm.remove(&index));
        }
        let (outcome, cost) = measure(&database);
        let (report, active) = {
            let mut core = lock(core);
            let report = core.apply(index, outcome, cost, reason);
            (report, core.database(index).is_some())
        };
        schedule.scanned(index, started.elapsed());
        if !active {
            schedule.remove(index);
            let files = watched.get_mut(index).map(std::mem::take).unwrap_or_default();
            for path in files {
                // A directory another watched source still uses stays watched.
                if !watched.iter().any(|other| other.contains(&path)) {
                    watch.unwatch(&path);
                }
            }
        }
        report
    };
    for index in 0..sources {
        if let Some(report) =
            scan(index, Reason::Launch, &mut schedule, &mut rearm, &mut watch, &mut watched)
        {
            sink(&report);
        }
    }
    'wait: loop {
        for wake in watch.wait(timeout(schedule.next_due(), started.elapsed())) {
            match wake {
                Wake::Stop => break 'wait,
                Wake::Failed(reason) => {
                    // The watch cannot go on: every source still watched is
                    // reported failed once, and the thread ends.
                    for index in 0..sources {
                        let failed = {
                            let mut core = lock(core);
                            let outcome = Err(ScanError::Unreadable(reason.clone()));
                            let cost = Cost { scan_ms: 0.0, cpu_ms: None };
                            core.apply(index, outcome, cost, Reason::Watch)
                        };
                        if let Some(report) = failed {
                            sink(&report);
                        }
                    }
                    break 'wait;
                }
                Wake::Rescan => {
                    // Events were lost, a delete or rename among them maybe:
                    // every source's watches are made again and it is scanned.
                    for (index, files) in watched.iter_mut().enumerate() {
                        if let Some(database) = databases.get(index)
                            && lock(core).database(index).is_some()
                        {
                            refresh(&mut watch, files, database, true);
                            schedule.event(index, started.elapsed());
                        }
                    }
                }
                Wake::Changed { paths, moved } => {
                    for path in &paths {
                        for index in routes.matches(path) {
                            schedule.event(index, started.elapsed());
                            if moved {
                                rearm.insert(index);
                            }
                        }
                        // A change in a source's directory: a `-wal` may have
                        // appeared or gone; watch what is there now. The
                        // directory itself moved: every watch is made again
                        // (they follow the old directory) and it is scanned.
                        for index in routes.in_dir(path) {
                            if moved && routes.is_dir_of(index, path) {
                                rearm.insert(index);
                                schedule.event(index, started.elapsed());
                            } else if let (Some(files), Some(database)) =
                                (watched.get_mut(index), databases.get(index))
                                && lock(core).database(index).is_some()
                                && refresh(&mut watch, files, database, false)
                            {
                                schedule.event(index, started.elapsed());
                            }
                        }
                    }
                }
            }
        }
        for index in schedule.due(started.elapsed()) {
            if let Some(report) =
                scan(index, Reason::Watch, &mut schedule, &mut rearm, &mut watch, &mut watched)
            {
                sink(&report);
            }
        }
    }
}
