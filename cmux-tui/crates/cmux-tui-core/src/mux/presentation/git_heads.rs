//! The git HEAD of each tab directory, cached, and kept current by a watch of the HEAD files.
//!
//! A tree reply names the branch of each terminal's directory. A read of a HEAD walks the file
//! system up to the repository. Before this cache had a watch, each value older than 2 seconds
//! was read again for each client that asked: K directories cost K reads each 2 seconds of
//! polling, and a `list-workspaces` with no `known` read its stale directories on its own
//! thread before it replied.
//!
//! The values live in a [`TagCache`] keyed by directory. Each value carries the tag of the
//! directory it was read from ([`HeadTag::Dir`]): the git dir that holds its HEAD file (a linked
//! worktree's own one under `.git/worktrees/`), or, for a directory in no repository, the
//! directory itself, where a new `.git` would make one. One file watch (non-recursive; on Linux
//! an inotify watch that asks for no opens, [`quiet_watch`], elsewhere `notify`'s) holds each of
//! those directories: every `git` command opens files in a git dir, and a read changes no HEAD. A write of a HEAD file (a checkout, a switch, a branch
//! rename, a commit on a detached HEAD: git renames `HEAD.lock` over it) or of a `.git` entry
//! invalidates that tag, which writes one number whatever is cached, and sends the directories
//! cached with it to the refresh. The refresh reads them, and for a value that changed moves the
//! tree revision and sends `tab-changed` for the tabs of that directory, so a client gets the new
//! branch with no request and no timer. A directory whose HEAD did not change is never read
//! again before [`GIT_HEAD_SAFETY_TTL`].
//!
//! Every walk of the tree, and every `list-workspaces` request with or without `known`, uses the
//! cached value whatever its state (stale-while-revalidate): a stale value goes to the refresh
//! and the reply never waits on a read. Only a directory with no cached value is read in the
//! walk. A request with `known` can answer `unchanged` with no walk: it sends the values past
//! their lifetime to the refresh ([`Mux::revalidate_git_heads`]), at a constant cost until the
//! first one is due.
//!
//! Why a long safety lifetime is kept: a watch can miss a change that matters. A network or FUSE
//! file system (NFS, SMB, sshfs) delivers no event for a write made on another machine; a
//! repository made between a directory and the git dir it is watched by (`git init` in a
//! subdirectory of a repository, a worktree's `.git` file rewritten) touches no watched file.
//! A queue overflow (inotify) or a dropped stream (FSEvents) is told as a rescan and invalidates
//! every value at once. A directory the watch could not hold (the kernel's watch limit, a
//! directory that does not exist) keeps the old 2 second lifetime ([`GIT_HEAD_TTL`]).
//!
//! The refresh is one worker thread for a session. It starts when a walk, a request with `known`
//! or the watch finds a value to read and ends when its queue is empty. A directory is in the
//! queue at most one time (`refreshing`). The worker first puts the watch on the directories of
//! its batch, then reads each of them with no lock held (a change after the watch is in place is
//! either in the read or invalidates it), and writes the value at the clock reading taken before
//! the read ([`TagCache::insert_at`]): an event that lands during the read leaves it stale, and
//! the worker reads it again. The first read of a directory in a walk happens before its watch,
//! so the worker reads it once more behind its new watch.
//!
//! A worker that panics ends the refresh ([`RefreshEnd`]); the next reply starts a new one.

#[cfg(target_os = "linux")]
mod quiet_watch;

#[cfg(test)]
use super::git_head_probe;
use super::{GitHead, decoration_walks::surface_directories_in_state, read_git_head_at};
use crate::SurfaceId;
use crate::mux::Mux;
use crate::panic_free::RecoverPoison;
use cmux_tag_cache::{Lookup, Stamp, TagCache};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

/// The lifetime of a value whose directory the watch does not hold: past it, the value goes to
/// the refresh (the lifetime of every value before the watch).
const GIT_HEAD_TTL: Duration = Duration::from_secs(2);
/// The lifetime of a value whose directory the watch holds: only for the changes a watch cannot
/// see (module docs).
const GIT_HEAD_SAFETY_TTL: Duration = Duration::from_secs(60);
const GIT_HEAD_CACHE_LIMIT: usize = 4096;
/// The watch gathers the events of one burst (git writes `HEAD.lock`, then renames it) and
/// sends the refresh once: it waits this long after an event for the next one...
const WATCH_QUIET: Duration = Duration::from_millis(20);
/// ...and no longer than this after the first.
const WATCH_BURST: Duration = Duration::from_millis(200);

