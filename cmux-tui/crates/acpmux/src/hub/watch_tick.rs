//! One check for every watched transcript (`watch.rs`), so a quiet watch costs no wakeup of its
//! own (Leo 2026-11-04: "never ... acceptable ... linear time growth degradation"). Each watch
//! used to wake 2.5 times a second and open and read its transcript on a blocking thread.
//!
//! One task, the hub's [`WatchTicker`], wakes every [`FAST`] while a transcript grew in the last
//! [`QUIET_AFTER`] (or a watch just started), and every [`SLOW`] after that. Each wake reads the
//! length of every watched transcript in one blocking call and wakes only the watches whose
//! transcript's length moved, or whose chat closed or stopped watching (they end). A watch reads
//! its transcript only then. A watch that starts cuts the current wait short: the check runs at
//! once and then at [`FAST`], so its next line shows within [`FAST`] even when every other watch
//! was quiet (review F1 of #39357). A watch whose last read or start failed is woken at the next
//! check while its transcript exists ([`Registration::retry`]). The task ends when no watch is left
//! (a new watch starts it again) or the hub drops.
//!
//! A write cuts the wait short too (Leo 2026-11-12: terminal and chat are two live views of one
//! session, a toggle under 100 ms). The task keeps one file-event watch ([`Events`]) on the
//! folders that hold the watched transcripts, one watch per folder however many transcripts it
//! holds: Linux `quiet_dirs` (inotify for changes only), elsewhere `notify`'s watcher (FSEvents
//! on macOS). An event naming a watched transcript marks it and wakes the task, which reads the
//! lengths of only the marked ones in one blocking call and wakes the watches whose length moved.
//! Events only shorten the wait: the lengths stay the truth, and the timed check still runs, so
//! a lost event (a full queue, a folder the watch could not follow) costs at most a tick, as
//! before. The watch is made with the task and dropped when it ends.

use super::super::{Session, SessionStatus};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::time::Instant;

/// How often the transcripts are checked while one grew lately.
pub(super) const FAST: Duration = Duration::from_millis(400);

/// How often they are checked once all were quiet for [`QUIET_AFTER`].
pub(super) const SLOW: Duration = Duration::from_secs(2);

/// How long the checks stay at [`FAST`] after a transcript grew or a watch started.
pub(super) const QUIET_AFTER: Duration = Duration::from_secs(30);

/// The hub's one check of its watched transcripts.
#[derive(Default)]
pub(crate) struct WatchTicker {
    state: Arc<State>,
}

#[derive(Default)]
struct State {
    watches: Mutex<Watches>,
    /// Set when the hub drops; `kick` wakes the task to see it.
    stop: AtomicBool,
    /// A watch started, or the hub dropped: the task stops waiting. Kicks coalesce, so a burst of
    /// starts is one early check.
    kick: Notify,
    /// A file event named a watched transcript ([`Watches::written`]): check those now.
    written: Notify,
}

#[derive(Default)]
struct Watches {
    next: u64,
    by_key: HashMap<u64, Entry>,
    /// The task runs.
    running: bool,
    /// When a transcript last grew or a watch started.
    lively: Option<Instant>,
    /// The watches whose transcript a file event named since the last check.
    written: HashSet<u64>,
}

struct Entry {
    session: Weak<Session>,
    wake: Arc<Notify>,
    /// The transcript's length at the last check (`None`: missing or unreadable).
    seen: Option<u64>,
    /// Wake at the next check even if the length did not move.
    retry: bool,
    /// The transcript at the last check, which file events are matched against.
    file: Option<PathBuf>,
}

impl Drop for WatchTicker {
    fn drop(&mut self) {
        self.state.stop.store(true, Ordering::SeqCst);
        self.state.kick.notify_one();
    }
}

/// One watch's place in the check; dropping it leaves the check.
pub(super) struct Registration {
    state: Arc<State>,
    key: u64,
    wake: Arc<Notify>,
}

impl Registration {
    /// Until the transcript's length moved, the chat stopped watching, or a retry is due.
    pub(super) async fn wait(&self) {
        self.wake.notified().await;
    }

    /// The next check wakes this watch even if its transcript's length did not move, as long as
    /// the transcript exists: its read or its start failed.
    pub(super) fn retry(&self) {
        let mut watches = self.state.watches.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = watches.by_key.get_mut(&self.key) {
            entry.retry = true;
        }
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        let mut watches = self.state.watches.lock().unwrap_or_else(|e| e.into_inner());
        watches.by_key.remove(&self.key);
        watches.written.remove(&self.key);
    }
}

