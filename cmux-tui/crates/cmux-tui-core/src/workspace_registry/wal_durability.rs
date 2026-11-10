//! SQLite durability off the request path: one syncer thread per database
//! runs its WAL checkpoints and flushes it at close (PL-daemon).
//!
//! The daemon's databases (the workspace registry, the conversation store,
//! the chief registry) run in WAL mode with `synchronous=NORMAL`: a commit's
//! frames are in the WAL file, in the kernel's page cache, when `COMMIT`
//! returns. That survives a crash, kill or restart of the daemon. Only a
//! power loss or kernel panic can take an acknowledged commit back, and such
//! a loss also ends every terminal, host and shell the commit described.
//!
//! So no request waits for the disk, and none for a checkpoint. SQLite's WAL
//! hook runs on the committing thread right after a commit's frames are
//! written and counts it. Once a request's reply is out (the server's reply funnel), or a
//! background journal batch committed, the caller hands the commits to this
//! syncer. During the run the WAL reaches the disk the way SQLite's
//! `synchronous=NORMAL` defines it: at its checkpoint (SQLite syncs the WAL
//! before copying it), which the syncer runs once the WAL is large, and
//! through the kernel's own write-back; at close the syncer issues one
//! F_FULLFSYNC. No per-request sync: measured on one fleet mini (40 rounds,
//! 50 background workspaces), an F_FULLFSYNC after each reply made the next
//! request wait for it (new browser tab 4.2 -> 22-25 ms p50), and even an
//! F_BARRIERFSYNC after each reply cost the next request 5-7 ms.
//!
//! Installing the WAL hook also turns off SQLite's automatic checkpoint,
//! which ran on whichever request crossed 1000 WAL pages: it copied the WAL
//! into the database and synced it inside the committing request. The
//! syncer runs that checkpoint instead, on its own connection, once the
//! commits wrote [`CHECKPOINT_BYTES`] of frames since the last checkpoint
//! that copied the whole WAL; a PASSIVE checkpoint never blocks a writer.
//! The WAL file's size does not decide: after a cut the file stays at its
//! limit, and a checkpoint at each answered request would follow.
//!
//! A PASSIVE checkpoint never shrinks the WAL file, and while a reader holds
//! an old snapshot it cannot catch up, so the file grows with every commit
//! and stays at that size (one registry's WAL reached 15.7 GB). So every
//! connection runs `journal_size_limit` ([`WAL_SIZE_LIMIT_BYTES`]): once a
//! PASSIVE checkpoint copied the whole WAL and no reader still needs it, the
//! next commit restarts the WAL from its first frame and SQLite cuts the file
//! back to the limit. No TRUNCATE or RESTART checkpoint: either holds the
//! writer lock while it waits for readers, and a request's transaction that
//! read first then fails its write with SQLITE_BUSY at once (the busy
//! timeout does not cover that upgrade).
//!
//! A checkpoint that runs beside commits never ends with the whole WAL
//! copied: a commit landed while it copied. So under commits with no pause (a
//! session build, a restore, an agent burst) the WAL never restarted, and one
//! registry's WAL grew to 1366 MB beside a 45 MB database. A restart needs
//! one moment with no commit. The restart rule: the syncer thread makes that
//! moment, and no commit and no request waits for a checkpoint. The WAL hook
//! of a commit that finds [`RESTART_BYTES`] of frames in the WAL only marks a
//! restart owed. The syncer then ([`restart_the_wal`]):
//!
//! 1. copies the bulk beside the commits with PASSIVE checkpoints and syncs
//!    the database file itself, with no lock, until the commits that landed
//!    meanwhile are under [`TAIL_BYTES`] (at most [`BULK_PASSES`] passes:
//!    each copies what landed during the pass before);
//! 2. takes the database's writer lock ([`WriterLock`]: the registry's
//!    connection lock, a store's own lock) and runs one more PASSIVE
//!    checkpoint. No commit can land, so it copies the whole WAL: the few
//!    commits since the bulk, one sync of their WAL frames and one sync of
//!    the database pages they changed;
//! 3. releases the lock. The next commit restarts the WAL from its first
//!    frame.
//!
//! Other writers of that database wait only for step 2. The syncer holds no
//! other lock in it, and a thread that holds the mux state lock took the
//! connection lock before (lock order), so no reader of the state waits
//! behind it. The restart point is a quarter of the size limit, because
//! commits go on while the syncer works on step 1 (a storm on one workspace
//! wrote 34 MiB per second on a fleet M4 Pro). Nothing but the lock of
//! step 2 holds commits back, so the file's bound is not a hard one: it
//! holds while the passes over the bulk end before commits write the rest
//! of the limit (more than 1 s of that storm). Commits faster than that
//! grow the file until a try ends.
//!
//! A try can end with no restart. The syncer then tries again once commits
//! wrote [`CHECKPOINT_BYTES`] more; nobody waits, and the file grows by what
//! commits write until one try ends:
//!
//! - A reader that holds a snapshot stops the bulk at its mark (PASSIVE
//!   waits for no one). The try ends there and takes no lock.
//! - The writer lock does not come free in [`RESTART_WAIT`] (a flow that
//!   holds it for long).
//! - A reader of the old WAL is still open at the next commit: SQLite then
//!   appends to the WAL instead of a restart.
//!
//! A slow disk makes a try long: the next try waits for the bulk, and a
//! writer waits for the copy of the tail, which runs under its lock.
//!
//! A checkpoint that copied a WAL at its restart point to the end it had,
//! while commits appended beside it, leaves the WAL unable to restart (a
//! long read that ended, a WAL a kill left). The syncer does not wait for
//! 4 MiB of new commits then: the rest is due at once, as a try of the
//! restart rule, or as one more plain pass for a store that gave no lock.
//!
//! Before, the commit that took the WAL past the limit waited for the
//! syncer's checkpoint (at most 250 ms) with its connection lock held, and a
//! request thread also with the registry lock: a person's split or new tab
//! beside a storm waited behind that checkpoint. SQLite's own automatic
//! checkpoint (which Chromium keeps: 1000 pages, on the committing
//! connection) copies on the committing thread; Chromium commits on a
//! background sequence, cmux on request threads, so here the copy has its
//! own thread and the writers are kept out only for the tail.
//!
//! A WAL a previous run left (a kill in a storm, an older build) is
//! checkpointed by the syncer when the database opens, with no caller that
//! asks; commits do not wait for that one. cmux never deletes the WAL file
//! (SQLite itself removes it when the last connection closes cleanly).
//! The open itself copies nothing of it: the registry's open path runs with
//! `wal_autocheckpoint=0`, and the open of a registry at the current schema
//! commits 2 frames whatever the session's size, so the start does not
//! follow the size of the WAL.
//! A clean stop ends with one more PASSIVE checkpoint
//! ([`WalDurability::checkpoint_at_stop`]): PASSIVE, because request threads
//! and readers can still run then, and it waits for none of them. The next
//! start then finds every commit in the database file and a WAL at or under
//! the limit that its first commit restarts.
//!
//! Before, each registry commit ran `synchronous=FULL` with `fullfsync`
//! while it held the registry connection lock: about 4.5 ms per commit on a
//! fleet M4 Pro, one to three of them on every create and close reply, and
//! every other request that needed the lock waited behind them.
//!
//! The thread sleeps on a condition variable while nothing is owed (no
//! timer, no wakeups at idle).

