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
//! So no request waits for the disk, with one bounded exception: the
//! restart rule below (one commit per 64 MiB of WAL waits for a checkpoint,
//! at most [`RESTART_WAIT`], and never a thread that holds the mux state
//! lock). SQLite's WAL hook runs on the committing thread right after a
//! commit's frames are written and counts it. Once a request's reply is out (the server's reply funnel), or a
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
//! syncer runs that checkpoint instead, on its own connection, once the WAL
//! passes [`CHECKPOINT_BYTES`]; a PASSIVE checkpoint never blocks a writer.
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
//! registry's WAL grew to 1366 MB beside a 45 MB database. The restart rule:
//! the WAL hook of the commit that takes the WAL past
//! [`WAL_SIZE_LIMIT_BYTES`] asks the syncer for one more PASSIVE checkpoint
//! and waits for its end, at most [`RESTART_WAIT`]. The committing thread
//! owns its connection (the registry's connection lock; a store's own lock),
//! the only one that writes, so no commit lands during that checkpoint: it
//! copies the whole WAL, the next commit restarts the WAL, and SQLite cuts
//! the file to the limit. The syncer already copied all but the newest
//! commits, so the wait is one short checkpoint per 64 MiB of WAL. The bound
//! is the limit plus one commit, and it holds only while each try's
//! checkpoint ends inside the wait and copies the whole WAL. Three cases
//! take the bound away for a time, and none of them makes a commit wait
//! longer:
//!
//! - A reader that holds a snapshot stops the checkpoint at its mark and the
//!   checkpoint ends at once (PASSIVE waits for no one), so the commit never
//!   waits for the reader. The rule tries again at each further
//!   [`CHECKPOINT_BYTES`], never at each commit, and the file grows by what
//!   commits write until the read ends.
//! - A checkpoint slower than the wait (a slow disk): the commit goes on.
//!   The tries come at 0, 4, 12, 28, 60 and 124 MiB past the limit, then
//!   once per 64 MiB ([`next_restart_step`]): each try that timed out
//!   doubles the step from 4 MiB up to the limit, and a try that ended sets
//!   it back to 4 MiB. The file grows until one try ends.
//! - A commit of a thread that holds the mux state lock never waits (every
//!   reader of the state would wait behind it): it makes no try, and the
//!   next commit of a thread without that lock makes it. The journal writer
//!   makes most commits and never holds the state lock.
//!
//! The thread that waits holds its connection lock (and a request thread
//! the registry lock) for the wait: other writers of that database wait
//! with it, readers of the mux state do not.
//! SQLite's own automatic checkpoint (which Chromium keeps: 1000 pages, on
//! the committing connection, on the database's own sequence) has the same
//! exclusion; here the bulk of the copy stays off the committing thread.
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
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

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

/// The longest a commit waits for the checkpoint that lets the WAL restart
/// (module docs). The checkpoint copies only the commits since the syncer's
/// last one and runs two plain fsyncs: milliseconds on an idle disk. The
/// limit is for a disk that is slow now (a network disk's fsync, a host
/// under load): the commit then goes on, and the rule tries again later.
/// A request thread can be the one that waits: at most this long, once per
/// try, and a try comes once per 64 MiB of WAL when the checkpoint ends.
const RESTART_WAIT: Duration = Duration::from_millis(250);

/// [`RESTART_WAIT`] for a database attached in this crate's unit tests:
/// long, so a try always ends with its checkpoint and a test's byte bound
/// does not depend on the load of its host.
const TEST_RESTART_WAIT: Duration = Duration::from_secs(60);

