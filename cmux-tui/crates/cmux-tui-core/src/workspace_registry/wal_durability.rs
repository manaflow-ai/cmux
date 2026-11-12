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
//! So no request waits for the disk. SQLite's WAL hook runs on the
//! committing thread right after a commit's frames are written and counts
//! it. Once a request's reply is out (the server's reply funnel), or a
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
//! holds more than [`CHECKPOINT_BYTES`] of frames (not once its file is that
//! large: the file keeps its size when the WAL restarts); a PASSIVE
//! checkpoint never blocks a writer.
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
//! Before, each registry commit ran `synchronous=FULL` with `fullfsync`
//! while it held the registry connection lock: about 4.5 ms per commit on a
//! fleet M4 Pro, one to three of them on every create and close reply, and
//! every other request that needed the lock waited behind them.
//!
//! A PASSIVE checkpoint also cannot catch up with a writer that is faster
//! than the copy: each look copies the frames that were there when it began,
//! and a write restarts the WAL only when all of it is copied. A request is
//! never slowed for that. A BACKGROUND writer that nobody waits for (the
//! journal retention pass) pays for the checkpoint of what it wrote before
//! it writes more ([`WalDurability::checkpoint_and_wait`]), as SQLite's own
//! automatic checkpoint makes each writer do
//! (<https://www.sqlite.org/wal.html>, "Performance Considerations"), and it
//! adds nothing to a WAL that is past the limit with frames not yet copied
//! ([`WalRoom`]).
//!
//! The thread sleeps on a condition variable while nothing is owed (no
//! timer, no wakeups at idle).

use std::cell::RefCell;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
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
    /// A background writer waits for a look that begins after it asked
    /// ([`WalDurability::checkpoint_and_wait`]): the syncer looks with or
    /// without a new commit, and clears this when such a look ended. No
    /// request sets it.
    look_wanted: bool,
    /// Frames the last ended look left in the WAL and not copied into the
    /// database: commits that came while it copied, or frames a reader's
    /// snapshot holds. 0 after a look of a small WAL (no checkpoint).
    uncopied_frames: u64,
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
    /// Checkpoints the syncer ran for announced commits.
    #[cfg(test)]
    checkpoints: u64,
    /// Announced commits the syncer has finished with (checkpointed or left in the WAL).
    #[cfg(test)]
    finished: u64,
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
}

thread_local! {
    /// The syncer of the commit in progress on this thread: the commit hook
    /// sets it before SQLite writes the frames, the WAL hook takes it after.
    static COMMITTING: RefCell<Option<Arc<Shared>>> = const { RefCell::new(None) };
}

