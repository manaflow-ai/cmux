//! The search-everything index service (`search-v1`,
//! plans/cmux-next/search-everything-DESIGN.md): one `cmux_search`
//! engine per daemon, fed by a worker thread.
//!
//! The PTY reader loops only mark a terminal dirty (one set insert, and a
//! channel send on the first output since the last capture). Tree changes
//! (renames, adds, closes, selection) send one signal. The worker blocks on
//! its channel, so an idle daemon never wakes it. After output it waits a
//! bounded debounce, then reads each dirty terminal once: new scrollback
//! rows, or the alternate screen frame (deduplicated by `ScreenFrames`).
//! After a tree change it resyncs names, ranking context (workspace, group,
//! title, folder, branch) and the focus history. Full segments seal on the
//! worker with no engine lock held. The index lives in
//! `<session state dir>/search/v1`; a session without a state directory
//! keeps it in memory.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockWriteGuard, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_search::{
    Doc, EngineConfig, Kind, NameDoc, Query, ScreenFrames, SearchEngine, SearchResult, Stats,
    TargetContext,
};

use crate::shell_history::FinishedCommand;
use crate::surface::{ScrollbackCursor, TerminalCapture};
use crate::{Mux, SurfaceId};

/// Signals the worker queue holds before a sender counts a drop.
const QUEUE: usize = 1024;
/// Quiet time after output before the worker reads the dirty terminals.
const DEBOUNCE: Duration = Duration::from_millis(500);
/// Reads of one terminal per capture pass before it yields to the others.
const READS_PER_PASS: usize = 64;

enum Signal {
    Output,
    Tree,
    Commands { terminal: String, commands: Vec<FinishedCommand> },
    Stop,
}

/// What the worker does after one signal.
#[derive(Clone, Copy, Default)]
struct Work {
    capture: bool,
    tree: bool,
}

/// The tree as the index sees it, read from the mux by the worker.
#[derive(Default)]
pub(crate) struct ModelSnapshot {
    pub names: Vec<NameDoc>,
    pub contexts: Vec<(String, TargetContext)>,
    /// The focused workspace, screen, pane, tab and terminal ids.
    pub focus: Vec<String>,
}

/// The service a `Mux` holds once the first terminal output or query
/// creates it.
pub struct SearchEverything {
    engine: Arc<RwLock<SearchEngine>>,
    sender: SyncSender<Signal>,
    dirty: Arc<Mutex<HashSet<SurfaceId>>>,
    dropped: AtomicU64,
    worker: Mutex<Option<JoinHandle<()>>>,
}

/// Index counters for `search-stats`.
#[derive(Clone, Copy, Debug)]
pub struct SearchEverythingStats {
    pub stats: Stats,
    /// Signals dropped because the worker queue was full.
    pub dropped: u64,
}

impl SearchEverything {
    /// Opens the index in `directory` (empty when none or unreadable) and
    /// starts the worker, which first syncs the tree.
    pub(crate) fn start(mux: Weak<Mux>, directory: Option<PathBuf>) -> Self {
        let config = EngineConfig::default();
        let mut engine = match &directory {
            Some(directory) => SearchEngine::open(directory, config).unwrap_or_else(|error| {
                eprintln!("cmux-tui: search index unreadable, starting empty: {error}");
                SearchEngine::new(config)
            }),
            None => SearchEngine::new(config),
        };
        engine.set_background_seal(true);
        let engine = Arc::new(RwLock::new(engine));
        let dirty = Arc::new(Mutex::new(HashSet::new()));
        let (sender, receiver) = std::sync::mpsc::sync_channel(QUEUE);
        let worker = Worker {
            mux,
            engine: engine.clone(),
            dirty: dirty.clone(),
            directory,
            cursors: HashMap::new(),
            frames: ScreenFrames::new(),
            names: HashSet::new(),
            contexts: HashSet::new(),
            focus: Vec::new(),
        };
        let worker = std::thread::Builder::new()
            .name("search-everything".into())
            .spawn(move || worker.run(receiver))
            .map_err(|error| eprintln!("cmux-tui: search worker did not start: {error}"))
            .ok();
        let service =
            Self { engine, sender, dirty, dropped: AtomicU64::new(0), worker: Mutex::new(worker) };
        service.send(Signal::Tree);
        service
    }

