//! Test seam of the git HEAD reads: how many reads a thread made, how many refreshes run, and a
//! watch that counts the reads below one directory and can hold each of them. A test asserts
//! these counts, so a loaded host does not change its result.

use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

/// A held read goes on by itself after this time, so a test that fails leaves no thread behind.
const HOLD_LIMIT: Duration = Duration::from_secs(5);

thread_local! {
    static READS: Cell<u64> = const { Cell::new(0) };
}

struct Watch {
    root: PathBuf,
    held: bool,
    reads: u64,
}

static WATCH: Mutex<Option<Watch>> = Mutex::new(None);
static RELEASED: Condvar = Condvar::new();
static REFRESHES: AtomicUsize = AtomicUsize::new(0);

/// The git HEAD reads that this thread has made.
pub(super) fn reads_on_this_thread() -> u64 {
    READS.with(Cell::get)
}

/// Counts from zero the reads of a directory below `root`, on each thread, and holds each of
/// them while `held`. A second call for the same root keeps the count.
pub(super) fn watch_reads_below(root: &Path, held: bool) {
    let mut watch = WATCH.lock().unwrap_or_else(PoisonError::into_inner);
    let reads =
        watch.as_ref().filter(|watch| watch.root.as_path() == root).map_or(0, |watch| watch.reads);
    *watch = Some(Watch { root: root.to_path_buf(), held, reads });
    RELEASED.notify_all();
}

/// The reads below the watched directory since its watch began.
pub(super) fn watched_reads() -> u64 {
    WATCH.lock().unwrap_or_else(PoisonError::into_inner).as_ref().map_or(0, |watch| watch.reads)
}

/// The background refreshes that run now, in each session of this process.
pub(super) fn refreshes_running() -> usize {
    REFRESHES.load(Ordering::SeqCst)
}

/// A background refresh starts: called before its thread starts, so a test that waits for no
/// running refresh sees one from the reply that asked for it.
pub(super) fn refresh_started() {
    REFRESHES.fetch_add(1, Ordering::SeqCst);
}

pub(super) fn refresh_ended() {
    REFRESHES.fetch_sub(1, Ordering::SeqCst);
}

/// Called by each git HEAD read before it touches the file system.
pub(super) fn on_read(directory: &Path) {
    READS.with(|reads| reads.set(reads.get().saturating_add(1)));
    let mut watch = WATCH.lock().unwrap_or_else(PoisonError::into_inner);
    match watch.as_mut() {
        Some(watch) if directory.starts_with(&watch.root) => {
            watch.reads = watch.reads.saturating_add(1);
        }
        _ => return,
    }
    let deadline = Instant::now() + HOLD_LIMIT;
    while watch.as_ref().is_some_and(|watch| watch.held && directory.starts_with(&watch.root)) {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return;
        }
        watch = RELEASED.wait_timeout(watch, left).unwrap_or_else(PoisonError::into_inner).0;
    }
}

/// The seams as a test calls them.
impl crate::mux::Mux {
    /// The git HEAD reads that this thread has made.
    pub(crate) fn git_head_reads_on_this_thread() -> u64 {
        reads_on_this_thread()
    }

    /// Counts from zero the git HEAD reads of a directory below `root`, on each thread, and
    /// holds each of them while `held`.
    pub(crate) fn watch_git_head_reads_below(root: &Path, held: bool) {
        watch_reads_below(root, held);
    }

    /// The git HEAD reads below the watched directory.
    pub(crate) fn watched_git_head_reads() -> u64 {
        watched_reads()
    }

    /// The background refreshes of git HEADs that run now.
    pub(crate) fn git_head_refreshes_running() -> usize {
        refreshes_running()
    }
}
