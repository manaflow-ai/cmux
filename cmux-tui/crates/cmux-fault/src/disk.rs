//! `disk-full` and slow fsync: a switch file a daemon's store reads in debug builds.
//!
//! The daemon under test is started with [`DiskFault::env`] (`ACPMUX_TEST_DISK_FAULT_FILE=<path>`);
//! its store's write layer reads the file before each write and each sync (acpmux:
//! `store.rs` `disk_fault`). The file holds one line:
//!
//! - `enospc` / `edquot`: every write fails as a full disk or a spent quota does;
//! - `slow-fsync <ms>`: every sync takes that much longer;
//! - absent: the disk is healthy again.
//!
//! A file instead of a size-capped mount needs no root, and the scenario flips it from outside the
//! daemon's process at any step.

use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::trace::Trace;

/// The variable the daemon's store reads the switch file's path from.
pub const ENV: &str = "ACPMUX_TEST_DISK_FAULT_FILE";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Full {
    /// ENOSPC: no space left on the device.
    NoSpace,
    /// EDQUOT: the user's quota is spent.
    Quota,
}

pub struct DiskFault {
    path: PathBuf,
    trace: Trace,
}

impl DiskFault {
    /// A switch in `dir` (the scenario's own temp dir), the disk healthy.
    pub fn new(dir: &Path, trace: &Trace) -> Self {
        let path = dir.join("disk-fault");
        let _ = std::fs::remove_file(&path);
        Self { path, trace: trace.clone() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The daemon's environment entry.
    pub fn env(&self) -> (&'static str, &Path) {
        (ENV, &self.path)
    }

    fn set(&self, line: &str) -> std::io::Result<()> {
        // Written whole and renamed, so the daemon never reads half a line.
        let staged = self.path.with_extension("next");
        std::fs::write(&staged, line)?;
        std::fs::rename(&staged, &self.path)
    }

    pub fn fill(&self, full: Full) -> std::io::Result<()> {
        self.trace.note(format!("fault disk-full {full:?}"));
        self.set(match full {
            Full::NoSpace => "enospc",
            Full::Quota => "edquot",
        })
    }

    pub fn slow_fsync(&self, by: Duration) -> std::io::Result<()> {
        self.trace.note(format!("fault slow-fsync {} ms", by.as_millis()));
        self.set(&format!("slow-fsync {}", by.as_millis()))
    }

    /// Space returns (and syncs are fast again).
    pub fn free(&self) {
        self.trace.note("heal disk");
        let _ = std::fs::remove_file(&self.path);
    }
}

impl Drop for DiskFault {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
