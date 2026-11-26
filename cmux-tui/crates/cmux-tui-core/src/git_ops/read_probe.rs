//! Test hooks of the slow git reads behind `git.files.list`, `git.files.search`,
//! `git.status` and `git.branches`: how many times each ran for a folder, and a
//! delay a test puts in front of one so it can tell an answer that waited for
//! the read from one that did not (`read_cache_tests`).
//!
//! Counted per folder, so tests that run at once in one process each see
//! only their own repositories.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

/// The read a count or a delay is of.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) enum Read {
    /// `git ls-files` of a repository's names, by the repository's top folder.
    Listing,
    /// `git.status`'s reads of the refs, by the folder asked about.
    Status,
    /// `git.branches`'s reads of the refs, by the folder asked about.
    Branches,
}

#[derive(Default)]
struct Probe {
    counts: HashMap<(Read, PathBuf), usize>,
    delays: HashMap<(Read, PathBuf), Duration>,
}

static PROBE: Mutex<Option<Probe>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut Probe) -> R) -> R {
    let mut probe = PROBE.lock().unwrap_or_else(PoisonError::into_inner);
    f(probe.get_or_insert_with(Probe::default))
}

/// Counts one `read` of `at`, and waits the delay a test set for it.
pub(super) fn ran(read: Read, at: &Path) {
    let delay = with(|probe| {
        *probe.counts.entry((read, at.to_path_buf())).or_default() += 1;
        probe.delays.get(&(read, at.to_path_buf())).copied()
    });
    if let Some(delay) = delay {
        std::thread::sleep(delay);
    }
}

/// How many times `read` of `at` ran.
pub(super) fn count(read: Read, at: &Path) -> usize {
    with(|probe| probe.counts.get(&(read, at.to_path_buf())).copied().unwrap_or(0))
}

/// Makes each later `read` of `at` take `delay` more.
pub(super) fn slow(read: Read, at: &Path, delay: Duration) {
    with(|probe| probe.delays.insert((read, at.to_path_buf()), delay));
}
