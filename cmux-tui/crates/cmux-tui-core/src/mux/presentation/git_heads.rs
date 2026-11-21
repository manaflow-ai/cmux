//! The git HEAD of each tab directory, cached.
//!
//! A tree reply names the branch of each terminal's directory. A read of a HEAD walks the file
//! system up to the repository, and a reply read each directory whose cached value was older
//! than [`GIT_HEAD_TTL`]: one walk for each terminal, on the thread of the reply. In a session of
//! some hundred terminals that was half of a `list-workspaces` reply's time.
//!
//! A walk of the tree now uses the cached value of a directory whatever its age. A value older
//! than [`GIT_HEAD_TTL`] goes to one background refresh. Whoever finds a changed value first
//! (the refresh, or a request that reads its stale directories itself) stores it, moves the tree
//! revision and sends `tab-changed` for the tabs of that directory, so a client that takes
//! events gets the new branch. A directory with no cached value is read in the walk.
//!
//! Who gets a value of which age:
//!
//! - A `list-workspaces` request with no `known` comes from a client that holds no tree (a
//!   command that prints the tree one time): its reply is all that it gets. Before its tree is
//!   read, the request reads each stale directory that a tab shows, on its own thread
//!   ([`Mux::read_stale_git_heads`]), as each reply did before the refresh existed. Its reply
//!   has no value older than [`GIT_HEAD_TTL`] plus the time of its own reads. The refresh finds
//!   no change after it, so the request sends the `tab-changed` of a branch that it found.
//! - A request with `known` comes from a client that asks again: it gets the cached value, and
//!   its stale directories go to the refresh (below).
//! - Each other walk (the delta of a mutation, the launch snapshot, the cloud replica) gets the
//!   cached value and sends its stale directories to the refresh.
//!
//! The refresh is one worker thread for a session. It starts when a walk or a request with
//! `known` finds a stale value and ends when its queue is empty. A directory is in the queue at
//! most one time (`refreshing`), so requests that come inside one refresh start no second one.
//! It gets there from a walk that asked for it, or from a request with `known` (below). The
//! worker reads the file system with no lock held; it takes the state lock only for a directory
//! whose value changed: one time to find its tabs and 2 short times for each `tab-changed`.
//!
//! A worker that panics ends the refresh ([`RefreshEnd`]); the next reply starts a new one.
//!
//! A request with `known` can answer `unchanged` and read no tree, so it asks for no directory.
//! It sends each stale directory of the cache to the same refresh
//! ([`Mux::revalidate_git_heads`]): a branch switched with no event then moves the tree revision
//! for the client's next request.

#[cfg(test)]
use super::git_head_probe;
use super::{GitHead, decoration_walks::surface_directories_in_state, read_git_head};
use crate::SurfaceId;
use crate::mux::Mux;
use crate::panic_free::RecoverPoison;
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

/// A cached HEAD older than this goes to the background refresh, which bounds the staleness of
/// a branch switch made without a change of directory for a client that asks again.
const GIT_HEAD_TTL: Duration = Duration::from_secs(2);
const GIT_HEAD_CACHE_LIMIT: usize = 4096;

/// The git HEAD lookups of a session, by directory.
#[derive(Default)]
pub(in crate::mux) struct GitHeadCache {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    heads: HashMap<String, Entry>,
    /// The directories whose stale value waits for the worker.
    queue: Vec<String>,
    /// Whether the worker runs (or starts): it ends only with an empty queue.
    worker_running: bool,
}

struct Entry {
    checked: Instant,
    head: Option<GitHead>,
    /// In the queue, or read by the worker now.
    refreshing: bool,
}

