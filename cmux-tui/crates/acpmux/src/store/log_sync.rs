//! A log's sync for the journal store's checkpoint, and the error of a failed `fsync` (moved out
//! of `store.rs`, which is over its size budget).

use super::*;

#[cfg(test)]
thread_local! {
    /// Tests: the next sync of a log segment on this thread ([`sync_segment`]) fails, as a failed
    /// fsync would.
    pub(crate) static FAIL_NEXT_LOG_SYNC: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Tests: the next sync of this folder on this thread (`sync_directory`) fails.
    pub(crate) static FAIL_DIR_SYNC: std::cell::RefCell<Option<std::path::PathBuf>> =
        const { std::cell::RefCell::new(None) };
    /// Tests: the next sync of this folder on this thread for which the test's condition holds
    /// (it reads the folder) fails: a test names a sync by the state it runs in, not by its rank,
    /// which differs between two versions of the code.
    pub(crate) static FAIL_DIR_SYNC_WHEN: std::cell::RefCell<Option<(std::path::PathBuf, fn(&Path) -> bool)>> =
        const { std::cell::RefCell::new(None) };
}

/// Tests: whether this sync of the folder at `path` fails ([`FAIL_DIR_SYNC`]).
#[cfg(test)]
pub(super) fn fail_dir_sync(path: &Path) -> bool {
    let plain = FAIL_DIR_SYNC.with(|fail| {
        let mut fail = fail.borrow_mut();
        let hit = fail.as_deref() == Some(path);
        if hit {
            *fail = None;
        }
        hit
    });
    plain
        || FAIL_DIR_SYNC_WHEN.with(|fail| {
            let mut fail = fail.borrow_mut();
            let hit = fail.as_ref().is_some_and(|(folder, when)| folder == path && when(path));
            if hit {
                *fail = None;
            }
            hit
        })
}

/// Syncs one log segment: its data, or with `all` its metadata too. The tests' crash model
/// follows each sync (`store/sync_model.rs`).
pub(super) fn sync_segment(file: &File, all: bool) -> std::io::Result<()> {
    #[cfg(test)]
    if FAIL_NEXT_LOG_SYNC.with(|fail| fail.replace(false)) {
        #[cfg(unix)]
        super::sync_model::synced(file, false);
        return Err(std::io::Error::other("a failed sync (a test)"));
    }
    let result = if all { file.sync_all() } else { file.sync_data() };
    #[cfg(all(test, unix))]
    super::sync_model::synced(file, result.is_ok());
    result
}

/// A sync call (`fsync`) that failed, as opposed to an error before it (a folder that does not
/// open): what it was to make durable may be lost, and a later sync of the same file may report
/// success without it (the journal store then keeps every line until a restart).
#[derive(Debug)]
pub(crate) struct SyncFailed(pub(crate) std::io::Error);

impl std::fmt::Display for SyncFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "sync failed: {}", self.0)
    }
}

impl std::error::Error for SyncFailed {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.0)
    }
}

impl LocalStore {
    /// Syncs `id`'s open log segment and its folders, without holding the writers' lock while
    /// the disk works (the journal store's checkpoint, `store/journal_store.rs`). A segment that
    /// is not open was synced at its close (`SegmentWriter::close`, which notes a failure).
    pub(super) fn sync_log(&self, id: &str) -> Result<()> {
        // Debug builds only: `ACPMUX_TEST_FAIL_LOG_SYNC` fails every log sync, as a disk whose
        // fsync fails would, so the daemon-level test (`tests/daemon_restart_close.rs`) can see
        // the stop for a restart. Release builds have no seam.
        #[cfg(debug_assertions)]
        if std::env::var_os("ACPMUX_TEST_FAIL_LOG_SYNC").is_some() {
            return Err(SyncFailed(std::io::Error::other(
                "a failed sync (ACPMUX_TEST_FAIL_LOG_SYNC)",
            ))
            .into());
        }
        let open = {
            let writers = self.writers.lock_or_recover();
            match writers.open.get(id) {
                Some(writer) => Some(writer.file.try_clone()?),
                None => None,
            }
        };
        if let Some(file) = open {
            sync_segment(&file, true).map_err(SyncFailed)?;
        }
        let session = self.dir(id);
        sync_directory(&session.join("events"))?;
        sync_directory(&session)
    }
}
