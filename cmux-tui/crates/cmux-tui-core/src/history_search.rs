//! The history search index (`history-search-v1`): one SQLite file on this
//! Mac, never synced. A background worker fills it from the feeds the binary
//! installs, a bounded step at a time, so a large backlog never runs on the
//! daemon's main loop and a restart resumes from the feeds' cursors.
//! `history-search` reads on its own connection (WAL), so a query never
//! waits for indexing.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_history::{Backfill, SearchFeed, SearchHit, SearchIndex, SearchKind};

/// How hard the worker indexes: at most `budget` docs per feed step, `pause`
/// between steps while a backlog remains, `idle` between polls once every
/// feed has caught up.
#[derive(Clone, Copy, Debug)]
pub struct SearchPace {
    pub budget: usize,
    pub pause: Duration,
    pub idle: Duration,
}

impl Default for SearchPace {
    fn default() -> Self {
        Self { budget: 256, pause: Duration::from_millis(25), idle: Duration::from_secs(2) }
    }
}

/// A feed the worker owns.
pub type BoxedSearchFeed = Box<dyn SearchFeed + Send>;

pub struct HistorySearch {
    reader: Mutex<SearchIndex>,
    stop: Arc<AtomicBool>,
    /// The worker frees its own connection's page cache at its next turn
    /// ([`Self::release_memory`]).
    trim: Arc<AtomicBool>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl HistorySearch {
    /// Opens (or creates) the index at `path` and starts its worker.
    pub fn start(
        path: &Path,
        feeds: Vec<BoxedSearchFeed>,
        pace: SearchPace,
    ) -> anyhow::Result<Self> {
        let writer = SearchIndex::open(path)?;
        let reader = SearchIndex::open(path)?;
        let stop = Arc::new(AtomicBool::new(false));
        let trim = Arc::new(AtomicBool::new(false));
        let signals = Signals { stop: stop.clone(), trim: trim.clone() };
        let worker = std::thread::Builder::new()
            .name("history-search".into())
            .spawn(move || index_loop(writer, feeds, pace, &signals))?;
        Ok(Self { reader: Mutex::new(reader), stop, trim, worker: Mutex::new(Some(worker)) })
    }

    /// Frees both connections' unused page cache, each on its owner: the
    /// reader's here under its lock, the indexing worker's on the worker
    /// thread, which this wakes (`mux/sqlite_trim.rs`).
    pub(crate) fn release_memory(&self) -> anyhow::Result<()> {
        self.trim.store(true, Ordering::Release);
        if let Some(worker) = self.worker.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
            worker.thread().unpark();
        }
        let reader = self.reader.lock().unwrap_or_else(PoisonError::into_inner);
        Ok(reader.release_memory()?)
    }

    /// Newest first; every word must match. `kinds` empty: every kind.
    pub fn search(
        &self,
        query: &str,
        kinds: &[SearchKind],
        limit: usize,
    ) -> anyhow::Result<Vec<SearchHit>> {
        let reader = self.reader.lock().unwrap_or_else(PoisonError::into_inner);
        Ok(reader.search(query, kinds, limit)?)
    }
}

impl Drop for HistorySearch {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.lock().unwrap_or_else(PoisonError::into_inner).take() {
            worker.thread().unpark();
            let _ = worker.join();
        }
    }
}

/// What the owner asks of the indexing worker.
struct Signals {
    stop: Arc<AtomicBool>,
    trim: Arc<AtomicBool>,
}

fn index_loop(
    mut index: SearchIndex,
    feeds: Vec<BoxedSearchFeed>,
    pace: SearchPace,
    signals: &Signals,
) {
    while !signals.stop.load(Ordering::Relaxed) {
        let mut backlog = false;
        for feed in &feeds {
            match Backfill::step(&mut index, feed.as_ref(), pace.budget) {
                Ok(step) => backlog |= !step.done,
                Err(error) => eprintln!("cmux-tui: history search indexing failed: {error}"),
            }
        }
        // After the step, so the cache stays empty while the worker rests.
        if signals.trim.swap(false, Ordering::AcqRel)
            && let Err(error) = index.release_memory()
        {
            eprintln!("cmux-tui: history search page cache release failed: {error}");
        }
        rest(if backlog { pace.pause } else { pace.idle }, signals);
    }
}

/// Sleeps for `period`, waking early when the owner stops the worker or
/// asks it to free its page cache.
fn rest(period: Duration, signals: &Signals) {
    let deadline = Instant::now() + period;
    while !signals.stop.load(Ordering::Relaxed) && !signals.trim.load(Ordering::Acquire) {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        std::thread::park_timeout(left);
    }
}

#[cfg(test)]
mod tests {
    use cmux_history::{HistoryError, SearchDoc};

    use super::*;

    /// One source of `count` command docs.
    struct Docs(i64);

    impl SearchFeed for Docs {
        fn sources(&self) -> Result<Vec<String>, HistoryError> {
            Ok(vec!["shell:1".into()])
        }

        fn read(
            &self,
            _source: &str,
            after: Option<i64>,
            max: usize,
        ) -> Result<(Vec<SearchDoc>, i64), HistoryError> {
            let start = after.map_or(0, |after| after + 1);
            let end = (start + i64::try_from(max).unwrap_or(i64::MAX)).min(self.0);
            let docs = (start..end)
                .map(|i| SearchDoc {
                    key: format!("doc-{i}"),
                    source: "shell:1".into(),
                    kind: SearchKind::Command,
                    target: "terminal-1".into(),
                    position: Some(i),
                    title: "build".into(),
                    text: format!("cargo test --package number{i} {}", "x".repeat(100)),
                    at_ms: i,
                })
                .collect();
            Ok((docs, end.max(start) - 1))
        }
    }

    /// The reader frees its cache on the caller; the worker takes the
    /// request at its next turn, woken from its rest.
    #[test]
    fn sqlite_trim_history_search_frees_the_reader_and_wakes_the_worker() {
        let dir = std::env::temp_dir()
            .join(format!("cmux-history-search-trim-{}", crate::workspace_registry::new_uuid_v4()));
        let pace = SearchPace {
            budget: 4096,
            pause: Duration::from_millis(1),
            idle: Duration::from_secs(3600),
        };
        let search =
            HistorySearch::start(&dir.join("search.sqlite"), vec![Box::new(Docs(2000))], pace)
                .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while search.search("cargo test", &[], 2000).unwrap().len() < 2000 {
            assert!(Instant::now() < deadline, "the worker indexed the docs");
            std::thread::park_timeout(Duration::from_millis(5));
        }
        let cache = || search.reader.lock().unwrap().cache_used_bytes().unwrap();
        let filled = cache();
        assert!(filled > 64 * 1024, "the search filled {filled} bytes");

        search.release_memory().unwrap();
        let trimmed = cache();
        assert!(trimmed < 32 * 1024, "release left {trimmed} of {filled} bytes");
        // The worker rests for an hour; the request wakes it.
        while search.trim.load(Ordering::Acquire) {
            assert!(Instant::now() < deadline, "the worker took the release");
            std::thread::park_timeout(Duration::from_millis(5));
        }
        assert_eq!(search.search("number1999", &[], 10).unwrap().len(), 1);
        drop(search);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