/// What a cached HEAD was read from.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum HeadTag {
    /// The watched directory: the git dir of the HEAD file, or where a `.git` would go.
    Dir(PathBuf),
    /// Each value: the watch reported that it could have missed events.
    All,
}

#[derive(Clone)]
struct Cached {
    head: Option<GitHead>,
    /// The directory whose change can change the value ([`read_git_head_at`]).
    at: PathBuf,
    /// Whether the watch held `at` when the value was read.
    watched: bool,
}

impl Cached {
    fn lifetime(&self) -> Duration {
        if self.watched { GIT_HEAD_SAFETY_TTL } else { GIT_HEAD_TTL }
    }

    fn tags(&self) -> Vec<HeadTag> {
        if self.watched {
            vec![HeadTag::Dir(self.at.clone()), HeadTag::All]
        } else {
            vec![HeadTag::All]
        }
    }
}

/// The git HEAD lookups of a session, by directory.
pub(in crate::mux) struct GitHeadCache {
    inner: Mutex<Inner>,
    /// Lock order: `watch`, then `inner`.
    watch: Mutex<Option<HeadWatch>>,
    /// Whether the refresh puts the watch on the directories it reads (a test turns it off to
    /// count reads with no event).
    watching: AtomicBool,
}

impl Default for GitHeadCache {
    fn default() -> Self {
        Self { inner: Mutex::default(), watch: Mutex::new(None), watching: AtomicBool::new(true) }
    }
}

struct Inner {
    heads: TagCache<String, Cached, HeadTag>,
    /// When each cached directory was last read: the keys of `heads` (which never drops one on
    /// its own: it is emptied whole at the limit, below).
    checked: HashMap<String, Instant>,
    /// The cached directories of each watched directory.
    by_dir: HashMap<PathBuf, HashSet<String>>,
    /// The first time a cached value is past its lifetime; `None` when unknown.
    next_due: Option<Instant>,
    /// The directories that wait for the worker.
    queue: Vec<String>,
    /// In the queue, or read by the worker now.
    refreshing: HashSet<String>,
    /// Whether the worker runs (or starts): it ends only with an empty queue.
    worker_running: bool,
}

impl Default for Inner {
    fn default() -> Self {
        Self {
            // One more than the limit: `store` empties the cache at the limit, so the cache
            // never drops an entry `checked` and `by_dir` still name.
            heads: TagCache::new(GIT_HEAD_CACHE_LIMIT + 1),
            checked: HashMap::new(),
            by_dir: HashMap::new(),
            next_due: None,
            queue: Vec::new(),
            refreshing: HashSet::new(),
            worker_running: false,
        }
    }
}

impl Inner {
    /// The cached value of `cwd` and whether it must be read again (stale, or past its
    /// lifetime), or `None` with no cached value.
    fn lookup(&self, cwd: &str, now: Instant) -> Option<(Option<GitHead>, bool)> {
        let (cached, stale) = match self.heads.get(cwd) {
            Lookup::Fresh(cached) => (cached, false),
            Lookup::Stale(cached) => (cached, true),
            Lookup::Miss => return None,
        };
        let old = self
            .checked
            .get(cwd)
            .is_none_or(|checked| now.saturating_duration_since(*checked) >= cached.lifetime());
        Some((cached.head.clone(), stale || old))
    }

    /// Puts `cwd` in the refresh unless it is there.
    fn enqueue(&mut self, cwd: &str) {
        if self.refreshing.insert(cwd.to_string()) {
            self.queue.push(cwd.to_string());
        }
    }

