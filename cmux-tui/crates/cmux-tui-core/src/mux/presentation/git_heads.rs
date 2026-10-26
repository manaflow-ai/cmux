//! The git HEAD of each tab directory, answered from memory.
//!
//! A tree read (a request) takes the HEAD it knows and never reads the
//! repository. A missing or stale HEAD starts one read on the mux's Files
//! lane; when the read finds a different HEAD, the tabs in that directory
//! get a `tab-changed` delta. This is Chrome's answer-from-memory shape: the
//! UI thread serves the cached value and a `MayBlock` task refreshes it
//! (components/omnibox/browser/history_quick_provider.cc reads its in-memory
//! index; the disk work runs as a posted task).

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
    entries: Mutex<HashMap<String, GitHeadEntry>>,
    #[cfg(test)]
    read_finished: Condvar,
}

#[derive(Default)]
struct GitHeadEntry {
    head: Option<GitHead>,
    /// When the last read finished; `None` before the first one.
    read_at: Option<Instant>,
    /// A read is queued or running.
    reading: bool,
}

impl GitHeads {
    /// The HEAD known for `cwd`, and whether the caller must start a read:
    /// `refresh` asked for one and the entry is missing or older than
    /// [`GIT_HEAD_TTL`] with no read out. Never touches the disk.
    fn lookup(&self, cwd: &str, now: Instant, refresh: bool) -> (Option<GitHead>, bool) {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        if !refresh {
            return (entries.get(cwd).and_then(|entry| entry.head.clone()), false);
        }
        if !entries.contains_key(cwd) && entries.len() >= GIT_HEAD_CACHE_LIMIT {
            entries.clear();
        }
        let entry = entries.entry(cwd.to_owned()).or_default();
        let fresh =
            entry.read_at.is_some_and(|at| now.saturating_duration_since(at) < GIT_HEAD_TTL);
        let start = !fresh && !entry.reading;
        entry.reading |= start;
        (entry.head.clone(), start)
    }

    /// Records a finished read of `cwd`; whether its HEAD changed.
    fn finish_read(&self, cwd: &str, head: Option<GitHead>, at: Instant) -> bool {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        let entry = entries.entry(cwd.to_owned()).or_default();
        let changed = entry.head != head;
        *entry = GitHeadEntry { head, read_at: Some(at), reading: false };
        #[cfg(test)]
        self.read_finished.notify_all();
        changed
    }

    /// A read that could not be queued: the next lookup tries again.
    fn read_refused(&self, cwd: &str) {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(entry) = entries.get_mut(cwd) {
            entry.reading = false;
        }
    }

    /// Waits until a read of `cwd` has finished, at most `timeout`.
    #[cfg(test)]
    pub(crate) fn wait_read_for_test(&self, cwd: &str, timeout: Duration) -> bool {
        let entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        let (_entries, waited) = self
            .read_finished
            .wait_timeout_while(entries, timeout, |entries| {
                entries.get(cwd).is_none_or(|entry| entry.read_at.is_none() || entry.reading)
            })
            .unwrap_or_else(PoisonError::into_inner);
        !waited.timed_out()
    }
}

impl Mux {
    /// The HEAD known for `cwd`; a missing or stale one is read off this
    /// thread when `refresh` asks for it (see the module docs).
    pub(super) fn git_head(&self, cwd: &str, now: Instant, refresh: bool) -> Option<GitHead> {
        let (head, read) = self.git_heads.lookup(cwd, now, refresh);
        if read {
            self.read_git_head_off_thread(cwd);
        }
        head
    }

    fn read_git_head_off_thread(&self, cwd: &str) {
        let directory = cwd.to_owned();
        let posted = self.work.post(
            Priority::UserVisible,
            Lane::Files,
            Shutdown::SkipOnShutdown,
            move |mux| {
                let head = read_git_head(Path::new(&directory));
                if mux.git_heads.finish_read(&directory, head, Instant::now()) {
                    mux.emit_git_head_changed(&directory);
                }
            },
        );
        if posted.is_err() {
            self.git_heads.read_refused(cwd);
        }
    }

    /// A `tab-changed` delta for each tab that presents `cwd`.
    fn emit_git_head_changed(&self, cwd: &str) {
        let surfaces: Vec<SurfaceId> = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            surface_directories_in_state(&state)
                .into_iter()
                .filter(|(_, directory)| directory == cwd)
                .map(|(surface, _)| surface)
                .collect()
        };
        for surface in surfaces {
            self.emit_tab_changed(surface);
        }
    }
}