impl WatchTicker {
    /// Adds `session`'s watch to the check, starting the check's task when it is not running.
    pub(super) fn register(&self, session: &Arc<Session>) -> Registration {
        let wake = Arc::new(Notify::new());
        let mut watches = self.state.watches.lock().unwrap_or_else(|e| e.into_inner());
        let key = watches.next;
        watches.next = watches.next.wrapping_add(1);
        watches.by_key.insert(
            key,
            Entry {
                session: Arc::downgrade(session),
                wake: wake.clone(),
                seen: None,
                retry: false,
                file: None,
            },
        );
        watches.lively = Some(Instant::now());
        if !watches.running {
            watches.running = true;
            tokio::spawn(run(self.state.clone()));
        }
        drop(watches);
        self.state.kick.notify_one();
        Registration { state: self.state.clone(), key, wake }
    }
}

/// The transcript `session` watches, or `None` when its watch is over.
fn watched_file(session: &Session) -> Option<PathBuf> {
    if session.purged.load(Ordering::SeqCst) {
        return None;
    }
    let meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
    if meta.status == SessionStatus::Closed {
        return None;
    }
    meta.watching.as_ref().map(|w| w.file.clone())
}

async fn run(state: Arc<State>) {
    // The file-event watch, made at the first check (off the runtime) and dropped with the task.
    let mut events: Option<Events> = None;
    let mut tried = false;
    // When the last full check ran: an event check does not push the next one back, so a
    // transcript written all the time never delays the other watches' checks.
    let mut last_full = Instant::now();
    loop {
        let lively = {
            let mut watches = state.watches.lock().unwrap_or_else(|e| e.into_inner());
            if watches.by_key.is_empty() || state.stop.load(Ordering::SeqCst) {
                watches.running = false;
                return;
            }
            watches.lively
        };
        let every = if lively.is_some_and(|at| at.elapsed() < QUIET_AFTER) { FAST } else { SLOW };
        // True: only the transcripts a file event named are checked.
        let written = tokio::select! {
            _ = tokio::time::sleep_until(last_full + every) => false,
            _ = state.kick.notified() => {
                if state.stop.load(Ordering::SeqCst) {
                    continue;
                }
                false
            }
            _ = state.written.notified() => true,
        };
        if !written {
            last_full = Instant::now();
        }
        #[cfg(test)]
        super::idle_cost::wakeup();
        let (mut files, mut over) = (Vec::new(), Vec::new());
        {
            let mut watches = state.watches.lock().unwrap_or_else(|e| e.into_inner());
            let marked = std::mem::take(&mut watches.written);
            for (key, entry) in &mut watches.by_key {
                if written && !marked.contains(key) {
                    continue;
                }
                match entry.session.upgrade().as_deref().and_then(watched_file) {
                    Some(file) => {
                        entry.file = Some(file.clone());
                        files.push((*key, file));
                    }
                    None => {
                        entry.file = None;
                        over.push(entry.wake.clone());
                    }
                }
            }
        }
        // The watch sees it is over and ends, dropping its registration.
        for wake in over {
            wake.notify_one();
        }
        if files.is_empty() {
            continue;
        }
        // A full check follows the folders of every watched transcript; an event check names
        // only some of them, so it leaves the watch as it is.
        let follow = (!written).then(|| {
            let mut dirs: Vec<PathBuf> =
                files.iter().filter_map(|(_, f)| f.parent().map(Path::to_path_buf)).collect();
            dirs.sort();
            dirs.dedup();
            dirs
        });
        let mut held = events.take();
        // Made once per run of the task: a system that refused it is not asked at every check.
        let start = follow.is_some() && held.is_none() && !tried;
        tried |= start;
        let weak = Arc::downgrade(&state);
        #[cfg(test)]
        super::idle_cost::blocking();
        let checked = tokio::task::spawn_blocking(move || {
            if start {
                held = Events::start(weak);
            }
            // Followed before the lengths are read: a write before its folder's watch is in
            // this read's lengths, one after it is an event.
            if let (Some(events), Some(dirs)) = (held.as_mut(), follow) {
                events.follow(dirs);
            }
            let lengths = files
                .into_iter()
                .map(|(key, file)| (key, std::fs::metadata(&file).ok().map(|m| m.len())))
                .collect::<Vec<_>>();
            (lengths, held)
        })
        .await;
        let Ok((lengths, held)) = checked else {
            // The watch was lost with the call: made again at the next check.
            tried = false;
            continue;
        };
        events = held;
        let mut watches = state.watches.lock().unwrap_or_else(|e| e.into_inner());
        let mut grew = false;
        for (key, length) in lengths {
            let Some(entry) = watches.by_key.get_mut(&key) else { continue };
            let moved = entry.seen != length;
            let retry = std::mem::take(&mut entry.retry) && length.is_some();
            entry.seen = length;
            if moved || retry {
                entry.wake.notify_one();
            }
            grew |= moved;
        }
        if grew {
            watches.lively = Some(Instant::now());
        }
    }
}