    /// Stores a value read as of `written` (a stamp taken before the read). Whether the tree
    /// revision must move (tree_revision.rs): the directory had another value, or the full
    /// cache was emptied and forgot what a refresh could compare with.
    fn store(&mut self, cwd: &str, written: Stamp, checked: Instant, value: Cached) -> bool {
        let moved = match self.heads.get(cwd).value() {
            Some(previous) => {
                let moved = previous.head != value.head;
                if previous.watched
                    && let Some(cwds) = self.by_dir.get_mut(&previous.at)
                {
                    cwds.remove(cwd);
                    if cwds.is_empty() {
                        self.by_dir.remove(&previous.at);
                    }
                }
                moved
            }
            None if self.checked.len() >= GIT_HEAD_CACHE_LIMIT => {
                self.heads = TagCache::new(GIT_HEAD_CACHE_LIMIT + 1);
                self.checked.clear();
                self.by_dir.clear();
                self.next_due = None;
                true
            }
            None => false,
        };
        if value.watched {
            self.by_dir.entry(value.at.clone()).or_default().insert(cwd.to_string());
        }
        let due = checked + value.lifetime();
        self.next_due = Some(self.next_due.map_or(due, |next| next.min(due)));
        let kept = self.checked.entry(cwd.to_string()).or_insert(checked);
        *kept = (*kept).max(checked);
        let tags = value.tags();
        self.heads.insert_at(cwd.to_string(), value, tags, written);
        moved
    }

    /// Sends each cached value that must be read again to the refresh, and finds when the next
    /// one is due. A walk of every cached directory, made only once one is due.
    fn queue_due(&mut self, now: Instant) {
        if self.next_due.is_some_and(|due| now < due) {
            return;
        }
        let mut next_due: Option<Instant> = None;
        let mut due = Vec::new();
        for (cwd, checked) in &self.checked {
            let Some(cached) = self.heads.get(cwd.as_str()).value() else { continue };
            let at = *checked + cached.lifetime();
            if matches!(self.heads.get(cwd.as_str()), Lookup::Stale(_)) || now >= at {
                due.push(cwd.clone());
            } else {
                next_due = Some(next_due.map_or(at, |next| next.min(at)));
            }
        }
        for cwd in due {
            self.enqueue(&cwd);
        }
        // A directory in the refresh sets its next time when its new value is stored.
        self.next_due = next_due;
    }
}

/// The file watch over the watched directories (`HeadTag::Dir`), and its thread.
struct HeadWatch {
    watcher: DirWatch,
    dirs: HashSet<PathBuf>,
}

/// Linux: an inotify watch that asks for no opens ([`quiet_watch`]); elsewhere `notify`'s.
#[cfg(target_os = "linux")]
type DirWatch = quiet_watch::QuietWatch;
#[cfg(not(target_os = "linux"))]
type DirWatch = notify::RecommendedWatcher;

impl HeadWatch {
    /// A watcher whose events go to a thread that tells `mux`; `None` when the platform gives
    /// none (each value then keeps [`GIT_HEAD_TTL`]).
    fn start(mux: Weak<Mux>) -> Option<Self> {
        let (tx, rx) = std::sync::mpsc::channel();
        #[cfg(target_os = "linux")]
        let watcher = quiet_watch::QuietWatch::start(tx, "git-head-inotify")
            .inspect_err(|error| eprintln!("cmux-tui: the git HEAD watch cannot start: {error}"))
            .ok()?;
        #[cfg(not(target_os = "linux"))]
        let watcher = notify::recommended_watcher(move |event| {
            let _ = tx.send(event);
        })
        .inspect_err(|error| eprintln!("cmux-tui: the git HEAD watch cannot start: {error}"))
        .ok()?;
        std::thread::Builder::new()
            .name("git-head-watch".to_string())
            .spawn(move || run_watch(&rx, &mux))
            .inspect_err(|error| eprintln!("cmux-tui: the git HEAD watch cannot start: {error}"))
            .ok()?;
        Some(Self { watcher, dirs: HashSet::new() })
    }
}

/// What one burst of events touched.
#[derive(Default)]
struct Fired {
    dirs: HashSet<PathBuf>,
    /// An event could have been missed: every value is stale.
    all: bool,
}