use std::cell::RefCell;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use rusqlite::Connection;

use crate::panic_free::RecoverPoison;

/// WAL size past which the syncer checkpoints (SQLite's own default is
/// 1000 pages of 4 KiB).
const CHECKPOINT_BYTES: u64 = 4 * 1024 * 1024;

/// Each WAL frame is a 24-byte frame header and one page.
const WAL_FRAME_HEADER_BYTES: u64 = 24;

/// The WAL file size SQLite cuts the file back to when the WAL restarts
/// (`journal_size_limit`).
pub(crate) const WAL_SIZE_LIMIT_BYTES: u64 = 64 * 1024 * 1024;

/// WAL frame bytes at which the syncer tries to restart the WAL (module
/// docs): a quarter of the size limit. The rest is the room for what commits
/// write during one try.
const RESTART_BYTES: u64 = WAL_SIZE_LIMIT_BYTES / 4;

/// The bulk of a restart is copied when the commits that landed during the
/// last pass are under this: the rest is the tail, copied under the writer
/// lock.
const TAIL_BYTES: u64 = 1024 * 1024;

/// The most passes over the bulk in one try. Each pass copies what landed
/// during the pass before, so each is shorter; under commits faster than the
/// copy the tail stays larger and the try goes on with it.
const BULK_PASSES: usize = 3;

/// The longest the syncer waits for the writer lock of a restart, and the
/// longest the clean stop waits for its checkpoint. No request waits in
/// either. A holder of the writer lock releases it after each commit or
/// flow, so the lock normally comes in under a millisecond; the limit is for
/// a flow that holds it for long: the try ends and the next one comes
/// [`CHECKPOINT_BYTES`] later.
const RESTART_WAIT: Duration = Duration::from_millis(250);

/// [`RESTART_WAIT`] for a database attached in this crate's unit tests:
/// long, so a try always ends with its checkpoint and a test's byte bound
/// does not depend on the load of its host.
const TEST_RESTART_WAIT: Duration = Duration::from_secs(60);

/// The lock under which every commit of one database runs: the registry's
/// connection lock, a store's own lock. The syncer takes it for the tail of
/// a restart (module docs). An implementation holds its lock WEAK: the
/// connection's commit hook owns the syncer's state, so a strong hold from
/// there to the lock around the connection would be a cycle, and the flush
/// at close would never run.
pub(crate) trait WriterLock: Send + Sync {
    /// Run `tail` while no other thread can commit. Waits for the lock at
    /// most until `deadline`. False when the lock did not come or is gone.
    fn exclude_commits(&self, deadline: Instant, tail: &mut dyn FnMut()) -> bool;
}

/// A store behind a `std` mutex (the conversation store, the chief
/// registry). That mutex has no wait with a deadline, so the syncer waits
/// until its holder releases it: one store operation.
impl<T: Send> WriterLock for std::sync::Weak<Mutex<T>> {
    fn exclude_commits(&self, _deadline: Instant, tail: &mut dyn FnMut()) -> bool {
        let Some(lock) = self.upgrade() else { return false };
        let guard = lock.lock().recover_poison();
        tail();
        drop(guard);
        true
    }
}

/// Commit counters shared with the syncer thread.
#[derive(Default)]
struct SyncState {
    /// Commits written to the WAL.
    committed: u64,
    /// Commits known to be on disk.
    synced: u64,
    /// Commits a caller announced ([`WalDurability::request_flush`]).
    requested: u64,
    /// Announced commits the syncer has looked at (checkpointed or not).
    handled: u64,
    /// Commits a caller must see on disk ([`WalDurability::wait_durable`]).
    forced: u64,
    /// The database closed: the thread flushes what is owed and ends.
    stopping: bool,
    /// Frames in the WAL after the last commit (the WAL hook's page count).
    wal_frames: u64,
    /// Bytes of the WAL frames the commits appended (`server-stats` `write_path.registry_wal_frame_bytes`).
    wal_frame_bytes: u64,
    /// [`Self::wal_frame_bytes`] when the last checkpoint that copied the whole WAL started.
    copied_frame_bytes: u64,
    /// The largest WAL file size seen since the database opened (`server-stats`
    /// `write_path.registry_wal_file_high_water_bytes`).
    wal_file_high_water: u64,
    /// Checkpoints the clean stop asked for ([`WalDurability::checkpoint_at_stop`]).
    stop_asked: u64,
    /// Of those, the ones the syncer ended.
    stop_done: u64,
    /// A commit found the WAL at its restart point: the syncer owes one try
    /// ([`restart_the_wal`]).
    restart_owed: bool,
    /// The syncer runs that try now.
    restart_running: bool,
    /// The WAL frame count from which a commit marks the next try; 0 after a restart.
    restart_try_frames: u64,
    /// The WAL a previous run left is large, or a pass that copied a large
    /// WAL left the commits that came beside it: the syncer checkpoints next,
    /// whatever the commits wrote.
    leftover_owed: bool,
    /// Tries of the restart rule the syncer ended.
    #[cfg(test)]
    restart_tries: u64,
    /// Each span in which the restart rule kept the database's writer lock
    /// from other threads (start, end).
    #[cfg(test)]
    restart_holds: Vec<(Instant, Instant)>,
    /// Checkpoints the syncer ran, and the announced commits its ended
    /// passes had looked at.
    #[cfg(test)]
    checkpoints: u64,
    #[cfg(test)]
    settled: u64,
}

