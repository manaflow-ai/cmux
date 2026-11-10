//! A test's own folder below `/tmp`, unique in this process.
//!
//! The tests of one file run in parallel in one process (`cargo test`
//! `--test-threads=2`), so two of them can ask for a folder at the same
//! moment. The pid and the wall clock alone gave two such tests one folder
//! (run 42648495910: two `new_terminal_first_text` tests shared one daemon,
//! and the first to end shut it down under the other). A counter of this
//! process makes each name unique, and the folder is made with
//! `create_dir`, which refuses one that exists, so a collision is never
//! silent.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Folders named by this process so far.
static NEXT: AtomicU64 = AtomicU64::new(0);

/// A new folder `/tmp/<prefix>-<pid>-<n>-<ns>`, made here.
pub fn new_test_dir(prefix: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = test_dir_at(prefix, stamp);
    create_new_dir(&dir).unwrap_or_else(|error| panic!("{}: {error}", dir.display()));
    dir
}

/// The name of the next folder for `prefix` at wall clock `stamp` (ns):
/// never one this process named before.
pub fn test_dir_at(prefix: &str, stamp: u128) -> PathBuf {
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    PathBuf::from("/tmp").join(format!("{prefix}-{}-{n}-{stamp}", std::process::id()))
}

/// Makes the folder `dir`; one that exists is an error.
pub fn create_new_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir(dir)
}