impl Inner {
    /// Stores the value that a reply read: for a directory that had none when the reply
    /// looked, or for a stale one ([`Mux::read_stale_git_heads`]). Whether the tree revision
    /// must move (tree_revision.rs): the directory had another value, or the full cache was
    /// emptied and forgot what a refresh could compare with.
    fn store_read(&mut self, cwd: &str, now: Instant, head: Option<GitHead>) -> bool {
        if let Some(entry) = self.heads.get_mut(cwd) {
            let moved = entry.head != head;
            entry.head = head;
            entry.checked = entry.checked.max(now);
            return moved;
        }
        let cleared = self.heads.len() >= GIT_HEAD_CACHE_LIMIT;
        if cleared {
            self.heads.clear();
        }
        self.heads.insert(cwd.to_string(), Entry { checked: now, head, refreshing: false });
        cleared
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
    /// The worker: reads each queued directory, and tells `mux` the directories whose HEAD
    /// changed.
    fn run_refresh(&self, mux: &Weak<Mux>) {
        loop {
            let batch = {
                let mut cache = self.inner.lock().recover_poison();
                if cache.queue.is_empty() {
                    cache.worker_running = false;
                    return;
                }
                std::mem::take(&mut cache.queue)
            };
            let mut changed = HashSet::new();
            for cwd in batch {
                // No lock is held while the file system is read.
                let head = read_git_head(Path::new(&cwd));
                let mut cache = self.inner.lock().recover_poison();
                // A cache that was emptied meanwhile has no value to compare with: the next
                // reply reads the directory.
                let Some(entry) = cache.heads.get_mut(&cwd) else { continue };
                entry.refreshing = false;
                entry.checked = Instant::now();
                if entry.head != head {
                    entry.head = head;
                    drop(cache);
                    changed.insert(cwd);
                }
            }
            if !changed.is_empty()
                && let Some(mux) = mux.upgrade()
            {
                mux.emit_git_head_changes(&changed);
            }
        }
    }

    /// Takes each directory out of the refresh, when no worker runs (none can start, or it
    /// panicked): a later reply can queue each stale directory again.
    fn give_up_refresh(&self) {
        let mut cache = self.inner.lock().recover_poison();
        cache.worker_running = false;
        cache.queue.clear();
        for entry in cache.heads.values_mut() {
            entry.refreshing = false;
        }
    }
}

impl Mux {
    /// The git HEAD of `cwd` for a tree reply. With `read`, a directory that has no cached
    /// value is read here, and a value older than [`GIT_HEAD_TTL`] is queued for the refresh
    /// that [`Self::start_git_head_refresh`] starts. Without it (a caller that holds the state
    /// lock) the answer comes from the cache only.
    pub(super) fn git_head(&self, cwd: &str, now: Instant, read: bool) -> Option<GitHead> {
        {
            let mut cache = self.git_heads.inner.lock().recover_poison();
            let cache = &mut *cache;
            if let Some(entry) = cache.heads.get_mut(cwd) {
                if read
                    && !entry.refreshing
                    && now.saturating_duration_since(entry.checked) >= GIT_HEAD_TTL
                {
                    entry.refreshing = true;
                    cache.queue.push(cwd.to_string());
                }
                return entry.head.clone();
            }
        }
        if !read {
            return None;
        }
        let head = read_git_head(Path::new(cwd));
        let moved = self.git_heads.inner.lock().recover_poison().store_read(cwd, now, head.clone());
        if moved {
            self.tree_revision.bump();
        }
        head
    }

    /// For a `list-workspaces` request with `known`, which can answer `unchanged` with no read
    /// of the tree (cmux#42895): sends each cached directory whose value is older than
    /// [`GIT_HEAD_TTL`] to the refresh. No HEAD is read on the thread of the reply. A branch
    /// switched with no event moves the tree revision when the refresh reads it, so the request
    /// that comes after the refresh gets the whole tree; the request that queued the directory
    /// can still answer `unchanged`. The cache holds the directories that a tree showed.
    pub(crate) fn revalidate_git_heads(&self) {
        let now = Instant::now();
        {
            let mut cache = self.git_heads.inner.lock().recover_poison();
            let cache = &mut *cache;
            for (cwd, entry) in &mut cache.heads {
                if !entry.refreshing && now.saturating_duration_since(entry.checked) >= GIT_HEAD_TTL
                {
                    entry.refreshing = true;
                    cache.queue.push(cwd.clone());
                }
            }
        }
        self.start_git_head_refresh();
    }