struct Shared {
    database_path: PathBuf,
    wal_path: PathBuf,
    state: Mutex<SyncState>,
    changed: Condvar,
    /// `CMUX_TUI_DEBUG_SLOW_DURABLE_COMMIT_MS`: each flush takes this much
    /// longer, as on a busy disk.
    slow_flush: Option<Duration>,
    /// Flush after every commit (a store with no request funnel), instead
    /// of only when asked.
    flush_each_commit: bool,
    /// `CMUX_TUI_TEST_REGISTRY_COMMIT_DELAY_MS`: each commit takes this much
    /// longer inside `COMMIT`, holding the write lock, as on a slow disk.
    commit_delay: Option<Duration>,
    /// Bytes of one WAL frame: its header and one page.
    frame_bytes: u64,
    /// The longest the syncer waits for the writer lock, and the clean stop
    /// for its checkpoint ([`RESTART_WAIT`]).
    restart_wait: Duration,
    /// The lock under which this database's commits run
    /// ([`WalDurability::own_restart`]). Without one there is no restart rule.
    writer_lock: OnceLock<Box<dyn WriterLock>>,
    /// Test seam ([`WalDurability::slow_restart_bulk`]), in milliseconds.
    #[cfg(test)]
    slow_restart_bulk_ms: std::sync::atomic::AtomicU64,
}

thread_local! {
    /// The syncer of the commit in progress on this thread: the commit hook
    /// sets it before SQLite writes the frames, the WAL hook takes it after.
    static COMMITTING: RefCell<Option<Arc<Shared>>> = const { RefCell::new(None) };
}

/// A view of one database's syncer (see the module docs): its commit
/// counts. The syncer itself lives as long as the connection: the commit
/// hook owns it, so closing the connection flushes what is owed and ends the
/// thread, with no field for the store to keep.
pub(crate) struct WalDurability {
    shared: Arc<Shared>,
}

/// Owned by the connection's commit hook; dropped when the connection
/// closes (daemon shutdown).
struct SyncerOwner(Arc<Shared>);

impl Drop for SyncerOwner {
    /// Flush what is owed on this thread, so a clean exit never leaves a
    /// commit only in the page cache, and end the syncer thread.
    fn drop(&mut self) {
        let owed = {
            let mut state = self.0.state.lock().recover_poison();
            state.stopping = true;
            state.synced < state.committed
        };
        self.0.changed.notify_all();
        if owed {
            sync_wal(&self.0, true);
        }
    }
}

/// [`WalDurability::attach`] for a store at `database_path`, with the
/// `CMUX_TUI_DEBUG_SLOW_DURABLE_COMMIT_MS` seam. A later
/// `PRAGMA wal_autocheckpoint` on the connection would replace its WAL hook.
pub(crate) fn attach_store(connection: &Connection, database_path: &Path) -> WalDurability {
    let delay = super::registry_connection::slow_durable_commit_delay();
    WalDurability::attach(connection, database_path, delay, true)
}

impl WalDurability {
    /// Install the hooks on `connection` (the database at `database_path`,
    /// in WAL mode) and start its syncer thread. The commit hook also keeps
    /// the debug span mark (`debug_spans::traced`), which it replaces.
    /// `flush_each_commit`: flush after every commit; else only when a
    /// caller asks ([`Self::request_flush`]), so a request's several commits
    /// share one flush and none of them waits behind a flush of an earlier
    /// one (an F_FULLFSYNC holds the file, so a WAL write that lands during
    /// it waits for it).
    pub(crate) fn attach(
        connection: &Connection,
        database_path: &Path,
        slow_flush: Option<Duration>,
        flush_each_commit: bool,
    ) -> Self {
        Self::attach_with_commit_delay(
            connection,
            database_path,
            slow_flush,
            flush_each_commit,
            None,
        )
    }

