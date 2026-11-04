//! A log's sync for the journal store's checkpoint, and the error of a failed `fsync` (moved out
//! of `store.rs`, which is over its size budget).

use super::*;

#[cfg(test)]
thread_local! {
    /// Tests: the next `LocalStore::sync_log` on this thread fails, as a failed fsync would.
    pub(crate) static FAIL_NEXT_LOG_SYNC: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
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
        #[cfg(test)]
        if FAIL_NEXT_LOG_SYNC.with(|fail| fail.replace(false)) {
            return Err(SyncFailed(std::io::Error::other("a failed sync (a test)")).into());
        }
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
            file.sync_all().map_err(SyncFailed)?;
        }
        let session = self.dir(id);
        sync_directory(&session.join("events"))?;
        sync_directory(&session)
    }
}
