//! The git HEAD of each tab directory, answered from memory.
//!
//! A tree read (a request) takes the HEAD it knows and never reads the
//! repository. A directory not read yet answers its nearest read ancestor's
//! HEAD (a `cd` inside a repository keeps its branch), and a missing or
//! stale HEAD starts one read on the mux's Files lane. Reads that find a
//! different HEAD than the one presented are coalesced: one flush item
//! sends every affected tab's `tab-changed` delta from one snapshot. This is
//! Chrome's answer-from-memory shape: the UI thread serves the in-memory
//! value and a `MayBlock` task refreshes it
//! (components/omnibox/browser/history_quick_provider.cc reads its in-memory
//! index; the disk work runs as a posted task). The daemon warms the cache
//! for restored tabs when it starts, as Chrome builds that index at profile
//! start (components/omnibox/browser/in_memory_url_index.cc).

use std::collections::HashSet;
use std::time::Instant;

use cmux_threads::work::{Lane, Priority, Shutdown};

use super::*;

/// A HEAD read is reused for this long, which bounds both the filesystem
/// work of tree reads and the staleness of a branch switch made without
/// changing directory.
const GIT_HEAD_TTL: Duration = Duration::from_secs(2);
const GIT_HEAD_CACHE_LIMIT: usize = 4096;

#[derive(Default)]
pub(crate) struct GitHeads {
    inner: Mutex<GitHeadsInner>,
    #[cfg(test)]
    read_finished: Condvar,
}

#[derive(Default)]
struct GitHeadsInner {
    entries: HashMap<String, GitHeadEntry>,
    /// Directories whose read found a HEAD other than the one presented,
    /// not yet flushed.
    changed: HashSet<String>,
    /// A flush item is queued.
    flush_queued: bool,
}

#[derive(Default)]
struct GitHeadEntry {
    /// The HEAD presented for this directory: the last read's, or before
    /// the first read the nearest read ancestor's.
    head: Option<GitHead>,
    /// When the last read finished; `None` before the first one.
    read_at: Option<Instant>,
    /// A read is queued or running.
    reading: bool,
}

impl GitHeadsInner {
    /// The HEAD of the nearest ancestor of `cwd` with an entry: the same
    /// repository unless a nested one sits between them.
    fn ancestor_head(&self, cwd: &str) -> Option<GitHead> {
        Path::new(cwd)
            .ancestors()
            .skip(1)
            .filter_map(Path::to_str)
            .find_map(|ancestor| self.entries.get(ancestor))
            .and_then(|entry| entry.head.clone())
    }

    /// Keeps the newer half of the finished reads and every read still out.
    fn evict_older_half(&mut self) {
        let mut finished: Vec<Instant> = self
            .entries
            .values()
            .filter(|entry| !entry.reading)
            .filter_map(|entry| entry.read_at)
            .collect();
        let cutoff = if finished.is_empty() {
            None
        } else {
            let middle = finished.len() / 2;
            Some(*finished.select_nth_unstable(middle).1)
        };
        self.entries.retain(|_, entry| {
            entry.reading
                || cutoff.is_some_and(|cutoff| entry.read_at.is_some_and(|at| at > cutoff))
        });
    }
}

impl GitHeads {
    /// The HEAD presented for `cwd`, and whether the caller must start a
    /// read: `refresh` asked for one and the entry is missing or older than
    /// [`GIT_HEAD_TTL`] with no read out. Never touches the disk.
    fn lookup(&self, cwd: &str, now: Instant, refresh: bool) -> (Option<GitHead>, bool) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(entry) = inner.entries.get_mut(cwd) {
            if !refresh {
                return (entry.head.clone(), false);
            }
            let fresh =
                entry.read_at.is_some_and(|at| now.saturating_duration_since(at) < GIT_HEAD_TTL);
            let start = !fresh && !entry.reading;
            entry.reading |= start;
            return (entry.head.clone(), start);
        }
        let head = inner.ancestor_head(cwd);
        if !refresh {
            return (head, false);
        }
        if inner.entries.len() >= GIT_HEAD_CACHE_LIMIT {
            inner.evict_older_half();
        }
        let entry = GitHeadEntry { head: head.clone(), read_at: None, reading: true };
        inner.entries.insert(cwd.to_owned(), entry);
        (head, true)
    }

    /// Records a finished read of `cwd`. Returns whether the caller must
    /// queue a flush: the HEAD differs from the one presented and no flush
    /// is queued yet.
    fn finish_read(&self, cwd: &str, head: Option<GitHead>, at: Instant) -> bool {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let entry = inner.entries.entry(cwd.to_owned()).or_default();
        let changed = entry.head != head;
        *entry = GitHeadEntry { head, read_at: Some(at), reading: false };
        #[cfg(test)]
        self.read_finished.notify_all();
        if !changed {
            return false;
        }
        inner.changed.insert(cwd.to_owned());
        !std::mem::replace(&mut inner.flush_queued, true)
    }

    /// A read that ended with no result (refused, dropped unrun, or its
    /// body panicked): the next lookup tries again.
    fn read_ended_without_result(&self, cwd: &str) {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(entry) = inner.entries.get_mut(cwd) {
            entry.reading = false;
        }
        #[cfg(test)]
        self.read_finished.notify_all();
    }

    /// The directories to flush; the next changed read queues a new flush.
    fn take_changed(&self) -> HashSet<String> {
        let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        inner.flush_queued = false;
        std::mem::take(&mut inner.changed)
    }

    /// Waits until a read of `cwd` has finished, at most `timeout`.
    #[cfg(test)]
    pub(crate) fn wait_read_for_test(&self, cwd: &str, timeout: Duration) -> bool {
        let inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        let (_inner, waited) = self
            .read_finished
            .wait_timeout_while(inner, timeout, |inner| {
                inner.entries.get(cwd).is_none_or(|entry| entry.read_at.is_none() || entry.reading)
            })
            .unwrap_or_else(PoisonError::into_inner);
        !waited.timed_out()
    }
}