    /// [`Self::attach`] whose commits each wait `commit_delay` inside
    /// `COMMIT` (the registry's `CMUX_TUI_TEST_REGISTRY_COMMIT_DELAY_MS` seam).
    pub(crate) fn attach_with_commit_delay(
        connection: &Connection,
        database_path: &Path,
        slow_flush: Option<Duration>,
        flush_each_commit: bool,
        commit_delay: Option<Duration>,
    ) -> Self {
        let mut wal_path = database_path.as_os_str().to_owned();
        wal_path.push("-wal");
        // A WAL database keeps its page size (SQLite changes it only when the journal is not WAL).
        let page_size = connection
            .query_row("PRAGMA page_size", [], |row| row.get::<_, i64>(0))
            .ok()
            .and_then(|size| u64::try_from(size).ok())
            .unwrap_or(4096);
        // The writer cuts the WAL file back to this size whenever the WAL
        // restarts from its first frame (module docs).
        if let Err(error) = connection.execute_batch(&journal_size_limit_pragma()) {
            eprintln!("cmux-tui: SQLite journal_size_limit failed: {error}");
        }
        let wal_path = PathBuf::from(wal_path);
        // A large WAL from a previous run: the syncer checkpoints it at
        // once, before any caller asks (module docs).
        let leftover = std::fs::metadata(&wal_path).map_or(0, |meta| meta.len());
        let shared = Arc::new(Shared {
            database_path: database_path.to_path_buf(),
            wal_path,
            state: Mutex::new(SyncState {
                leftover_owed: leftover > CHECKPOINT_BYTES,
                wal_file_high_water: leftover,
                ..SyncState::default()
            }),
            changed: Condvar::new(),
            slow_flush,
            flush_each_commit,
            commit_delay,
            frame_bytes: page_size + WAL_FRAME_HEADER_BYTES,
            restart_wait: if cfg!(test) { TEST_RESTART_WAIT } else { RESTART_WAIT },
            writer_lock: OnceLock::new(),
            #[cfg(test)]
            slow_restart_bulk_ms: std::sync::atomic::AtomicU64::new(0),
        });
        let owner = SyncerOwner(shared.clone());
        let _ = connection.commit_hook(Some(move || {
            crate::debug_spans::mark("sqlite.commit");
            if let Some(delay) = owner.0.commit_delay {
                std::thread::sleep(delay);
            }
            COMMITTING.with(|committing| *committing.borrow_mut() = Some(owner.0.clone()));
            false
        }));
        connection.wal_hook(Some(|_, frames| {
            if let Some(shared) = COMMITTING.with(|committing| committing.borrow_mut().take()) {
                note_commit(&shared, frames);
            }
            Ok(())
        }));
        let thread_shared = shared.clone();
        let spawned = std::thread::Builder::new()
            .name("sqlite-wal-sync".into())
            .spawn(move || run(&thread_shared));
        if let Err(error) = spawned {
            // Without the thread, commits stay crash safe (WAL+NORMAL) but
            // are flushed only at close; say so once.
            eprintln!("cmux-tui: SQLite WAL syncer did not start: {error}");
            shared.state.lock().recover_poison().stopping = true;
        }
        Self { shared }
    }

    /// Give the syncer the lock under which every commit of this database
    /// runs, so it can restart the WAL under commits with no pause (module
    /// docs). Call it once, when the lock around the connection exists.
    pub(crate) fn own_restart(&self, writer_lock: impl WriterLock + 'static) {
        if self.shared.writer_lock.set(Box::new(writer_lock)).is_err() {
            eprintln!("cmux-tui: the WAL syncer already has its writer lock");
        }
    }

    /// Wait until every commit made before this call is on disk.
    #[cfg(test)]
    pub(crate) fn wait_durable(&self) {
        let mut state = self.shared.state.lock().recover_poison();
        let target = state.committed;
        state.forced = state.forced.max(target);
        self.shared.changed.notify_all();
        while state.synced < target && !state.stopping {
            state = self.shared.changed.wait(state).recover_poison();
        }
    }

    /// Commits made and no caller has asked to flush yet: an idle daemon
    /// leaves them in the WAL until a request flushes it.
    #[cfg(test)]
    pub(crate) fn unrequested_commits(&self) -> u64 {
        let state = self.shared.state.lock().recover_poison();
        state.committed.saturating_sub(state.requested)
    }

    /// Flush every commit made so far, soon, on the syncer thread. Callers
    /// ask once their request is answered (the server's reply funnel) or
    /// once a background batch committed (the journal writer).
    pub(crate) fn request_flush(&self) {
        request_flush(&self.shared);
    }

    /// One PASSIVE checkpoint on the syncer thread now, whatever the WAL's
    /// size, for a clean stop (module docs). Waits for its end, at most
    /// [`RESTART_WAIT`]; never for a reader or a writer.
    pub(crate) fn checkpoint_at_stop(&self) {
        let state = self.shared.state.lock().recover_poison();
        if state.stopping || state.committed == 0 {
            return;
        }
        drop(checkpoint_and_wait(&self.shared, state));
    }

    /// Tries of the restart rule the syncer ended.
    #[cfg(test)]
    pub(crate) fn restart_tries(&self) -> u64 {
        self.shared.state.lock().recover_poison().restart_tries
    }

