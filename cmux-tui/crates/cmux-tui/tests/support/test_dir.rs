//! A test's own folder below `/tmp`.
//!
//! The tests of one file run in parallel in one process (`cargo test`
//! `--test-threads=2`), so two of them can ask for a folder at the same
//! moment.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A new folder `/tmp/<prefix>-<pid>-<ns>`, made here.
pub fn new_test_dir(prefix: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = test_dir_at(prefix, stamp);
    create_new_dir(&dir).unwrap_or_else(|error| panic!("{}: {error}", dir.display()));
    dir
}

/// The name of the next folder for `prefix` at wall clock `stamp` (ns).
pub fn test_dir_at(prefix: &str, stamp: u128) -> PathBuf {
    PathBuf::from("/tmp").join(format!("{prefix}-{}-{stamp}", std::process::id()))
}

/// Makes the folder `dir`.
pub fn create_new_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)
}