/// Marks the watches whose transcript an event named and wakes the task. `paths: None` is a
/// lost event (a full queue, a rescan): every watch is marked. A path matches a transcript that
/// is it, is under it (a folder made, moved or removed), or has its name (an event that names
/// the folder a link leads to; transcript names are session ids).
fn written(state: &State, paths: Option<&[PathBuf]>) {
    let mut watches = state.watches.lock().unwrap_or_else(|e| e.into_inner());
    let Watches { by_key, written, .. } = &mut *watches;
    let mut hit = false;
    for (key, entry) in by_key.iter() {
        let Some(file) = &entry.file else { continue };
        let named = paths.is_none_or(|paths| {
            paths.iter().any(|p| {
                file.starts_with(p)
                    || p.file_name().is_some_and(|name| file.file_name() == Some(name))
            })
        });
        if named {
            written.insert(*key);
            hit = true;
        }
    }
    drop(watches);
    if hit {
        state.written.notify_one();
    }
}

/// The task's file-event watch on the folders of the watched transcripts, one watch per folder.
/// Its thread holds the check only weakly, so it never keeps it alive.
struct Events {
    #[cfg(target_os = "linux")]
    dirs: crate::quiet_dirs::QuietDirs,
    #[cfg(not(target_os = "linux"))]
    watcher: notify::RecommendedWatcher,
    /// The folders asked for at the last [`Events::follow`].
    wanted: Vec<PathBuf>,
    /// The folders watched now (Linux: `quiet_dirs` keeps its own).
    #[cfg(not(target_os = "linux"))]
    watched: HashSet<PathBuf>,
}

impl Events {
    /// Starts the watch, or `None` when the system refuses one (the timed check still runs).
    #[cfg(target_os = "linux")]
    fn start(state: Weak<State>) -> Option<Self> {
        let (tx, rx) = std::sync::mpsc::channel::<notify::Result<notify::Event>>();
        let dirs =
            match crate::quiet_dirs::QuietDirs::follow(tx, "acpmux-watch-inotify", Vec::new()) {
                Ok(dirs) => dirs,
                Err(e) => {
                    tracing::debug!("watched transcripts: no file events ({e}); checks stay timed");
                    return None;
                }
            };
        // task-owner: the Events; ends when its QuietDirs drops (its reading thread ends and
        // drops the sender) or the check is gone.
        let spawned =
            std::thread::Builder::new().name("acpmux-watch-events".into()).spawn(move || {
                while let Ok(first) = rx.recv() {
                    // A burst (one write is a modify and a close) is one pass.
                    let mut lost = false;
                    let mut paths = Vec::new();
                    for event in std::iter::once(first).chain(rx.try_iter()) {
                        match event {
                            Ok(event) => paths.extend(event.paths),
                            Err(_) => lost = true,
                        }
                    }
                    let Some(state) = state.upgrade() else { return };
                    written(&state, (!lost).then_some(paths.as_slice()));
                }
            });
        if let Err(e) = spawned {
            tracing::debug!("watched transcripts: no file events ({e}); checks stay timed");
            return None;
        }
        Some(Self { dirs, wanted: Vec::new() })
    }

    /// Starts the watch, or `None` when the system refuses one (the timed check still runs).
    #[cfg(not(target_os = "linux"))]
    fn start(state: Weak<State>) -> Option<Self> {
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let Some(state) = state.upgrade() else { return };
            match event {
                Ok(event) if !event.need_rescan() && !event.paths.is_empty() => {
                    written(&state, Some(&event.paths));
                }
                _ => written(&state, None),
            }
        });
        match watcher {
            Ok(watcher) => Some(Self { watcher, wanted: Vec::new(), watched: HashSet::new() }),
            Err(e) => {
                tracing::debug!("watched transcripts: no file events ({e}); checks stay timed");
                None
            }
        }
    }

    /// Watches exactly `dirs` (sorted, each once). Blocking.
    fn follow(&mut self, dirs: Vec<PathBuf>) {
        #[cfg(target_os = "linux")]
        {
            if dirs == self.wanted {
                return;
            }
            // A missing folder is followed through its nearest existing ancestor.
            self.dirs.retarget(dirs.iter().cloned().map(crate::quiet_dirs::Target::Dir).collect());
        }
        #[cfg(not(target_os = "linux"))]
        {
            use notify::Watcher as _;
            if dirs == self.wanted && dirs.len() == self.watched.len() {
                return;
            }
            let gone: Vec<PathBuf> =
                self.watched.iter().filter(|d| !dirs.contains(d)).cloned().collect();
            for dir in gone {
                let _ = self.watcher.unwatch(&dir);
                self.watched.remove(&dir);
            }
            for dir in &dirs {
                // A folder missing now is tried again at the next full check.
                if !self.watched.contains(dir)
                    && self.watcher.watch(dir, notify::RecursiveMode::NonRecursive).is_ok()
                {
                    self.watched.insert(dir.clone());
                }
            }
        }
        self.wanted = dirs;
    }
}