    /// The checkpoints the syncer ran, read once it ended the pass for the
    /// last flush request (or 10 s passed).
    #[cfg(test)]
    pub(crate) fn checkpoints_once_idle(&self) -> u64 {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let state = self.shared.state.lock().recover_poison();
            let idle = state.settled >= state.requested
                && !state.restart_owed
                && !state.restart_running
                && !state.leftover_owed;
            if idle || Instant::now() > deadline {
                return state.checkpoints;
            }
            drop(state);
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    /// The spans in which the restart rule kept the writer lock from other threads.
    #[cfg(test)]
    pub(crate) fn restart_holds(&self) -> Vec<(Instant, Instant)> {
        self.shared.state.lock().recover_poison().restart_holds.clone()
    }

    /// Test seam: the copy of the WAL's bulk for each restart takes `delay`
    /// longer, as the copy of a large WAL on a busy disk does.
    #[cfg(test)]
    pub(crate) fn slow_restart_bulk(&self, delay: Duration) {
        let ms = u64::try_from(delay.as_millis()).unwrap_or(u64::MAX);
        self.shared.slow_restart_bulk_ms.store(ms, std::sync::atomic::Ordering::Release);
    }

    /// (committed, synced) commit counts, for `server-stats` `write_path`.
    pub(crate) fn counts(&self) -> (u64, u64) {
        let state = self.shared.state.lock().recover_poison();
        (state.committed, state.synced)
    }

    /// Bytes of the WAL frames the commits appended since the database opened, for `server-stats`
    /// `write_path.registry_wal_frame_bytes`: the bytes a write puts on the disk (the checkpoint later copies
    /// each page once more into the database). The first commit also counts the frames a previous run left in
    /// the WAL, so a reader takes the difference of two reads.
    pub(crate) fn wal_frame_bytes(&self) -> u64 {
        self.shared.state.lock().recover_poison().wal_frame_bytes
    }

    /// (size now, largest size seen since the database opened) of the WAL
    /// file, for `server-stats` `write_path.registry_wal_file_bytes` and
    /// `registry_wal_file_high_water_bytes`. A missing WAL is 0 bytes.
    pub(crate) fn wal_file_bytes(&self) -> (u64, u64) {
        let size = wal_file_len(&self.shared);
        (size, self.shared.state.lock().recover_poison().wal_file_high_water)
    }
}

/// The WAL file's size, noted in its high-water mark.
fn wal_file_len(shared: &Shared) -> u64 {
    let size = std::fs::metadata(&shared.wal_path).map_or(0, |meta| meta.len());
    let mut state = shared.state.lock().recover_poison();
    state.wal_file_high_water = state.wal_file_high_water.max(size);
    size
}

fn journal_size_limit_pragma() -> String {
    format!("PRAGMA journal_size_limit={WAL_SIZE_LIMIT_BYTES};")
}

/// One commit; `frames` is the WAL's frame count after it (the WAL hook's argument).
fn note_commit(shared: &Arc<Shared>, frames: std::ffi::c_int) {
    let mut state = shared.state.lock().recover_poison();
    state.committed += 1;
    let frames = u64::try_from(frames).unwrap_or(0);
    // A smaller count: the WAL restarted from its first frame (a checkpoint had copied all of it), so every
    // frame is new. A restart whose first commit writes more frames than the WAL held before counts only the
    // difference; the syncer checkpoints at 4 MiB (about 1000 frames), far above one commit.
    let appended = frames.checked_sub(state.wal_frames).unwrap_or(frames);
    if frames < state.wal_frames {
        state.restart_try_frames = 0;
    }
    state.wal_frames = frames;
    state.wal_frame_bytes =
        state.wal_frame_bytes.saturating_add(appended.saturating_mul(shared.frame_bytes));
    let mut wake = shared.flush_each_commit;
    if shared.flush_each_commit {
        state.requested = state.committed;
    }
    // The restart rule (module docs): mark the try owed and go on. The
    // syncer makes it; this thread never waits.
    if frames.saturating_mul(shared.frame_bytes) >= RESTART_BYTES
        && frames >= state.restart_try_frames
        && !state.restart_owed
        && !state.restart_running
        && !state.stopping
        && shared.writer_lock.get().is_some()
    {
        state.restart_owed = true;
        wake = true;
    }
    drop(state);
    if wake {
        shared.changed.notify_all();
    }
}

/// Ask the syncer for one PASSIVE checkpoint, whatever the WAL's size, and
/// wait for its end, at most the database's wait limit ([`RESTART_WAIT`]):
/// the clean stop. Returns whether it ended.
fn checkpoint_and_wait<'a>(
    shared: &'a Shared,
    mut state: MutexGuard<'a, SyncState>,
) -> (MutexGuard<'a, SyncState>, bool) {
    state.stop_asked += 1;
    let ask = state.stop_asked;
    shared.changed.notify_all();
    let started = Instant::now();
    let mut waited = Duration::ZERO;
    while state.stop_done < ask && !state.stopping && waited < shared.restart_wait {
        state = shared.changed.wait_timeout(state, shared.restart_wait - waited).recover_poison().0;
        waited = started.elapsed();
    }
    let ended = state.stop_done >= ask;
    (state, ended)
}

fn request_flush(shared: &Shared) {
    let mut state = shared.state.lock().recover_poison();
    if state.requested < state.committed {
        state.requested = state.committed;
        drop(state);
        shared.changed.notify_all();
    }
}

fn run(shared: &Shared) {
    let mut checkpointer: Option<Connection> = None;
    let mut state = shared.state.lock().recover_poison();
    loop {
        while state.requested <= state.handled
            && state.forced <= state.synced
            && state.stop_asked <= state.stop_done
            && !state.leftover_owed
            && !state.restart_owed
            && !state.stopping
        {
            state = shared.changed.wait(state).recover_poison();
        }
        if state.stopping && state.committed <= state.synced {
            return;
        }
        let force = state.stopping || state.forced > state.synced;
        let target = if force { state.committed } else { state.requested };
        state.handled = state.handled.max(state.requested);
        // The clean stop waits for this checkpoint, or a previous run left a
        // large WAL, or a restart is owed: checkpoint whatever the size.
        let asked = state.stop_asked;
        let leftover = std::mem::take(&mut state.leftover_owed);
        let restart = std::mem::take(&mut state.restart_owed) && !state.stopping;
        state.restart_running = restart;
        let owed = !state.stopping && (leftover || restart || asked > state.stop_done);
        // Else a checkpoint is due by what the commits wrote since the last
        // one that copied the whole WAL, never by the file's size.
        let mark = state.wal_frame_bytes;
        let due =
            owed || (!force && mark.saturating_sub(state.copied_frame_bytes) > CHECKPOINT_BYTES);
        drop(state);
        // A forced flush syncs the WAL; otherwise the WAL reaches the disk
        // with its checkpoint (SQLite syncs it first), or at close.
        let mut synced = force;
        if force {
            flush(shared);
        }
        let pass = if restart {
            restart_the_wal(shared, &mut checkpointer)
        } else {
            checkpoint_if_due(shared, &mut checkpointer, due)
        };
        synced |= pass.ran;
        state = shared.state.lock().recover_poison();
        if pass.whole {
            state.copied_frame_bytes = state.copied_frame_bytes.max(mark);
        }
        #[cfg(test)]
        {
            state.checkpoints += u64::from(pass.ran);
            state.settled = state.handled;
            state.restart_tries += u64::from(restart);
        }
        if restart {
            // The next commit restarts the WAL (its frame count falls, and
            // this point with it). When it cannot (a reader), or this try
            // did not end, the next try comes one step on.
            let step = (CHECKPOINT_BYTES / shared.frame_bytes).max(1);
            state.restart_try_frames = state.wal_frames.saturating_add(step);
            state.restart_running = false;
        } else if pass.whole
            && state.wal_frames > pass.frames
            && state.wal_frames.saturating_mul(shared.frame_bytes) >= RESTART_BYTES
            && !state.stopping
        {
            // The pass copied a WAL at its restart point to the end it had
            // at the start, so no reader stops a copy now, and commits
            // appended beside it: the WAL still cannot restart, and nothing
            // would be due until they write 4 MiB more (a long read that
            // ended, a WAL a kill left). The rest is small. The restart
            // rule takes it now, with no step to wait for; a store with no
            // writer lock yet gets one more pass at once.
            if shared.writer_lock.get().is_some() {
                state.restart_owed = true;
            } else {
                state.leftover_owed = true;
            }
        }
        state.stop_done = state.stop_done.max(asked);
        if synced {
            state.synced = state.synced.max(target);
        }
        shared.changed.notify_all();
    }
}