impl Fired {
    fn add(&mut self, event: notify::Result<notify::Event>) {
        let event = match event {
            Ok(event) => event,
            // A watcher error may have dropped events.
            Err(_) => {
                self.all = true;
                return;
            }
        };
        // A read is no change: the refresh's own read would wake the watch again.
        if matches!(event.kind, notify::EventKind::Access(_)) {
            return;
        }
        if event.need_rescan() {
            self.all = true;
            return;
        }
        let removed = matches!(event.kind, notify::EventKind::Remove(_));
        for path in event.paths {
            let name = path.file_name();
            if name.is_some_and(|name| name == "HEAD" || name == ".git")
                && let Some(parent) = path.parent()
            {
                self.dirs.insert(parent.to_path_buf());
            }
            // A watched directory that went away.
            if removed {
                self.dirs.insert(path);
            }
        }
    }
}

/// The watch's thread: gathers each burst of events and tells `mux` once. Ends when the watcher
/// is dropped (with its session's cache) or the session is gone.
fn run_watch(rx: &Receiver<notify::Result<notify::Event>>, mux: &Weak<Mux>) {
    while let Ok(first) = rx.recv() {
        let started = Instant::now();
        let mut fired = Fired::default();
        fired.add(first);
        let mut closed = false;
        loop {
            let left = WATCH_BURST.saturating_sub(started.elapsed());
            if left.is_zero() {
                break;
            }
            match rx.recv_timeout(WATCH_QUIET.min(left)) {
                Ok(event) => fired.add(event),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    closed = true;
                    break;
                }
            }
        }
        if fired.all || !fired.dirs.is_empty() {
            let Some(mux) = mux.upgrade() else { return };
            mux.git_head_watch_fired(&fired);
        }
        if closed {
            return;
        }
    }
}

/// Lives as long as the worker thread. A worker that panics would leave `worker_running` set
/// and its directories `refreshing`, and no refresh would run again in the session: the drop
/// ends the refresh then, so the next reply starts a new worker.
struct RefreshEnd(Arc<GitHeadCache>);

impl Drop for RefreshEnd {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.0.give_up_refresh();
        }
        #[cfg(test)]
        git_head_probe::refresh_ended();
    }
}

impl GitHeadCache {
    fn watching(&self) -> bool {
        self.watching.load(Ordering::Relaxed)
    }

    /// Puts the watch on `wanted` (starting the watcher the first time) and takes it off each
    /// directory no cached value is read from now. The directories of `wanted` it holds.
    fn arm(&self, wanted: &HashSet<PathBuf>, mux: &Weak<Mux>) -> HashSet<PathBuf> {
        if !self.watching() || wanted.is_empty() {
            return HashSet::new();
        }
        let mut watch = self.watch.lock().recover_poison();
        if watch.is_none() {
            *watch = HeadWatch::start(mux.clone());
        }
        let Some(watch) = watch.as_mut() else { return HashSet::new() };
        let gone: Vec<PathBuf> = {
            let inner = self.inner.lock().recover_poison();
            watch
                .dirs
                .iter()
                .filter(|dir| !wanted.contains(*dir) && !inner.by_dir.contains_key(*dir))
                .cloned()
                .collect()
        };
        let new: Vec<&PathBuf> = wanted.iter().filter(|dir| !watch.dirs.contains(*dir)).collect();
        if !gone.is_empty() || !new.is_empty() {
            #[cfg(target_os = "linux")]
            let (added, committed) = {
                for dir in &gone {
                    watch.watcher.remove(dir);
                }
                let added: Vec<PathBuf> =
                    new.into_iter().filter(|dir| watch.watcher.add(dir).is_ok()).cloned().collect();
                (added, true)
            };
            // One change of the watch for the batch: FSEvents restarts its stream on each.
            #[cfg(not(target_os = "linux"))]
            let (added, committed) = {
                let mut paths = notify::Watcher::paths_mut(&mut watch.watcher);
                for dir in &gone {
                    let _ = paths.remove(dir);
                }
                let added: Vec<PathBuf> = new
                    .into_iter()
                    .filter(|dir| {
                        paths.add(dir.as_path(), notify::RecursiveMode::NonRecursive).is_ok()
                    })
                    .cloned()
                    .collect();
                (added, paths.commit().is_ok())
            };
            for dir in &gone {
                watch.dirs.remove(dir);
            }
            if committed {
                watch.dirs.extend(added);
            }
        }
        wanted.iter().filter(|dir| watch.dirs.contains(*dir)).cloned().collect()
    }