/// Ends a posted read that never records a result: the job was dropped
/// before it ran (shutdown, a worker that could not start) or its body
/// panicked. Without it the entry would stay `reading` and never be read
/// again.
struct GitHeadRead {
    heads: Arc<GitHeads>,
    directory: String,
    finished: bool,
}

impl GitHeadRead {
    /// Reads the HEAD and records it; whether a flush must be queued.
    fn run(mut self) -> bool {
        let head = read_git_head(Path::new(&self.directory));
        self.finished = true;
        self.heads.finish_read(&self.directory, head, Instant::now())
    }
}

impl Drop for GitHeadRead {
    fn drop(&mut self) {
        if !self.finished {
            self.heads.read_ended_without_result(&self.directory);
        }
    }
}

impl Mux {
    /// The HEAD presented for `cwd`; a missing or stale one is read off
    /// this thread when `refresh` asks for it (see the module docs).
    pub(super) fn git_head(&self, cwd: &str, now: Instant, refresh: bool) -> Option<GitHead> {
        let (head, read) = self.git_heads.lookup(cwd, now, refresh);
        if read {
            self.read_git_head_off_thread(cwd);
        }
        head
    }

    /// Starts a read for every tab directory: the daemon start warms the
    /// cache, so the first tree read already knows the restored branches.
    pub(crate) fn warm_git_heads(&self) {
        let directories = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            surface_directories_in_state(&state)
        };
        let now = Instant::now();
        for (_, cwd) in directories {
            self.git_head(&cwd, now, true);
        }
    }

    fn read_git_head_off_thread(&self, cwd: &str) {
        // A refused post drops the read unrun, which ends it.
        let read = GitHeadRead {
            heads: self.git_heads.clone(),
            directory: cwd.to_owned(),
            finished: false,
        };
        let _ = self.post_mux_work(
            Priority::UserVisible,
            Lane::Files,
            Shutdown::SkipOnShutdown,
            move |mux| {
                if read.run()
                    && let Some(mux) = mux.upgrade()
                {
                    mux.queue_git_head_flush();
                }
            },
        );
    }

    /// Queues the flush on the Files lane, where it starts after the reads
    /// queued before it, so a burst of reads (a daemon start, many new
    /// directories) sends one update per flush, not one per read.
    fn queue_git_head_flush(&self) {
        let posted = self.post_mux_work(
            Priority::UserVisible,
            Lane::Files,
            Shutdown::SkipOnShutdown,
            |mux| {
                if let Some(mux) = mux.upgrade() {
                    mux.flush_git_heads();
                }
            },
        );
        if posted.is_err() {
            self.git_heads.take_changed();
        }
    }

    /// One `tab-changed` delta for each tab in a directory whose HEAD
    /// changed, all from one snapshot under one state lock.
    fn flush_git_heads(&self) {
        let changed = self.git_heads.take_changed();
        if changed.is_empty() {
            return;
        }
        let deltas = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let surfaces: Vec<SurfaceId> = surface_directories_in_state(&state)
                .into_iter()
                .filter(|(_, directory)| changed.contains(directory))
                .map(|(surface, _)| surface)
                .collect();
            if surfaces.is_empty() {
                return;
            }
            let decorations = self.tree_decorations_in_state(&state);
            surfaces
                .into_iter()
                .filter_map(|surface| tab_changed_delta(&state, &decorations, surface))
                .collect::<Vec<_>>()
        };
        for delta in deltas {
            self.emit(MuxEvent::TreeDelta(delta));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A read whose job is dropped before it runs, or whose body panics,
    /// ends with no result, and the next lookup starts a new read.
    #[test]
    fn a_read_that_never_records_a_result_is_started_again() {
        let heads = Arc::new(GitHeads::default());
        let now = Instant::now();
        assert_eq!(heads.lookup("/repo", now, true), (None, true));
        assert_eq!(heads.lookup("/repo", now, true), (None, false), "one read at a time");

        drop(GitHeadRead { heads: heads.clone(), directory: "/repo".into(), finished: false });
        assert_eq!(heads.lookup("/repo", now, true), (None, true));

        let panicked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _read =
                GitHeadRead { heads: heads.clone(), directory: "/repo".into(), finished: false };
            panic!("the read body panicked");
        }));
        assert!(panicked.is_err());
        assert_eq!(heads.lookup("/repo", now, true), (None, true));
    }

    /// Finished reads that change a HEAD queue one flush until it runs.
    #[test]
    fn changed_reads_queue_one_flush() {
        let heads = GitHeads::default();
        let now = Instant::now();
        let main = Some(GitHead { name: "main".into(), detached: false });
        heads.lookup("/a", now, true);
        heads.lookup("/b", now, true);
        heads.lookup("/c", now, true);
        assert!(heads.finish_read("/a", main.clone(), now), "the first change queues the flush");
        assert!(!heads.finish_read("/b", main.clone(), now), "a flush is already queued");
        assert!(!heads.finish_read("/c", None, now), "an unchanged HEAD flushes nothing");
        let changed = heads.take_changed();
        assert_eq!(changed, HashSet::from(["/a".to_owned(), "/b".to_owned()]));
        heads.lookup("/c", now + GIT_HEAD_TTL, true);
        assert!(heads.finish_read("/c", main, now), "after a flush the next change queues one");
    }
}