/// The frames from one try of the restart rule to the next, after a try
/// with the step `previous` (0: the first try past the limit). A try whose
/// checkpoint ended inside the wait: [`CHECKPOINT_BYTES`]. One that timed
/// out: twice the previous step, from [`CHECKPOINT_BYTES`] up to
/// [`WAL_SIZE_LIMIT_BYTES`].
fn next_restart_step(previous: u64, ended: bool, frame_bytes: u64) -> u64 {
    let step = (CHECKPOINT_BYTES / frame_bytes).max(1);
    let limit = (WAL_SIZE_LIMIT_BYTES / frame_bytes).max(step);
    if ended { step } else { previous.saturating_mul(2).clamp(step, limit) }
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
    /// The largest WAL file size seen since the database opened (`server-stats`
    /// `write_path.registry_wal_file_high_water_bytes`).
    wal_file_high_water: u64,
    /// Checkpoints commits asked for so the WAL can restart ([`wait_for_restart_checkpoint`]).
    restart_asked: u64,
    /// Of those, the ones the syncer ended.
    restart_done: u64,
    /// The WAL frame count from which a commit asks again; 0 after a restart.
    restart_try_frames: u64,
    /// Frames between two asks ([`next_restart_step`]).
    restart_step_frames: u64,
    /// The WAL a previous run left is large: the syncer checkpoints it first.
    leftover_owed: bool,
    /// The syncer runs that checkpoint now. It can copy a WAL of any size, so no commit waits for it.
    leftover_running: bool,
    /// Commits that waited for a restart checkpoint, the longest wait, and
    /// the waits that ended at the limit before their checkpoint did.
    #[cfg(test)]
    restart_waits: u64,
    #[cfg(test)]
    restart_wait_longest: Duration,
    #[cfg(test)]
    restart_timeouts: u64,
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
    /// The longest a commit, or the clean stop, waits for a checkpoint it
    /// asked for ([`RESTART_WAIT`]).
    restart_wait: Duration,
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

    /// (commits that waited for a restart checkpoint, the longest wait).
    #[cfg(test)]
    pub(crate) fn restart_waits(&self) -> (u64, Duration) {
        let state = self.shared.state.lock().recover_poison();
        (state.restart_waits, state.restart_wait_longest)
    }

    /// The checkpoints the syncer ran, read once it ended the pass for the
    /// last flush request (or 10 s passed).
    #[cfg(test)]
    pub(crate) fn checkpoints_once_idle(&self) -> u64 {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            let state = self.shared.state.lock().recover_poison();
            if state.settled >= state.requested || std::time::Instant::now() > deadline {
                return state.checkpoints;
            }
            drop(state);
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    /// Waits that ended at the limit before their checkpoint did.
    #[cfg(test)]
    pub(crate) fn restart_timeouts(&self) -> u64 {
        self.shared.state.lock().recover_poison().restart_timeouts
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
fn note_commit(shared: &Shared, frames: std::ffi::c_int) {
    let mut state = shared.state.lock().recover_poison();
    state.committed += 1;
    let frames = u64::try_from(frames).unwrap_or(0);
    // A smaller count: the WAL restarted from its first frame (a checkpoint had copied all of it), so every
    // frame is new. A restart whose first commit writes more frames than the WAL held before counts only the
    // difference; the syncer checkpoints at 4 MiB (about 1000 frames), far above one commit.
    let appended = frames.checked_sub(state.wal_frames).unwrap_or(frames);
    if frames < state.wal_frames {
        state.restart_try_frames = 0;
        state.restart_step_frames = 0;
    }
    state.wal_frames = frames;
    state.wal_frame_bytes =
        state.wal_frame_bytes.saturating_add(appended.saturating_mul(shared.frame_bytes));
    if shared.flush_each_commit {
        state.requested = state.committed;
        shared.changed.notify_all();
    }
    wait_for_restart_checkpoint(shared, state, frames);
}

/// The restart rule (module docs), on the committing thread, after its
/// commit: SQLite released the write lock and the read snapshot before it
/// ran the WAL hook. With `frames` in the WAL past the size limit, ask the
/// syncer for one PASSIVE checkpoint and wait for its end, at most
/// [`RESTART_WAIT`]. This thread owns the writing connection, so the
/// checkpoint sees no new commit and the next commit restarts the WAL.
///
/// A thread that holds the mux state lock makes no try: its wait would hold
/// every reader of the state behind the disk (`registry_intent`: "No request
/// waits for the disk while it holds the mux state lock"). The point of the
/// next try stays, so the next commit of a thread without that lock makes it.
fn wait_for_restart_checkpoint(shared: &Shared, state: MutexGuard<'_, SyncState>, frames: u64) {
    if frames.saturating_mul(shared.frame_bytes) <= WAL_SIZE_LIMIT_BYTES
        || frames < state.restart_try_frames
        || state.leftover_owed
        || state.leftover_running
        || state.stopping
        || super::registry_connection::current_thread_holds_state()
    {
        return;
    }
    #[cfg(test)]
    let started = std::time::Instant::now();
    let (mut state, ended) = checkpoint_and_wait(shared, state);
    // A checkpoint that ended and left frames (a reader holds a snapshot):
    // try again one step on. One that did not end in time: twice that far.
    state.restart_step_frames =
        next_restart_step(state.restart_step_frames, ended, shared.frame_bytes);
    state.restart_try_frames = frames.saturating_add(state.restart_step_frames);
    #[cfg(test)]
    {
        state.restart_waits += 1;
        state.restart_wait_longest = state.restart_wait_longest.max(started.elapsed());
        state.restart_timeouts += u64::from(!ended);
    }
}

/// Ask the syncer for one PASSIVE checkpoint, whatever the WAL's size, and
/// wait for its end, at most the database's wait limit ([`RESTART_WAIT`]).
/// Returns whether it ended.
fn checkpoint_and_wait<'a>(
    shared: &'a Shared,
    mut state: MutexGuard<'a, SyncState>,
) -> (MutexGuard<'a, SyncState>, bool) {
    state.restart_asked += 1;
    let ask = state.restart_asked;
    shared.changed.notify_all();
    let started = std::time::Instant::now();
    let mut waited = Duration::ZERO;
    while state.restart_done < ask && !state.stopping && waited < shared.restart_wait {
        state = shared.changed.wait_timeout(state, shared.restart_wait - waited).recover_poison().0;
        waited = started.elapsed();
    }
    let ended = state.restart_done >= ask;
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
            && state.restart_asked <= state.restart_done
            && !state.leftover_owed
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
        // A commit waits for this checkpoint (the restart rule), or a
        // previous run left a large WAL: checkpoint whatever the size.
        let asked = state.restart_asked;
        let leftover = std::mem::take(&mut state.leftover_owed);
        state.leftover_running = leftover;
        let owed = !state.stopping && (leftover || asked > state.restart_done);
        drop(state);
        // A forced flush syncs the WAL; otherwise the WAL reaches the disk
        // with its checkpoint (SQLite syncs it first), or at close.
        let mut synced = force;
        if force {
            flush(shared);
        }
        let ran = (owed || !force) && checkpoint_if_large(shared, &mut checkpointer, owed);
        synced |= ran;
        state = shared.state.lock().recover_poison();
        #[cfg(test)]
        {
            state.checkpoints += u64::from(ran);
            state.settled = state.handled;
        }
        state.leftover_running = false;
        state.restart_done = state.restart_done.max(asked);
        if synced {
            state.synced = state.synced.max(target);
        }
        shared.changed.notify_all();
    }
}

/// A PASSIVE checkpoint on the syncer's own connection once the WAL is
/// large, or whatever its size when `owed`: it copies what it can without
/// waiting for a writer or reader. True when a checkpoint ran (it synced the
/// WAL before copying it).
fn checkpoint_if_large(shared: &Shared, checkpointer: &mut Option<Connection>, owed: bool) -> bool {
    let size = wal_file_len(shared);
    if size <= CHECKPOINT_BYTES && !owed {
        return false;
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
    let Some(connection) = checkpointer.as_ref() else { return false };
    match connection.query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |_| Ok(())) {
        Ok(()) => true,
        Err(error) => {
            eprintln!("cmux-tui: WAL checkpoint failed: {error}");
            false
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
        let started = std::time::Instant::now();
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
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let db_len = loop {
            let db_len = std::fs::metadata(dir.join("r.sqlite")).unwrap().len();
            if db_len > 4 * 1024 * 1024 || std::time::Instant::now() > deadline {
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
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let after = loop {
            connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
            durability.request_flush();
            let len = std::fs::metadata(&wal).map_or(0, |meta| meta.len());
            if len <= WAL_SIZE_LIMIT_BYTES || std::time::Instant::now() > deadline {
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
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let mut rounds = 0;
        while std::time::Instant::now() < deadline {
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
