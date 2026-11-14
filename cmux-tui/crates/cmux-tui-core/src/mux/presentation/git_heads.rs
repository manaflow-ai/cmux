//! The git HEAD of each tab directory, cached.
//!
//! A tree reply names the branch of each terminal's directory. A read of a HEAD walks the file
//! system up to the repository, and a reply read each directory whose cached value was older
//! than [`GIT_HEAD_TTL`]: one walk for each terminal, on the thread of the reply. In a session of
//! some hundred terminals that was half of a `list-workspaces` reply's time.
//!
//! A reply now uses the cached value of a directory whatever its age. A value older than
//! [`GIT_HEAD_TTL`] goes to one background refresh, and the refresh sends `tab-changed` for the
//! tabs whose value changed, so a client that takes events gets the new branch. A stale value
//! has no age bound: it is served until its refresh ends. Only a directory with no cached value
//! is read in the reply, because a client that takes no event (a one-shot command) must find
//! its branches in its first reply.
//!
//! The refresh is one worker thread for a session. It starts when a reply finds a stale value
//! and ends when its queue is empty. A directory is in the queue at most one time
//! (`refreshing`), and only a directory that a reply asked for gets there, so requests that
//! come inside one refresh start no second one. The worker reads the file system with no lock
//! held; it takes the state lock only to find the tabs of a directory whose value changed.

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

    /// Takes each queued directory out of the refresh, when no worker can run.
    fn give_up_refresh(&self) {
        let mut cache = self.inner.lock().recover_poison();
        cache.worker_running = false;
        for cwd in std::mem::take(&mut cache.queue) {
            if let Some(entry) = cache.heads.get_mut(&cwd) {
                entry.refreshing = false;
            }
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
        let mut cache = self.git_heads.inner.lock().recover_poison();
        if cache.heads.len() >= GIT_HEAD_CACHE_LIMIT {
            cache.heads.clear();
        }
        cache
            .heads
            .insert(cwd.to_string(), Entry { checked: now, head: head.clone(), refreshing: false });
        head
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
                    cache.run_refresh(&mux);
                    #[cfg(test)]
                    git_head_probe::refresh_ended();
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

    /// Sends `tab-changed` for each placed tab whose directory is in `directories`.
    fn emit_git_head_changes(&self, directories: &HashSet<String>) {
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

    /// MEASURE BRANCH ONLY: forgets each cached git HEAD, so the next read of the tree reads the
    /// HEAD of each directory again.
    #[cfg(test)]
    pub(crate) fn forget_git_heads_for_measure(&self) {
        let mut cache = self.git_heads.inner.lock().recover_poison();
        cache.heads.clear();
        cache.queue.clear();
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
