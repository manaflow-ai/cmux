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
//! passes [`CHECKPOINT_BYTES`]; a PASSIVE checkpoint never blocks a writer.
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
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use rusqlite::Connection;

use crate::panic_free::RecoverPoison;

/// WAL size past which the syncer checkpoints (SQLite's own default is
/// 1000 pages of 4 KiB).
const CHECKPOINT_BYTES: u64 = 4 * 1024 * 1024;

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
        let mut wal_path = database_path.as_os_str().to_owned();
        wal_path.push("-wal");
        let shared = Arc::new(Shared {
            database_path: database_path.to_path_buf(),
            wal_path: PathBuf::from(wal_path),
            state: Mutex::new(SyncState::default()),
            changed: Condvar::new(),
            slow_flush,
            flush_each_commit,
        });
        let owner = SyncerOwner(shared.clone());
        let _ = connection.commit_hook(Some(move || {
            crate::debug_spans::mark("sqlite.commit");
            COMMITTING.with(|committing| *committing.borrow_mut() = Some(owner.0.clone()));
            false
        }));
        connection.wal_hook(Some(|_, _| {
            if let Some(shared) = COMMITTING.with(|committing| committing.borrow_mut().take()) {
                note_commit(&shared);
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

    /// Flush every commit made so far, soon, on the syncer thread. Callers
    /// ask once their request is answered (the server's reply funnel) or
    /// once a background batch committed (the journal writer).
    pub(crate) fn request_flush(&self) {
        request_flush(&self.shared);
    }

    /// (committed, synced) commit counts, for `server-stats` `write_path`.
    pub(crate) fn counts(&self) -> (u64, u64) {
        let state = self.shared.state.lock().recover_poison();
        (state.committed, state.synced)
    }
}

fn note_commit(shared: &Shared) {
    let mut state = shared.state.lock().recover_poison();
    state.committed += 1;
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
        while state.requested <= state.handled && state.forced <= state.synced && !state.stopping {
            state = shared.changed.wait(state).recover_poison();
        }
        if state.stopping && state.committed <= state.synced {
            return;
        }
        let force = state.stopping || state.forced > state.synced;
        let target = if force { state.committed } else { state.requested };
        state.handled = state.handled.max(state.requested);
        drop(state);
        // A forced flush syncs the WAL; otherwise the WAL reaches the disk
        // with its checkpoint (SQLite syncs it first), or at close.
        let synced = if force {
            flush(shared);
            true
        } else {
            checkpoint_if_large(shared, &mut checkpointer)
        };
        state = shared.state.lock().recover_poison();
        if synced {
            state.synced = state.synced.max(target);
            shared.changed.notify_all();
        }
    }
}

/// A PASSIVE checkpoint on the syncer's own connection once the WAL is
/// large: it copies what it can without waiting for a writer or reader.
/// True when a checkpoint ran (it synced the WAL before copying it).
fn checkpoint_if_large(shared: &Shared, checkpointer: &mut Option<Connection>) -> bool {
    let large = std::fs::metadata(&shared.wal_path).is_ok_and(|meta| meta.len() > CHECKPOINT_BYTES);
    if !large {
        return false;
    }
    if checkpointer.is_none() {
        *checkpointer = super::open_registry_database_with_flags(
            &shared.database_path,
            rusqlite::OpenFlags::default(),
        )
        .and_then(|connection| {
            connection.execute_batch(CHECKPOINTER_PRAGMAS)?;
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
}