/// What a background writer may do after
/// [`WalDurability::checkpoint_and_wait`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum WalRoom {
    /// It may write more. The syncer's look at its commits ended in time,
    /// and the WAL file is at or below [`WAL_SIZE_LIMIT_BYTES`], or that
    /// look copied each frame (the next write then restarts the WAL and
    /// SQLite cuts the file to the limit).
    Room,
    /// It must not write more now: more frames would only make the file
    /// larger. The look did not end in time (`looked` is false), or the
    /// file is past the limit with `uncopied_frames` not yet in the
    /// database: other writers are faster than the copy, or a reader holds
    /// an old snapshot.
    Full { looked: bool, file_bytes: u64, uncopied_frames: u64 },
    /// No syncer runs (it did not start, or the database closes): nothing
    /// checkpoints this WAL before the close.
    NoSyncer,
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
        let shared = Arc::new(Shared {
            database_path: database_path.to_path_buf(),
            wal_path: PathBuf::from(wal_path),
            state: Mutex::new(SyncState::default()),
            changed: Condvar::new(),
            slow_flush,
            flush_each_commit,
            commit_delay,
            frame_bytes: page_size + WAL_FRAME_HEADER_BYTES,
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

    /// Announce every commit made so far, as an answered request does, wait
    /// until the syncer has finished with them, and return the checkpoints
    /// it ran for announced commits since the database opened.
    #[cfg(test)]
    pub(crate) fn checkpoints_after_flush(&self) -> u64 {
        request_flush(&self.shared);
        let mut state = self.shared.state.lock().recover_poison();
        while state.finished < state.requested && !state.stopping {
            state = self.shared.changed.wait(state).recover_poison();
        }
        state.checkpoints
    }

    /// Commits made and no caller has asked to flush yet: an idle daemon
    /// leaves them in the WAL until a request flushes it.
    #[cfg(test)]
    pub(crate) fn unrequested_commits(&self) -> u64 {
        let state = self.shared.state.lock().recover_poison();
        state.committed.saturating_sub(state.requested)
    }

    /// Commits the syncer has not begun to look at: a caller that asked for
    /// a flush and went on has no word that the syncer took it.
    #[cfg(test)]
    pub(crate) fn unhandled_commits(&self) -> u64 {
        let state = self.shared.state.lock().recover_poison();
        state.committed.saturating_sub(state.handled)
    }

    /// Flush every commit made so far, soon, on the syncer thread. Callers
    /// ask once their request is answered (the server's reply funnel) or
    /// once a background batch committed (the journal writer).
    pub(crate) fn request_flush(&self) {
        request_flush(&self.shared);
    }

    /// For a BACKGROUND writer only, with no registry lock held: asks the
    /// syncer for a look at the WAL (a PASSIVE checkpoint once it is large)
    /// and waits until a look that began after this call ended, at most
    /// `timeout`. That look covers every commit made before the call. It
    /// runs with no new commit too: the look before it can have left frames
    /// that a reader held, and an idle daemon makes no commit that would ask
    /// again. Never on a request's path: no request waits for the disk
    /// (module docs).
    pub(crate) fn checkpoint_and_wait(&self, timeout: Duration) -> WalRoom {
        let deadline = std::time::Instant::now() + timeout;
        let mut state = self.shared.state.lock().recover_poison();
        state.requested = state.requested.max(state.committed);
        state.look_wanted = true;
        self.shared.changed.notify_all();
        while state.look_wanted && !state.stopping {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                break;
            }
            state = self.shared.changed.wait_timeout(state, left).recover_poison().0;
        }
        if state.stopping {
            return WalRoom::NoSyncer;
        }
        let (looked, uncopied_frames) = (!state.look_wanted, state.uncopied_frames);
        drop(state);
        let file_bytes = wal_file_len(&self.shared);
        // MUTATION, never merge: the gate with the file's size alone.
        if looked && file_bytes <= WAL_SIZE_LIMIT_BYTES {
            WalRoom::Room
        } else {
            WalRoom::Full { looked, file_bytes, uncopied_frames }
        }
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
    state.wal_frames = frames;
    state.wal_frame_bytes =
        state.wal_frame_bytes.saturating_add(appended.saturating_mul(shared.frame_bytes));
    if shared.flush_each_commit {
        state.requested = state.committed;
        drop(state);
        shared.changed.notify_all();
    }
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
            && !state.stopping
            && !state.look_wanted
        {
            state = shared.changed.wait(state).recover_poison();
        }
        if state.stopping && state.committed <= state.synced {
            return;
        }
        let force = state.stopping || state.forced > state.synced;
        let target = if force { state.committed } else { state.requested };
        state.handled = state.handled.max(state.requested);
        // A background writer that asked before this look began.
        let wanted = state.look_wanted;
        drop(state);
        // A forced flush syncs the WAL; otherwise the WAL reaches the disk
        // with its checkpoint (SQLite syncs it first), or at close.
        let look = if force {
            flush(shared);
            None
        } else {
            Some(checkpoint_if_large(shared, &mut checkpointer))
        };
        state = shared.state.lock().recover_poison();
        #[cfg(test)]
        {
            state.finished = state.finished.max(target);
            state.checkpoints += u64::from(matches!(look, Some(Look::Copied { .. })));
            shared.changed.notify_all();
        }
        // The waiters are `wait_durable` (tests) and `checkpoint_and_wait`
        // (the retention pass): a wake only when one of them can go on.
        let mut wake = false;
        if matches!(look, None | Some(Look::Copied { .. })) {
            state.synced = state.synced.max(target);
            wake = true;
        }
        if let Some(look) = look {
            state.uncopied_frames = look.uncopied(state.wal_frames);
            if wanted {
                state.look_wanted = false;
                wake = true;
            }
        }
        if wake {
            shared.changed.notify_all();
        }
    }
}

/// What one look of the syncer at the WAL did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Look {
    /// The WAL held at most [`CHECKPOINT_BYTES`] of frames, in a file at or
    /// below [`WAL_SIZE_LIMIT_BYTES`]: no checkpoint.
    Small,
    /// A PASSIVE checkpoint ran: the WAL held `frames` when it began and
    /// `copied` of them are in the database now.
    Copied { frames: u64, copied: u64 },
    /// The checkpoint did not run (its connection or the statement failed).
    Failed,
}

impl Look {
    /// Frames in the WAL and not in the database after this look, when the
    /// WAL holds `frames_now` (the count after the newest commit).
    fn uncopied(self, frames_now: u64) -> u64 {
        match self {
            Self::Small => 0,
            // No commit of this process yet: the look saw what an earlier
            // run left.
            Self::Copied { frames, copied } if frames_now == 0 => frames.saturating_sub(copied),
            // Fewer frames than the look saw: a write restarted the WAL
            // while it ran, and each frame there now is new.
            Self::Copied { frames, .. } if frames_now < frames => frames_now,
            Self::Copied { copied, .. } => frames_now.saturating_sub(copied),
            Self::Failed => frames_now,
        }
    }
}

