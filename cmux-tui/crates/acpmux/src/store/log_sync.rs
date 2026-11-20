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
    pub(crate) static FAIL_DIR_SYNC_WHEN: DirSyncWhen = const { std::cell::RefCell::new(None) };
    /// Tests: the checkpoint's `sync_log` on this thread stops right after it cloned the open
    /// log, before its own sync of it.
    pub(crate) static HOLD_AFTER_LOG_CLONE: HoldSlot = const { std::cell::RefCell::new(None) };
    /// Tests: a log's close on this thread whose sync failed stops right before it notes the
    /// failure in `sync_failed`.
    pub(crate) static HOLD_BEFORE_CLOSE_NOTE: HoldSlot = const { std::cell::RefCell::new(None) };
    /// Tests: this thread says so, once, right before it waits for the syncs of the store's
    /// files under way on other threads (`SyncsUnderWay::wait_for_those_under_way`).
    pub(crate) static NOTE_BEFORE_SYNCS_WAIT: Note = const { std::cell::RefCell::new(None) };
    /// Tests: this thread says so, once, right before it takes the writers' lock to read the log
    /// closes' note (`LocalStore::close_sync_failed`).
    pub(crate) static NOTE_BEFORE_CLOSE_NOTE_READ: Note = const { std::cell::RefCell::new(None) };
}

/// Tests: a note a thread sends once, when it reaches a point of the code: a test knows from it
/// that the thread is at that point, with no timer.
#[cfg(test)]
pub(crate) type Note = std::cell::RefCell<Option<std::sync::mpsc::Sender<&'static str>>>;

/// Tests: sends `what` on the note in `slot`, if this thread has one, and drops the note.
#[cfg(test)]
pub(super) fn note(slot: &'static std::thread::LocalKey<Note>, what: &'static str) {
    if let Some(note) = slot.with(|note| note.borrow_mut().take()) {
        let _ = note.send(what);
    }
}

/// Tests: a stop on one thread: it says so on the first channel and waits for the second.
#[cfg(test)]
pub(crate) type HoldSlot =
    std::cell::RefCell<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>;

/// Tests: the stop in `slot`, if this thread has one.
#[cfg(test)]
pub(super) fn hold(slot: &'static std::thread::LocalKey<HoldSlot>) {
    if let Some((arrived, release)) = slot.with(|hold| hold.borrow_mut().take()) {
        let _ = arrived.send(());
        let _ = release.recv();
    }
}

/// Tests: a folder and the condition under which its next sync fails ([`FAIL_DIR_SYNC_WHEN`]).
#[cfg(test)]
pub(crate) type DirSyncWhen = std::cell::RefCell<Option<(std::path::PathBuf, fn(&Path) -> bool)>>;

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

/// Tests: the syncs that flush the drive's cache (on macOS every `sync_all`/`sync_data` is an
/// `F_FULLFSYNC`), counted.
#[cfg(test)]
pub(crate) static FULL_SYNCS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
#[cfg(test)]
thread_local! {
    /// Tests: every sync of a log segment, a folder or a store file, full or ordered, that this
    /// thread made (the open's own syncs, not those of the checkpointer's thread).
    pub(crate) static ALL_SYNCS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
fn counted(result: &std::io::Result<()>) {
    if result.is_ok() {
        ALL_SYNCS.with(|syncs| syncs.set(syncs.get().saturating_add(1)));
    }
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
    #[cfg(test)]
    counted(&result);
    #[cfg(test)]
    if result.is_ok() {
        FULL_SYNCS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
    #[cfg(all(test, unix))]
    super::sync_model::synced(file, result.is_ok());
    result
}

/// Syncs one log segment so that it survives a crash of any process and a kernel panic, in
/// write order with every other sync (macOS `F_BARRIERFSYNC`, which does not flush the drive's
/// cache; Linux `fdatasync`): the journal store's checkpoint and recovery, which then flush the
/// drive once with the checkpoint file ([`sync_full`]) before they retire any journal record.
/// The same test seams as [`sync_segment`].
pub(super) fn sync_segment_ordered(file: &File) -> std::io::Result<()> {
    #[cfg(test)]
    if FAIL_NEXT_LOG_SYNC.with(|fail| fail.replace(false)) {
        #[cfg(unix)]
        super::sync_model::synced(file, false);
        return Err(std::io::Error::other("a failed sync (a test)"));
    }
    let result = cmux_journal::sync_file(file, cmux_journal::SyncLevel::Barrier);
    #[cfg(test)]
    counted(&result);
    #[cfg(all(test, unix))]
    super::sync_model::synced(file, result.is_ok());
    result
}

/// [`sync_segment_ordered`] for a folder's entries; a failed sync is a [`SyncFailed`].
#[cfg(unix)]
pub(super) fn sync_directory_ordered(path: &Path) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    #[cfg(test)]
    if fail_dir_sync(path) {
        return Err(SyncFailed(std::io::Error::other("a failed folder sync (a test)")).into());
    }
    let dir = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)?;
    let result = cmux_journal::sync_file(&dir, cmux_journal::SyncLevel::Barrier);
    #[cfg(test)]
    counted(&result);
    result.map_err(SyncFailed)?;
    #[cfg(test)]
    super::sync_model::folder_synced(path);
    Ok(())
}

/// Windows has no folder sync: NTFS journals its folder changes.
#[cfg(not(unix))]
pub(super) fn sync_directory_ordered(_path: &Path) -> Result<()> {
    Ok(())
}

/// `sync_all` of a file or folder (the drive's cache flushed on macOS), counted in tests.
pub(super) fn sync_full(file: &File) -> std::io::Result<()> {
    let result = file.sync_all();
    #[cfg(test)]
    counted(&result);
    #[cfg(test)]
    if result.is_ok() {
        FULL_SYNCS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
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
    /// Whether a log's sync at its close failed (`SegmentWriter::close`). Read under the writers'
    /// lock, which every close holds from its sync to its note: a close whose sync failed before
    /// this call has noted it when this reads (review of #35895, finding 1).
    pub(super) fn close_sync_failed(&self) -> bool {
        #[cfg(test)]
        note(&NOTE_BEFORE_CLOSE_NOTE_READ, "takes the writers' lock");
        let _writers = self.writers.lock_or_recover();
        self.sync_failed.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Syncs `id`'s open log segment and its folders in write order ([`sync_segment_ordered`]),
    /// without holding the writers' lock while the disk works (the journal store's checkpoint,
    /// `store/journal_store.rs`, which flushes the drive once after every chat's). A segment that
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
            #[cfg(test)]
            hold(&HOLD_AFTER_LOG_CLONE);
            sync_segment_ordered(&file).map_err(SyncFailed)?;
        }
        let session = self.dir(id);
        sync_directory_ordered(&session.join("events"))?;
        sync_directory_ordered(&session)
    }
}