    /// Terminal `surface` had output (the PTY reader hot path).
    pub(crate) fn note_output(&self, surface: SurfaceId) {
        let first = lock(&self.dirty).insert(surface);
        if first {
            self.send(Signal::Output);
        }
    }

    /// The tree changed (names, membership or selection).
    pub(crate) fn note_tree(&self) {
        self.send(Signal::Tree);
    }

    /// Finished shell commands of `terminal` (OSC 133).
    pub(crate) fn note_commands(&self, terminal: String, commands: Vec<FinishedCommand>) {
        self.send(Signal::Commands { terminal, commands });
    }

    fn send(&self, signal: Signal) {
        match self.sender.try_send(signal) {
            Ok(()) => {}
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    pub fn search(&self, query: &Query) -> SearchResult {
        self.engine.read().unwrap_or_else(PoisonError::into_inner).search(query)
    }

    /// The user opened a hit jumping to `target` (frecency).
    pub fn record_open(&self, target: &str, now_ms: i64) {
        self.engine.write().unwrap_or_else(PoisonError::into_inner).record_open(target, now_ms);
    }

    pub fn stats(&self) -> SearchEverythingStats {
        let stats = self.engine.read().unwrap_or_else(PoisonError::into_inner).stats();
        SearchEverythingStats { stats, dropped: self.dropped.load(Ordering::Relaxed) }
    }

    /// Stops the worker, which saves the index. Idempotent.
    pub(crate) fn stop(&self) {
        let Some(worker) = lock(&self.worker).take() else { return };
        // Blocking send: a full queue still drains, the worker reads until Stop.
        let _ = self.sender.send(Signal::Stop);
        if worker.thread().id() != std::thread::current().id() {
            let _ = worker.join();
        }
    }
}

impl Drop for SearchEverything {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Worker {
    mux: Weak<Mux>,
    engine: Arc<RwLock<SearchEngine>>,
    dirty: Arc<Mutex<HashSet<SurfaceId>>>,
    directory: Option<PathBuf>,
    cursors: HashMap<SurfaceId, ScrollbackCursor>,
    frames: ScreenFrames,
    /// Name keys and context targets last synced, to drop the gone ones.
    names: HashSet<String>,
    contexts: HashSet<String>,
    /// The focus last recorded, so an unrelated tree change records none.
    focus: Vec<String>,
}

impl Worker {
    fn run(mut self, receiver: Receiver<Signal>) {
        'signals: while let Ok(signal) = receiver.recv() {
            let Some(mut work) = self.handle(signal) else { break };
            if work.capture {
                // Bounded debounce after output, never a periodic timer.
                let deadline = Instant::now() + DEBOUNCE;
                loop {
                    let left = deadline.saturating_duration_since(Instant::now());
                    match receiver.recv_timeout(left) {
                        Ok(signal) => match self.handle(signal) {
                            Some(more) => {
                                work.capture |= more.capture;
                                work.tree |= more.tree;
                            }
                            None => {
                                self.apply(work);
                                break 'signals;
                            }
                        },
                        Err(RecvTimeoutError::Timeout) => break,
                        Err(RecvTimeoutError::Disconnected) => {
                            self.apply(work);
                            break 'signals;
                        }
                    }
                }
            }
            self.apply(work);
        }
        self.save();
    }

    fn apply(&mut self, work: Work) {
        if work.tree {
            self.sync_tree();
        }
        if work.capture {
            self.capture_dirty();
        }
        self.run_seals();
    }

    /// `None` for Stop; else the work the signal asks for.
    fn handle(&mut self, signal: Signal) -> Option<Work> {
        match signal {
            Signal::Stop => None,
            Signal::Output => Some(Work { capture: true, tree: false }),
            Signal::Tree => Some(Work { capture: false, tree: true }),
            Signal::Commands { terminal, commands } => {
                let mut engine = self.write_engine();
                for command in commands {
                    let Some(text) = command.command.filter(|text| !text.trim().is_empty()) else {
                        continue;
                    };
                    let at_ms = command.started_at_ms.saturating_add(command.duration_ms);
                    engine.append(Doc {
                        kind: Kind::Command,
                        source: format!("cmd:{terminal}"),
                        target: terminal.clone(),
                        position: None,
                        title: command.cwd.unwrap_or_else(|| "command".to_owned()),
                        text,
                        at_ms: i64::try_from(at_ms).unwrap_or(i64::MAX),
                        key: None,
                    });
                }
                Some(Work::default())
            }
        }
    }

    fn sync_tree(&mut self) {
        let Some(mux) = self.mux.upgrade() else { return };
        let now = crate::history_ops::now_ms();
        let snapshot = mux.search_model_snapshot(now);
        let names: HashSet<String> = snapshot.names.iter().map(|name| name.key.clone()).collect();
        let contexts: HashSet<String> =
            snapshot.contexts.iter().map(|(target, _)| target.clone()).collect();
        let focus_changed = snapshot.focus != self.focus;
        {
            let mut engine = self.write_engine();
            for gone in self.names.difference(&names) {
                engine.remove_name(gone);
            }
            for name in snapshot.names {
                engine.upsert_name(name);
            }
            for gone in self.contexts.difference(&contexts) {
                engine.remove_context(gone);
            }
            for (target, context) in snapshot.contexts {
                engine.set_context(&target, context);
            }
            if focus_changed {
                for target in &snapshot.focus {
                    engine.record_focus(target, now);
                }
            }
        }
        self.names = names;
        self.contexts = contexts;
        if focus_changed {
            self.focus = snapshot.focus;
        }
    }

    fn capture_dirty(&mut self) {
        let dirty: Vec<SurfaceId> = std::mem::take(&mut *lock(&self.dirty)).into_iter().collect();
        let Some(mux) = self.mux.upgrade() else { return };
        for id in dirty {
            let Some(surface) = mux.surface(id) else {
                self.cursors.remove(&id);
                self.frames.forget(&source_of(id));
                continue;
            };
            let target = surface
                .terminal_public_id()
                .map_or_else(|| format!("surface:{id}"), |terminal| terminal.to_string());
            let title =
                surface.name().filter(|name| !name.is_empty()).unwrap_or_else(|| surface.title());
            let title = if title.is_empty() { "terminal".to_owned() } else { title };
            let source = source_of(id);
            let cursor = self.cursors.entry(id).or_default();
            let mut finished = false;
            for _ in 0..READS_PER_PASS {
                let capture = surface.search_capture(cursor);
                let now = crate::history_ops::now_ms();
                let doc = |kind: Kind, position: i64, text: String| Doc {
                    kind,
                    source: source.clone(),
                    target: target.clone(),
                    position: Some(position),
                    title: title.clone(),
                    text,
                    at_ms: now,
                    key: None,
                };
                match capture {
                    TerminalCapture::Scrollback { first_marker, text, more } => {
                        if !text.trim().is_empty() {
                            let position = i64::try_from(first_marker).unwrap_or(i64::MAX);
                            write(&self.engine).append(doc(Kind::Scrollback, position, text));
                        }
                        if !more {
                            finished = true;
                            break;
                        }
                    }
                    TerminalCapture::Screen(text) => {
                        if self.frames.offer(&source, &text) {
                            write(&self.engine).append(doc(Kind::Screen, now, text));
                        }
                        finished = true;
                        break;
                    }
                    TerminalCapture::Nothing => {
                        finished = true;
                        break;
                    }
                }
            }
            if !finished {
                // More rows than one pass reads: come back on the next pass.
                lock(&self.dirty).insert(id);
            }
        }
    }

    /// Seals full segments: freeze under the lock (constant time), encode and
    /// write the file with no lock held, swap in under the lock.
    fn run_seals(&mut self) {
        let jobs = self.write_engine().take_seal_jobs();
        for job in jobs {
            let done = job.run();
            self.write_engine().finish_seal(done);
        }
    }

    fn save(&mut self) {
        self.run_seals();
        let Some(directory) = self.directory.clone() else { return };
        if let Err(error) = self.write_engine().save(&directory) {
            eprintln!("cmux-tui: search index save failed: {error}");
        }
    }

    fn write_engine(&self) -> RwLockWriteGuard<'_, SearchEngine> {
        write(&self.engine)
    }
}

fn write(engine: &RwLock<SearchEngine>) -> RwLockWriteGuard<'_, SearchEngine> {
    engine.write().unwrap_or_else(PoisonError::into_inner)
}

fn source_of(surface: SurfaceId) -> String {
    format!("term:{surface}")
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}