/// One PASSIVE checkpoint of the syncer.
#[derive(Clone, Copy, Default)]
struct Pass {
    /// It ran (SQLite synced the WAL before it copied).
    ran: bool,
    /// It copied the whole WAL as of its start.
    whole: bool,
    /// Frames in the WAL at its start.
    frames: u64,
}

/// One try of the restart rule, on the syncer thread (module docs): the
/// bulk with no lock, then the tail under the database's writer lock.
/// `whole` is true when the try ended with every frame copied, so the next
/// commit can restart the WAL.
fn restart_the_wal(shared: &Shared, checkpointer: &mut Option<Connection>) -> Pass {
    #[cfg(test)]
    slow_restart_bulk(shared);
    let mut bulk = Pass::default();
    for _ in 0..BULK_PASSES {
        bulk = checkpoint_if_due(shared, checkpointer, true);
        if !bulk.whole {
            // A reader's snapshot stopped the copy (or it failed): a tail
            // under the lock would stop at the same mark.
            return bulk;
        }
        // SQLite syncs the database file only in the checkpoint that copies
        // the whole WAL: that is the tail, under the lock. Sync the pages of
        // the bulk here, so the tail's sync finds only its own.
        if let Some(connection) = checkpointer.as_ref() {
            sync_database(connection);
        }
        let frames = shared.state.lock().recover_poison().wal_frames;
        let tail = frames.saturating_sub(bulk.frames).saturating_mul(shared.frame_bytes);
        if tail <= TAIL_BYTES {
            break;
        }
    }
    let Some(writer_lock) = shared.writer_lock.get() else { return Pass { whole: false, ..bulk } };
    let mut tail = Pass::default();
    // The syncer holds none of its own locks while it waits for this one: a
    // committing thread holds the writer lock when it takes the counters.
    let deadline = Instant::now() + shared.restart_wait;
    let held = writer_lock.exclude_commits(deadline, &mut || {
        #[cfg(test)]
        let from = Instant::now();
        tail = checkpoint_if_due(shared, checkpointer, true);
        #[cfg(test)]
        shared.state.lock().recover_poison().restart_holds.push((from, Instant::now()));
    });
    Pass { ran: true, whole: held && tail.whole, frames: tail.frames.max(bulk.frames) }
}

/// A plain fsync of the database file, as the checkpoint's own sync is
/// ([`CHECKPOINTER_PRAGMAS`]): it writes the pages a PASSIVE checkpoint
/// copied. Not needed for safety (SQLite syncs the file itself before the
/// WAL can restart); it takes that work out of the tail of a restart.
///
/// Through SQLite's own handle of the file, never a second descriptor: the
/// close of any descriptor of a file drops every POSIX lock the process
/// holds on it, and each connection keeps a shared lock on the database
/// file while it is in WAL mode.
fn sync_database(checkpointer: &Connection) {
    use rusqlite::ffi;
    let mut file: *mut ffi::sqlite3_file = std::ptr::null_mut();
    // SAFETY: `checkpointer` is the syncer's own connection, used only on
    // this thread. SQLITE_FCNTL_FILE_POINTER writes the file object of its
    // main database into `file`; that object lives as long as the connection.
    let found = unsafe {
        ffi::sqlite3_file_control(
            checkpointer.handle(),
            c"main".as_ptr(),
            ffi::SQLITE_FCNTL_FILE_POINTER,
            (&raw mut file).cast(),
        )
    };
    if found != ffi::SQLITE_OK || file.is_null() {
        eprintln!("cmux-tui: no file handle for the database sync (SQLite code {found})");
        return;
    }
    // SAFETY: `file` is the open main database file of `checkpointer`; its
    // method table is set while the file is open.
    let sync = unsafe { (*file).pMethods.as_ref() }.and_then(|methods| methods.xSync);
    let Some(sync) = sync else { return };
    // SAFETY: the VFS's own sync of its open file, with the flag SQLite
    // passes for a checkpoint with `checkpoint_fullfsync=OFF`.
    let synced = unsafe { sync(file, ffi::SQLITE_SYNC_NORMAL) };
    if synced != ffi::SQLITE_OK {
        eprintln!("cmux-tui: database sync failed (SQLite code {synced})");
    }
}

/// The [`WalDurability::slow_restart_bulk`] seam.
#[cfg(test)]
fn slow_restart_bulk(shared: &Shared) {
    let ms = shared.slow_restart_bulk_ms.load(std::sync::atomic::Ordering::Acquire);
    if ms > 0 {
        std::thread::sleep(Duration::from_millis(ms));
    }
}