    /// The worker: puts the watch on each queued directory's repository, reads it, and tells
    /// `mux` the directories whose HEAD changed.
    fn run_refresh(&self, mux: &Weak<Mux>) {
        loop {
            let (batch, wanted) = {
                let mut inner = self.inner.lock().recover_poison();
                if inner.queue.is_empty() {
                    inner.worker_running = false;
                    return;
                }
                let batch = std::mem::take(&mut inner.queue);
                let wanted: HashSet<PathBuf> = batch
                    .iter()
                    .map(|cwd| {
                        inner
                            .heads
                            .get(cwd.as_str())
                            .value()
                            .map_or_else(|| PathBuf::from(cwd), |cached| cached.at.clone())
                    })
                    .collect();
                (batch, wanted)
            };
            let mut armed = self.arm(&wanted, mux);
            let mut changed = HashSet::new();
            for cwd in batch {
                let (mut stamp, mut read) = self.read(&cwd);
                // The repository is not the one the watch was put on (a first read, or one
                // that moved): watch it and read behind the watch.
                if self.watching() && !armed.contains(&read.1) {
                    armed.extend(self.arm(&HashSet::from([read.1.clone()]), mux));
                    if armed.contains(&read.1) {
                        (stamp, read) = self.read(&cwd);
                    }
                }
                let (head, at) = read;
                let watched = armed.contains(&at);
                let mut inner = self.inner.lock().recover_poison();
                inner.refreshing.remove(&cwd);
                // A cache that was emptied meanwhile has no value to compare with: the next
                // walk reads the directory.
                if !inner.checked.contains_key(&cwd) {
                    continue;
                }
                let value = Cached { head, at, watched };
                if inner.store(&cwd, stamp, Instant::now(), value) {
                    changed.insert(cwd.clone());
                }
                // An event that landed while it was read: read it again.
                if matches!(inner.heads.get(cwd.as_str()), Lookup::Stale(_)) {
                    inner.enqueue(&cwd);
                }
            }
            if !changed.is_empty()
                && let Some(mux) = mux.upgrade()
            {
                mux.emit_git_head_changes(&changed);
            }
        }
    }

    /// A stamp, then a read of `cwd` with no lock held.
    fn read(&self, cwd: &str) -> (Stamp, (Option<GitHead>, PathBuf)) {
        let stamp = self.inner.lock().recover_poison().heads.stamp();
        (stamp, read_git_head_at(Path::new(cwd)))
    }

    /// Takes each directory out of the refresh, when no worker runs (none can start, or it
    /// panicked): a later reply can queue each stale directory again.
    fn give_up_refresh(&self) {
        let mut inner = self.inner.lock().recover_poison();
        inner.worker_running = false;
        inner.queue.clear();
        inner.refreshing.clear();
        // The values that were queued are found again by the next sweep.
        inner.next_due = None;
    }
}

impl Mux {
    /// The git HEAD of `cwd` for a tree reply, from the cache whatever its state. With `read`, a
    /// directory that has no cached value is read here, and a value that must be read again
    /// (stale, or past its lifetime) goes to the refresh that [`Self::start_git_head_refresh`]
    /// starts. Without it (a caller that holds the state lock) the answer comes from the cache
    /// only.
    pub(super) fn git_head(&self, cwd: &str, now: Instant, read: bool) -> Option<GitHead> {
        let stamp = {
            let mut inner = self.git_heads.inner.lock().recover_poison();
            if let Some((head, again)) = inner.lookup(cwd, now) {
                if read && again {
                    inner.enqueue(cwd);
                }
                return head;
            }
            if !read {
                return None;
            }
            inner.heads.stamp()
        };
        let (head, at) = read_git_head_at(Path::new(cwd));
        let moved = {
            let mut inner = self.git_heads.inner.lock().recover_poison();
            let moved =
                inner.store(cwd, stamp, now, Cached { head: head.clone(), at, watched: false });
            // This read came before any watch: the refresh puts one on its repository and reads
            // it again behind it.
            if self.git_heads.watching() {
                inner.enqueue(cwd);
            }
            moved
        };
        if moved {
            self.tree_revision.bump();
        }
        head
    }

