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
        let worker_stop = stop.clone();
        let worker = std::thread::Builder::new()
            .name("history-search".into())
            .spawn(move || index_loop(writer, feeds, pace, &worker_stop))?;
        Ok(Self { reader: Mutex::new(reader), stop, worker: Mutex::new(Some(worker)) })
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

fn index_loop(
    mut index: SearchIndex,
    feeds: Vec<BoxedSearchFeed>,
    pace: SearchPace,
    stop: &AtomicBool,
) {
    let _ = (&mut index, feeds, pace, stop, Backfill::step);
}

/// Sleeps for `period`, waking early when `stop` is set.
fn rest(period: Duration, stop: &AtomicBool) {
    let deadline = Instant::now() + period;
    while !stop.load(Ordering::Relaxed) {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        std::thread::park_timeout(left);
    }
}