/// A PASSIVE checkpoint on the syncer's own connection when `due`: it
/// copies what it can without waiting for a writer or reader.
fn checkpoint_if_due(shared: &Shared, checkpointer: &mut Option<Connection>, due: bool) -> Pass {
    // Each pass reads the file's size for its high-water mark.
    wal_file_len(shared);
    if !due {
        return Pass::default();
    }
    if checkpointer.is_none() {
        *checkpointer = super::open_registry_database_with_flags(
            &shared.database_path,
            rusqlite::OpenFlags::default(),
        )
        .and_then(|connection| {
            connection.execute_batch(CHECKPOINTER_PRAGMAS)?;
            connection.execute_batch(&journal_size_limit_pragma())?;
            Ok(connection)
        })
        .map_err(|error| eprintln!("cmux-tui: open the WAL checkpointer failed: {error:#}"))
        .ok();
    }
    let Some(connection) = checkpointer.as_ref() else { return Pass::default() };
    // The row: (busy, frames in the WAL, frames copied).
    let result = connection.query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
    });
    match result {
        Ok((busy, frames, copied)) => Pass {
            ran: true,
            whole: busy == 0 && copied >= frames,
            frames: u64::try_from(frames).unwrap_or(0),
        },
        Err(error) => {
            eprintln!("cmux-tui: WAL checkpoint failed: {error}");
            Pass::default()
        }
    }
}

/// The checkpoint orders its writes with plain fsyncs, as the WAL flush does
/// (no drive-cache flush while the daemon runs, see [`flush`]).
#[cfg(not(test))]
const CHECKPOINTER_PRAGMAS: &str = "PRAGMA fullfsync=OFF; PRAGMA checkpoint_fullfsync=OFF;";
#[cfg(test)]
const CHECKPOINTER_PRAGMAS: &str = "PRAGMA fullfsync=OFF;";

/// Sync the WAL now (a caller waits for it: [`WalDurability::wait_durable`]).
/// A missing WAL was checkpointed into the database and removed, which
/// SQLite syncs itself.
fn flush(shared: &Shared) {
    if let Some(delay) = shared.slow_flush {
        std::thread::sleep(delay);
    }
    sync_wal(shared, false);
}

fn sync_wal(shared: &Shared, full: bool) {
    let wal = match File::options().read(true).write(true).open(&shared.wal_path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
        Err(error) => {
            eprintln!("cmux-tui: open the WAL for its flush failed: {error}");
            return;
        }
    };
    if let Err(error) = drive_sync(&wal, full) {
        eprintln!("cmux-tui: WAL flush failed: {error}");
    }
}

/// F_BARRIERFSYNC, or F_FULLFSYNC when `full`, on macOS (each falls back to
/// fsync where the file system refuses it); fdatasync elsewhere. Unit tests
/// use a plain fsync, as their registries do (`REGISTRY_FULLFSYNC_PRAGMA`).
fn drive_sync(file: &File, full: bool) -> std::io::Result<()> {
    #[cfg(all(target_os = "macos", not(test)))]
    {
        use std::os::fd::AsRawFd;
        let command = if full { libc::F_FULLFSYNC } else { libc::F_BARRIERFSYNC };
        // SAFETY: fcntl on an fd this function borrows for the call.
        if unsafe { libc::fcntl(file.as_raw_fd(), command) } != -1 {
            return Ok(());
        }
        file.sync_data()
    }
    #[cfg(not(all(target_os = "macos", not(test))))]
    {
        let _ = full;
        file.sync_data()
    }
}

#[cfg(test)]
mod restart_tests;