    /// For a `list-workspaces` request with no `known`, before it reads its tree: reads, on the
    /// thread of the request, the HEAD of each directory that a tab shows and whose cached
    /// value is older than [`GIT_HEAD_TTL`]. The client of such a request holds no tree and asks
    /// no second time, so the refresh would come too late for it: a branch switched with no
    /// event must be in this reply. The tree that the request reads next finds these values
    /// fresh and queues none of them for the refresh; a value that got older than
    /// [`GIT_HEAD_TTL`] while the request worked goes to the refresh, as in each other walk.
    ///
    /// A HEAD that changed is stored here, so the refresh would find the file system equal to
    /// the cache and tell no client. The request tells them itself, as the refresh does: it
    /// moves the tree revision and sends `tab-changed` for the tabs of that directory.
    ///
    /// The cache also holds directories that no tab shows now; none of them is read here. The
    /// state lock is taken one time to find the directories of the tabs, and only when the
    /// cache has a stale value. When a HEAD changed, it is taken one time more to find the tabs
    /// of that directory, and 2 short times for each `tab-changed`.
    pub(crate) fn read_stale_git_heads(&self) {
        let now = Instant::now();
        let stale: HashSet<String> = {
            let cache = self.git_heads.inner.lock().recover_poison();
            cache
                .heads
                .iter()
                .filter(|(_, entry)| now.saturating_duration_since(entry.checked) >= GIT_HEAD_TTL)
                .map(|(cwd, _)| cwd.clone())
                .collect()
        };
        if stale.is_empty() {
            return;
        }
        let shown: HashSet<String> = self.with_state(|state| {
            surface_directories_in_state(state)
                .into_iter()
                .map(|(_, cwd)| cwd)
                .filter(|cwd| stale.contains(cwd))
                .collect()
        });
        let mut changed = HashSet::new();
        for cwd in shown {
            // Another request, or the refresh, can have read this directory since the list
            // above was made: it is not read a second time. Two requests that come to one
            // directory inside the time of one read still both read it.
            let fresh = |entry: &Entry| entry.checked.elapsed() < GIT_HEAD_TTL;
            if self.git_heads.inner.lock().recover_poison().heads.get(&cwd).is_none_or(fresh) {
                continue;
            }
            // No lock is held while the file system is read.
            let head = read_git_head(Path::new(&cwd));
            let moved =
                self.git_heads.inner.lock().recover_poison().store_read(&cwd, Instant::now(), head);
            if moved {
                changed.insert(cwd);
            }
        }
        if !changed.is_empty() {
            self.emit_git_head_changes(&changed);
        }
    }

    /// Starts the worker when stale directories wait and none runs.
    pub(super) fn start_git_head_refresh(&self) {
        {
            let mut cache = self.git_heads.inner.lock().recover_poison();
            if cache.worker_running || cache.queue.is_empty() {
                return;
            }
            cache.worker_running = true;
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

    /// Test seam: makes each cached git HEAD older than [`GIT_HEAD_TTL`]. Whether it could (a
    /// host that started less than that time ago has no older instant).
    #[cfg(test)]
    pub(crate) fn age_git_heads_for_test(&self) -> bool {
        let age = GIT_HEAD_TTL.saturating_add(Duration::from_secs(1));
        let mut cache = self.git_heads.inner.lock().recover_poison();
        let mut aged = true;
        for entry in cache.heads.values_mut() {
            match entry.checked.checked_sub(age) {
                Some(older) => entry.checked = older,
                None => aged = false,
            }
        }
        aged
    }
}

#[cfg(test)]
mod tests;