    /// For a `list-workspaces` request with `known`, which can answer `unchanged` with no walk
    /// of the tree (cmux#42895): sends each cached value past its lifetime to the refresh. No
    /// HEAD is read on the thread of the reply, and nothing is walked until the first value is
    /// due. A watched change went to the refresh when its event came; this sweep is for a
    /// directory the watch does not hold, and the safety lifetime of one it holds.
    pub(crate) fn revalidate_git_heads(&self) {
        self.git_heads.inner.lock().recover_poison().queue_due(Instant::now());
        self.start_git_head_refresh();
    }

    /// The watch saw a write of a HEAD file or a `.git` entry in `fired.dirs`, or could have
    /// missed one (`fired.all`): invalidates their tags and sends their cached directories to
    /// the refresh.
    fn git_head_watch_fired(&self, fired: &Fired) {
        {
            let mut inner = self.git_heads.inner.lock().recover_poison();
            let mut queued: Vec<String> = Vec::new();
            if fired.all {
                inner.heads.invalidate(HeadTag::All);
                queued.extend(inner.checked.keys().cloned());
            }
            for dir in &fired.dirs {
                let Some(cwds) = inner.by_dir.get(dir) else { continue };
                queued.extend(cwds.iter().cloned());
                inner.heads.invalidate(HeadTag::Dir(dir.clone()));
            }
            for cwd in queued {
                inner.enqueue(&cwd);
            }
        }
        self.start_git_head_refresh();
    }

    /// Starts the worker when directories wait and none runs.
    pub(super) fn start_git_head_refresh(&self) {
        {
            let mut inner = self.git_heads.inner.lock().recover_poison();
            if inner.worker_running || inner.queue.is_empty() {
                return;
            }
            inner.worker_running = true;
        }
        #[cfg(test)]
        git_head_probe::refresh_started();
        let cache = Arc::clone(&self.git_heads);
        // An owner that is not bound yet (construction) has no worker: its values stay as they
        // are, and the next reply asks again.
        let started = self.exit_settles.owner().is_some_and(|mux| {
            let mux = Arc::downgrade(&mux);
            std::thread::Builder::new()
                .name("git-head-refresh".to_string())
                .spawn(move || {
                    let end = RefreshEnd(cache);
                    end.0.run_refresh(&mux);
                })
                .inspect_err(|error| {
                    eprintln!("cmux-tui: could not start the git HEAD refresh worker: {error:#}");
                })
                .is_ok()
        });
        if !started {
            self.git_heads.give_up_refresh();
            #[cfg(test)]
            git_head_probe::refresh_ended();
        }
    }

    /// Counts the change in the tree revision (a branch switched with no change of directory
    /// has no event of its own, tree_revision.rs) and sends `tab-changed` for each placed tab
    /// whose directory is in `directories`. The cache has the new values before this call.
    fn emit_git_head_changes(&self, directories: &HashSet<String>) {
        self.tree_revision.bump();
        let surfaces: Vec<SurfaceId> = self.with_state(|state| {
            surface_directories_in_state(state)
                .into_iter()
                .filter(|(_, cwd)| directories.contains(cwd))
                .map(|(surface, _)| surface)
                .collect()
        });
        for surface in surfaces {
            self.emit_tab_changed(surface);
        }
    }

    /// Test seam: makes each cached git HEAD 3 seconds older (past [`GIT_HEAD_TTL`], the
    /// lifetime of a value the watch does not hold). Whether it could (a host that started less
    /// than that time ago has no older instant).
    #[cfg(test)]
    pub(crate) fn age_git_heads_for_test(&self) -> bool {
        let age = GIT_HEAD_TTL.saturating_add(Duration::from_secs(1));
        let mut inner = self.git_heads.inner.lock().recover_poison();
        let mut aged = true;
        for checked in inner.checked.values_mut() {
            match checked.checked_sub(age) {
                Some(older) => *checked = older,
                None => aged = false,
            }
        }
        inner.next_due = None;
        aged
    }

    /// Test seam: the refresh puts no watch on the directories it reads, so each value keeps
    /// [`GIT_HEAD_TTL`] and a write of a HEAD file reaches no client before it is past it (a
    /// test that counts reads with no event). Call before the first walk.
    #[cfg(test)]
    pub(crate) fn stop_git_head_watch_for_test(&self) {
        self.git_heads.watching.store(false, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests;