/// (`mxFrame`, `nBackfill`) of the wal-index header in the database's
/// `-shm` file: the valid frames in the WAL, and how many of them a
/// checkpoint copied into the database. A count, with no connection.
#[cfg(test)]
pub(crate) fn wal_index_frames(database_path: &Path) -> (u32, u32) {
    use std::io::Read;
    let mut shm = database_path.as_os_str().to_owned();
    shm.push("-shm");
    let mut bytes = [0u8; 100];
    let read = File::open(PathBuf::from(shm)).and_then(|mut file| file.read_exact(&mut bytes));
    assert!(read.is_ok(), "read the wal-index header: {read:?}");
    let word =
        |at: usize| u32::from_ne_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]);
    (word(16), word(96))
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(super) fn database(name: &str) -> (PathBuf, Connection) {
        let dir =
            std::env::temp_dir().join(format!("wal-durability-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("r.sqlite");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE t(v);")
            .unwrap();
        (dir, connection)
    }

    #[test]
    fn every_commit_is_counted_and_flushed() {
        let (dir, connection) = database("count");
        let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        connection.execute("INSERT INTO t VALUES (2)", []).unwrap();
        durability.wait_durable();
        assert_eq!(durability.counts(), (2, 2));
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn each_commit_counts_the_wal_frame_bytes_it_appended() {
        let (dir, connection) = database("frame-bytes");
        let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
        let page: i64 = connection.query_row("PRAGMA page_size", [], |row| row.get(0)).unwrap();
        let page = u64::try_from(page).unwrap();
        let frame = page + WAL_FRAME_HEADER_BYTES;
        // The first counted commit also counts the frames already in the WAL (here the CREATE TABLE): a reader
        // takes differences.
        connection.execute("INSERT INTO t VALUES (0)", []).unwrap();
        let base = durability.wal_frame_bytes();
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        let small = durability.wal_frame_bytes() - base;
        assert!(
            small >= frame && small <= 3 * frame,
            "a one-row commit appended {small} bytes ({frame} per frame)"
        );
        // A 256 KiB value: overflow pages, so at least its size in frames.
        connection.execute("INSERT INTO t VALUES (?1)", [vec![7u8; 256 * 1024]]).unwrap();
        let large = durability.wal_frame_bytes() - base - small;
        assert!(
            large >= 256 * 1024 && large <= 256 * 1024 + 16 * frame,
            "a 256 KiB commit appended {large} bytes"
        );
        // The same small commit again appends about what the first one did, not the WAL so far.
        let before = durability.wal_frame_bytes();
        connection.execute("INSERT INTO t VALUES (2)", []).unwrap();
        let again = durability.wal_frame_bytes() - before;
        assert!(
            again >= frame && again <= 3 * frame,
            "a second one-row commit appended {again} bytes"
        );
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_answered_request_syncs_nothing_until_a_checkpoint_or_close() {
        let (dir, connection) = database("share");
        let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
        for value in 0..5 {
            connection.execute("INSERT INTO t VALUES (?1)", [value]).unwrap();
        }
        durability.request_flush();
        std::thread::sleep(Duration::from_millis(50));
        assert_eq!(durability.counts(), (5, 0), "a small WAL was synced after a reply");
        durability.wait_durable();
        assert_eq!(durability.counts(), (5, 5));
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_commit_does_not_wait_for_a_slow_flush() {
        let (dir, connection) = database("slow");
        let durability = WalDurability::attach(
            &connection,
            &dir.join("r.sqlite"),
            Some(Duration::from_millis(300)),
            false,
        );
        let started = Instant::now();
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        assert!(started.elapsed() < Duration::from_millis(100));
        durability.wait_durable();
        assert!(started.elapsed() >= Duration::from_millis(300));
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_syncer_checkpoints_a_large_wal_and_commits_never_do() {
        let (dir, connection) = database("checkpoint");
        let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
        let blob = vec![7u8; 64 * 1024];
        for _ in 0..100 {
            connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
        }
        // A reply is out: the syncer looks at the WAL and checkpoints it.
        durability.request_flush();
        // The checkpoint follows the flush on the syncer thread.
        let deadline = Instant::now() + Duration::from_secs(10);
        let db_len = loop {
            let db_len = std::fs::metadata(dir.join("r.sqlite")).unwrap().len();
            if db_len > 4 * 1024 * 1024 || Instant::now() > deadline {
                break db_len;
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        assert!(db_len > 4 * 1024 * 1024, "the database file is {db_len} bytes: no checkpoint ran");
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Commits about one and a half [`WAL_SIZE_LIMIT_BYTES`] while a reader
    /// holds its snapshot, as a long read of the registry does: no checkpoint
    /// can copy past it. Returns the pinned WAL's size after the reader ended.
    pub(super) fn grow_a_pinned_wal(
        path: &Path,
        connection: &Connection,
        durability: &WalDurability,
    ) -> u64 {
        let reader = Connection::open(path).unwrap();
        reader.execute_batch("BEGIN").unwrap();
        let _: i64 = reader.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
        let blob = vec![7u8; 64 * 1024];
        let commits = (WAL_SIZE_LIMIT_BYTES * 3 / 2) / blob.len() as u64;
        for commit in 0..commits {
            connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
            if commit % 64 == 0 {
                durability.request_flush();
            }
        }
        durability.wait_durable();
        reader.execute_batch("COMMIT").unwrap();
        let mut wal = path.as_os_str().to_owned();
        wal.push("-wal");
        let pinned = std::fs::metadata(PathBuf::from(wal)).unwrap().len();
        assert!(pinned > WAL_SIZE_LIMIT_BYTES, "the pinned WAL is only {pinned} bytes");
        pinned
    }

    #[test]
    fn a_wal_a_reader_pinned_shrinks_under_the_limit_once_the_reader_is_gone() {
        let (dir, connection) = database("pinned");
        let path = dir.join("r.sqlite");
        let durability = WalDurability::attach(&connection, &path, None, false);
        let wal = dir.join("r.sqlite-wal");
        let pinned = grow_a_pinned_wal(&path, &connection, &durability);
        // Answered requests go on: the syncer checkpoints the whole WAL, and
        // the next commit restarts it and cuts the file to the limit.
        let deadline = Instant::now() + Duration::from_secs(10);
        let after = loop {
            connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
            durability.request_flush();
            let len = std::fs::metadata(&wal).map_or(0, |meta| meta.len());
            if len <= WAL_SIZE_LIMIT_BYTES || Instant::now() > deadline {
                break len;
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        assert!(
            after <= WAL_SIZE_LIMIT_BYTES,
            "the WAL stayed at {after} bytes after its reader ended ({pinned} while pinned)"
        );
        let (now, high_water) = durability.wal_file_bytes();
        assert_eq!(now, after);
        assert!(high_water >= pinned, "a high-water mark of {high_water} bytes, {pinned} pinned");
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_transaction_that_reads_then_writes_never_gets_busy_while_the_syncer_checkpoints() {
        // A request transaction reads, then writes (an idle policy update).
        // The upgrade to a writer does not wait for a busy timeout: a
        // checkpoint that held the writer lock while it waited for this
        // transaction's read would fail the write at once.
        let (dir, connection) = database("read-then-write");
        let path = dir.join("r.sqlite");
        let durability = WalDurability::attach(&connection, &path, None, false);
        connection.busy_timeout(Duration::from_secs(5)).unwrap();
        grow_a_pinned_wal(&path, &connection, &durability);
        let wal = dir.join("r.sqlite-wal");
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut rounds = 0;
        while Instant::now() < deadline {
            durability.request_flush();
            let tx = connection.unchecked_transaction().unwrap();
            let _: i64 = tx.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
            std::thread::sleep(Duration::from_millis(10));
            if let Err(error) = tx.execute("INSERT INTO t VALUES (2)", []) {
                panic!("round {rounds}: the write after a read failed: {error}");
            }
            tx.commit().unwrap();
            rounds += 1;
            if rounds >= 20
                && std::fs::metadata(&wal).map_or(0, |meta| meta.len()) <= WAL_SIZE_LIMIT_BYTES
            {
                break;
            }
        }
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