/// A PASSIVE checkpoint on the syncer's own connection once the WAL is
/// large: it copies what it can without waiting for a writer or reader.
/// [`Look::Copied`] when a checkpoint ran (it synced the WAL before copying it).
///
/// Large is the frames the WAL holds, not the size of its file: SQLite
/// keeps the file's size when the WAL restarts from its first frame (up to
/// `journal_size_limit`), so a file that passed [`CHECKPOINT_BYTES`] once
/// stays above it while it holds a few frames. A file past the limit is
/// one a reader pinned: a checkpoint lets the next commit cut it back.
fn checkpoint_if_large(shared: &Shared, checkpointer: &mut Option<Connection>) -> Look {
    let file = wal_file_len(shared);
    let frames = shared.state.lock().recover_poison().wal_frames;
    if frames.saturating_mul(shared.frame_bytes) <= CHECKPOINT_BYTES && file <= WAL_SIZE_LIMIT_BYTES
    {
        return Look::Small;
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
    let Some(connection) = checkpointer.as_ref() else { return Look::Failed };
    // The row is (busy, frames in the WAL, frames copied into the database).
    // A statement that ran is a checkpoint that ran, as before: a number
    // that cannot be read counts as "nothing copied".
    let row = connection.query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |row| {
        Ok((row.get::<_, i64>(1).unwrap_or(0), row.get::<_, i64>(2).unwrap_or(0)))
    });
    match row {
        Ok((frames, copied)) => Look::Copied {
            frames: u64::try_from(frames).unwrap_or(0),
            copied: u64::try_from(copied).unwrap_or(0),
        },
        Err(error) => {
            eprintln!("cmux-tui: WAL checkpoint failed: {error}");
            Look::Failed
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
mod tests {
    use super::*;

    fn database(name: &str) -> (PathBuf, Connection) {
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

    /// No background writer asks here (`checkpoint_and_wait` is not called),
    /// so the syncer's wait has the same two reasons to end as before that
    /// function came: a request that asked, or a forced flush. Commits alone
    /// do not wake it, before a request and after one.
    #[test]
    fn a_syncer_that_no_background_writer_asks_looks_only_when_a_request_asks() {
        let (dir, connection) = database("no-look-wanted");
        let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
        for value in 0..5 {
            connection.execute("INSERT INTO t VALUES (?1)", [value]).unwrap();
        }
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(
            durability.unhandled_commits(),
            5,
            "the syncer looked at commits that no request asked it to flush"
        );
        durability.request_flush();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while durability.unhandled_commits() > 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(durability.unhandled_commits(), 0, "the syncer did not take the request");
        for value in 5..8 {
            connection.execute("INSERT INTO t VALUES (?1)", [value]).unwrap();
        }
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(
            durability.unhandled_commits(),
            3,
            "the syncer looked again with no request after its first look"
        );
        assert_eq!(durability.counts(), (8, 0), "a small WAL was synced with no forced flush");
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

    /// SQLite keeps the WAL file's size when the WAL restarts from its first
    /// frame (it cuts the file back only to `journal_size_limit`, 64 MiB), so
    /// a WAL that passed the checkpoint size once kept a file above it for
    /// good, and the syncer, which read the file's size, ran a checkpoint
    /// (two fsyncs and a copy into the database) after every answered
    /// request. One 10.8 GB registry: about 0.36 MiB written per commit that
    /// appended about 60 KB of frames, 1,881 commits in ten minutes
    /// (2026-11-12).
    #[test]
    fn a_wal_file_that_kept_its_size_is_not_checkpointed_after_every_request() {
        let (dir, connection) = database("kept-size");
        let path = dir.join("r.sqlite");
        let durability = WalDurability::attach(&connection, &path, None, false);
        // 8 MiB of commits: the WAL passes the checkpoint size once.
        let blob = vec![7u8; 64 * 1024];
        for _ in 0..128 {
            connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
        }
        let large = durability.checkpoints_after_flush();
        assert!(large >= 1, "a WAL of 8 MiB was not checkpointed");
        // The next commit restarts the WAL from its first frame; the file keeps its size.
        connection.execute("INSERT INTO t VALUES (0)", []).unwrap();
        let file = std::fs::metadata(dir.join("r.sqlite-wal")).unwrap().len();
        assert!(file > CHECKPOINT_BYTES, "the restarted WAL file is {file} bytes");
        // 100 answered requests of one small commit each: well under 4 MiB of frames.
        for value in 1..=100 {
            connection.execute("INSERT INTO t VALUES (?1)", [value]).unwrap();
            durability.checkpoints_after_flush();
        }
        let ran = durability.checkpoints_after_flush() - large;
        assert!(
            ran <= 1,
            "100 one-row requests ran {ran} checkpoints of a WAL that held under 4 MiB of \
             frames (its file kept {file} bytes)"
        );
        // A WAL that fills again is still checkpointed.
        for _ in 0..128 {
            connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
        }
        let again = durability.checkpoints_after_flush() - large - ran;
        assert!(again >= 1, "a WAL that filled again was not checkpointed");
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Commits about one and a half [`WAL_SIZE_LIMIT_BYTES`] while a reader
    /// holds its snapshot, as a long read of the registry does: no checkpoint
    /// can copy past it. Returns the pinned WAL's size after the reader ended.
    fn grow_a_pinned_wal(path: &Path, connection: &Connection, durability: &WalDurability) -> u64 {
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

    /// The journal retention pass writes megabytes with no request between
    /// its commits. With one flush request at its end the WAL file took each
    /// of those bytes (284 MB for one tick on a generated registry). A writer
    /// that waits for the syncer's look after each commit keeps the file at
    /// the checkpoint size class: the look copies all, the next commit
    /// restarts the WAL.
    #[test]
    fn a_background_writer_that_waits_for_its_checkpoint_keeps_the_wal_small() {
        let (dir, connection) = database("background-writer");
        let path = dir.join("r.sqlite");
        let durability = WalDurability::attach(&connection, &path, None, false);
        let blob = vec![7u8; 1024 * 1024];
        // Three times the limit, in commits of 2 MiB.
        let commits = 3 * WAL_SIZE_LIMIT_BYTES / (2 * blob.len() as u64);
        for commit in 0..commits {
            let tx = connection.unchecked_transaction().unwrap();
            tx.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
            tx.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
            tx.commit().unwrap();
            let room = durability.checkpoint_and_wait(Duration::from_secs(30));
            assert_eq!(room, WalRoom::Room, "commit {commit}: no room with one writer");
        }
        let (_, high_water) = durability.wal_file_bytes();
        // One look can find the WAL just below CHECKPOINT_BYTES and leave
        // it; the next commit then adds to it.
        let bound = 2 * CHECKPOINT_BYTES + 2 * (2 * blob.len() as u64 + 64 * 1024);
        assert!(
            high_water <= bound,
            "the WAL file reached {high_water} bytes (bound {bound}) while {commits} commits of \
             2 MiB each waited for their checkpoint"
        );
        drop(connection);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A reader's snapshot holds the WAL past the limit: the look cannot copy
    /// past it, and a background writer has no room until the reader ends.
    ///
    /// Then the idle case: the reader is gone and nobody commits, so no
    /// request asks the syncer again. The writer's own question starts a look
    /// that copies each frame; the file keeps its size (SQLite does not cut a
    /// WAL at a checkpoint), and the writer has room all the same: its next
    /// commit restarts the WAL and SQLite cuts the file to the limit. A gate
    /// on the file's size alone would keep that writer out for ever.
    #[test]
    fn a_background_writer_has_no_room_while_a_reader_holds_a_wal_past_the_limit() {
        let (dir, connection) = database("background-no-room");
        let path = dir.join("r.sqlite");
        let durability = WalDurability::attach(&connection, &path, None, false);
        let reader = Connection::open(&path).unwrap();
        reader.execute_batch("BEGIN").unwrap();
        let _: i64 = reader.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
        let blob = vec![7u8; 1024 * 1024];
        for _ in 0..(WAL_SIZE_LIMIT_BYTES / blob.len() as u64 + 8) {
            connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
        }
        let held = durability.checkpoint_and_wait(Duration::from_secs(30));
        assert!(
            matches!(
                held,
                WalRoom::Full { looked: true, file_bytes, uncopied_frames }
                    if file_bytes > WAL_SIZE_LIMIT_BYTES && uncopied_frames > 0
            ),
            "a look that ended, a file past the limit and frames not copied: {held:?}"
        );
        reader.execute_batch("COMMIT").unwrap();
        drop(reader);
        let free = durability.checkpoint_and_wait(Duration::from_secs(30));
        assert_eq!(free, WalRoom::Room, "no room after the reader ended, with no new commit");
        let (still, _) = durability.wal_file_bytes();
        assert!(
            still > WAL_SIZE_LIMIT_BYTES,
            "the setup: the file keeps its size until a write restarts the WAL: {still} bytes"
        );
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        let (cut, _) = durability.wal_file_bytes();
        assert!(
            cut <= WAL_SIZE_LIMIT_BYTES,
            "the WAL file is {cut} bytes after the first commit that follows the whole copy"
        );
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
