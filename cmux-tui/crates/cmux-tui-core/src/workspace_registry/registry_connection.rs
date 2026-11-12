//! The workspace registry's SQLite connection behind its own lock.
//!
//! Lock order: workspace registry -> registry connection -> state. The
//! journal writer takes only the connection lock (never registry, never
//! state). A request thread that commits and then projects takes the
//! connection lock before state, so state is never held across a writer
//! fsync.
//!
//! Request threads reach the connection only through the registry, so they
//! already hold the registry lock when they take this one. The lock is
//! reentrant for its holder thread: a request flow pins it once (see
//! [`RegistryConnection::get`] on a handle clone) and every registry method
//! below re-enters it. Every access is a shared `&Connection`; transactions
//! use `unchecked_transaction`, and SQLite refuses a nested `BEGIN` at run
//! time where `&mut Connection` used to refuse it at compile time.

use std::cell::Cell;
use std::sync::Arc;
use std::time::Instant;

use parking_lot::{
    ArcReentrantMutexGuard, RawMutex, RawThreadId, ReentrantMutex, ReentrantMutexGuard,
};
use rusqlite::Connection;

use crate::lock_rank::{HeldRank, LockRank};

const CONNECTION_LOCK_NAME: &str = "registry.connection";

/// A held connection lock with lock rank `RegistryConnection`
/// (crate::lock_rank). Every acquisition records the rank, so the rank stays
/// held while any hold of this thread lives; only the first acquisition on a
/// thread is checked (a re-entry cannot deadlock).
pub(crate) struct RegistryConnectionGuard<'a> {
    guard: ReentrantMutexGuard<'a, Connection>,
    _rank: HeldRank,
}

impl std::ops::Deref for RegistryConnectionGuard<'_> {
    type Target = Connection;

    fn deref(&self) -> &Connection {
        &self.guard
    }
}

/// An owned hold of the connection lock that borrows nothing from the
/// registry, so the holder can still call `&mut WorkspaceRegistry` methods
/// (they re-enter the lock on the same thread).
pub(crate) struct RegistryConnectionPin {
    _guard: ArcReentrantMutexGuard<RawMutex, RawThreadId, Connection>,
    _rank: HeldRank,
}

/// Test hooks inside a journal writer commit (they pause the writer at a
/// fixed point while it holds the connection lock).
#[cfg(test)]
#[derive(Default)]
pub(crate) struct JournalCommitHooks {
    pub(super) before_commit:
        Option<(std::sync::mpsc::SyncSender<()>, std::sync::mpsc::Receiver<()>)>,
    pub(super) after_commit_admission:
        Option<(std::sync::mpsc::SyncSender<()>, std::sync::mpsc::Receiver<()>)>,
}

// TODO(cx-ags0): the reentrant lock and its pin go away in PR7, when request
// writes become writer-batch intents and the registry lock leaves the write
// path. Reentrancy can hide lock-order bugs; debug_assert_lock_order guards it.
pub(crate) struct RegistryConnection {
    connection: Arc<ReentrantMutex<Connection>>,
    /// Which thread commits durable writes (`server-stats` `write_path`).
    write_path_stats: crate::diagnostics::WritePathStats,
    /// The journal writer, once it runs (see `registry_intent`).
    pub(super) intent_sink: std::sync::OnceLock<Arc<dyn super::RegistryIntentSink>>,
    /// Indeterminate registry commits still owed to state (cx-g1fa.3).
    pub(super) unsettled: std::sync::Mutex<Vec<super::registry_intent::UnsettledReceipt>>,
    /// The length of `unsettled`, written under its mutex, for a reader that takes no lock.
    pub(super) unsettled_held: std::sync::atomic::AtomicUsize,
    /// Flushes the WAL to disk off every request path (`wal_durability`);
    /// `None` for an in-memory registry.
    durability: Option<super::wal_durability::WalDurability>,
    /// Read-only connections to the same file for reads of committed data
    /// that need neither the workspace registry lock nor this connection's
    /// lock ([`Self::read_committed`]). In WAL mode a reader sees the last
    /// committed state and never waits for a writer, nor for another reader.
    /// `None` for an in-memory registry or when the first could not open.
    readers: Option<CommittedReaders>,
    /// One more read-only connection, for the O(1) point reads of frequent
    /// cheap requests only ([`Self::committed_terminal_revision`],
    /// [`Self::committed_resource_revision`]): `identify`, every
    /// `list-workspaces` reply and `session.ping`. A heavy read (a list, a
    /// snapshot) never takes it, so a point read waits only for another
    /// point read (one indexed row), however many heavy reads hold the pool.
    /// It reads the file, as the pool does, so it sees every commit, from any
    /// connection or process. `None` when it did not open: point reads then
    /// use the pool.
    point_reader: Option<std::sync::Mutex<Connection>>,
    #[cfg(test)]
    pub(super) journal_hooks: std::sync::Mutex<JournalCommitHooks>,
}

thread_local! {
    static IN_JOURNAL_WRITER_COMMIT: Cell<bool> = const { Cell::new(false) };
    static STATE_HOLDS: Cell<usize> = const { Cell::new(0) };
}

/// Debug seam (`CMUX_TUI_DEBUG_SLOW_DURABLE_COMMIT_MS=N`, off by default):
/// every flush of the registry WAL to disk takes N ms longer, as on a busy
/// disk, so a test can see that no reply and no first output waits for one
/// (new-terminal-100x, PL-daemon).
pub(crate) fn slow_durable_commit_delay() -> Option<std::time::Duration> {
    static DELAY: std::sync::OnceLock<Option<std::time::Duration>> = std::sync::OnceLock::new();
    *DELAY.get_or_init(|| {
        std::env::var("CMUX_TUI_DEBUG_SLOW_DURABLE_COMMIT_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|ms| *ms > 0)
            .map(std::time::Duration::from_millis)
    })
}

/// Debug seam (`CMUX_TUI_TEST_REGISTRY_COMMIT_DELAY_MS=N`, debug builds
/// only): every registry commit takes N ms longer inside `COMMIT`, holding
/// SQLite's write lock and the connection lock, as a commit on a slow disk
/// does, so a test can see which requests wait for one.
pub(crate) fn registry_commit_delay() -> Option<std::time::Duration> {
    #[cfg(debug_assertions)]
    {
        std::env::var("CMUX_TUI_TEST_REGISTRY_COMMIT_DELAY_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|ms| *ms > 0)
            .map(std::time::Duration::from_millis)
    }
    #[cfg(not(debug_assertions))]
    None
}

/// Install the registry connection's commit hook: the debug span mark
/// (`debug_spans::traced`); [`RegistryConnection::new`] adds the WAL
/// syncer's commit count to a file registry's hook.
pub(crate) fn hooked(connection: Connection) -> Connection {
    crate::debug_spans::traced(connection)
}

/// Counts the mux state lock holds of the current thread (`StateMutex`).
pub(crate) fn note_state_lock(acquired: bool) {
    STATE_HOLDS.with(|holds| {
        holds.set(if acquired { holds.get() + 1 } else { holds.get().saturating_sub(1) });
    });
}

/// True while the current thread holds the mux state lock.
pub(crate) fn current_thread_holds_state() -> bool {
    STATE_HOLDS.with(Cell::get) > 0
}

/// Marks the current thread as the journal writer until dropped. It also
/// holds lock rank `JournalWriter`, so in debug and test builds a registry
/// lock on this thread panics in the lock-rank checker on every path.
pub(crate) struct JournalWriterCommitScope {
    previous: bool,
    _rank: HeldRank,
}

impl JournalWriterCommitScope {
    pub(crate) fn enter() -> Self {
        Self {
            previous: IN_JOURNAL_WRITER_COMMIT.with(|flag| flag.replace(true)),
            // Recorded, not checked: scopes nest (the batch commit enters
            // again inside the loop iteration).
            _rank: HeldRank::record(LockRank::JournalWriter, "journal.writer"),
        }
    }
}

impl Drop for JournalWriterCommitScope {
    fn drop(&mut self) {
        IN_JOURNAL_WRITER_COMMIT.with(|flag| flag.set(self.previous));
    }
}

/// True while this thread runs a journal writer loop iteration (the batch,
/// its commit, retries, and receipt delivery). The registry lock asserts it
/// is false and counts violations: the writer must never take the registry
/// or state, because a request thread holds the registry while it waits for
/// a writer receipt.
pub(crate) fn in_journal_writer_commit() -> bool {
    IN_JOURNAL_WRITER_COMMIT.with(Cell::get)
}

/// The most read-only connections a registry opens. Committed reads (a
/// `tab.list`, a `workspace.list`, the terminal revision of `identify`) ran
/// one at a time on a single connection, so each waited for every read
/// before it: with nine clients listing tabs, an `identify` waited 27 ms for
/// a 0.08 ms read. WAL readers on their own connections never wait for one
/// another; a few cover the request threads that read at once, and each
/// costs only its page cache.
pub(crate) const COMMITTED_READERS: usize = 4;

/// A bounded pool of read-only connections to the registry file. The first
/// opens with the registry; the others open when a read finds every open
/// one in use, up to [`COMMITTED_READERS`]. A read past that waits for one.
struct CommittedReaders {
    path: std::path::PathBuf,
    pool: std::sync::Mutex<ReaderPool>,
    returned: std::sync::Condvar,
}

struct ReaderPool {
    idle: Vec<Connection>,
    /// Connections open: idle ones plus those leased to a read.
    open: usize,
    /// False once a new connection failed to open: the pool keeps the ones
    /// it has and stops trying (and logging) on every busy read.
    can_grow: bool,
}

/// One read's connection; it goes back to the pool when the read ends. A
/// read that panics drops it instead (it may hold an open transaction), and
/// its slot is free for a new one.
struct ReaderLease<'a> {
    readers: &'a CommittedReaders,
    connection: Option<Connection>,
}

impl CommittedReaders {
    fn new(path: &std::path::Path, first: Connection) -> Self {
        Self {
            path: path.to_path_buf(),
            pool: std::sync::Mutex::new(ReaderPool { idle: vec![first], open: 1, can_grow: true }),
            returned: std::sync::Condvar::new(),
        }
    }

    fn pool(&self) -> std::sync::MutexGuard<'_, ReaderPool> {
        self.pool.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// An idle connection, a new one while fewer than the limit are open,
    /// else the next one given back. `None` only when none is open and no
    /// new one can open (the caller reads under the registry).
    fn lease(&self) -> Option<ReaderLease<'_>> {
        let mut pool = self.pool();
        loop {
            if let Some(connection) = pool.idle.pop() {
                return Some(ReaderLease { readers: self, connection: Some(connection) });
            }
            if pool.open == 0 && !pool.can_grow {
                return None;
            }
            if pool.can_grow && pool.open < COMMITTED_READERS {
                pool.open += 1;
                drop(pool);
                match super::open_registry_database_read_only(&self.path) {
                    Ok(connection) => {
                        return Some(ReaderLease { readers: self, connection: Some(connection) });
                    }
                    Err(error) => {
                        eprintln!("cmux-tui: another registry reader did not open: {error:#}");
                        pool = self.pool();
                        pool.open -= 1;
                        pool.can_grow = false;
                        if pool.open == 0 {
                            return None;
                        }
                        // Use one of the open connections instead.
                        continue;
                    }
                }
            }
            pool = self.returned.wait(pool).unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    }
}

impl Drop for ReaderLease<'_> {
    fn drop(&mut self) {
        let mut pool = self.readers.pool();
        match self.connection.take() {
            Some(connection) if !std::thread::panicking() => pool.idle.push(connection),
            _ => pool.open -= 1,
        }
        drop(pool);
        self.readers.returned.notify_one();
    }
}

impl RegistryConnection {
    /// The connection of the registry stored at `database_path` (`None`:
    /// in memory). Its commits run `synchronous=NORMAL`; a file registry's
    /// WAL is flushed to disk by its syncer thread (`wal_durability`).
    pub(super) fn new(
        connection: Connection,
        database_path: Option<&std::path::Path>,
    ) -> Arc<Self> {
        let durability = database_path.map(|path| {
            super::wal_durability::WalDurability::attach_with_commit_delay(
                &connection,
                path,
                slow_durable_commit_delay(),
                false,
                registry_commit_delay(),
            )
        });
        let readers =
            database_path.and_then(|path| match super::open_registry_database_read_only(path) {
                Ok(reader) => Some(CommittedReaders::new(path, reader)),
                Err(error) => {
                    eprintln!("cmux-tui: registry reader connection unavailable: {error:#}");
                    None
                }
            });
        let point_reader = readers.as_ref().and_then(|readers| {
            match super::open_registry_database_read_only(&readers.path) {
                Ok(reader) => Some(std::sync::Mutex::new(reader)),
                Err(error) => {
                    eprintln!("cmux-tui: registry point reader unavailable: {error:#}");
                    None
                }
            }
        });
        Arc::new(Self {
            connection: Arc::new(ReentrantMutex::new(connection)),
            readers,
            point_reader,
            write_path_stats: crate::diagnostics::WritePathStats::default(),
            intent_sink: std::sync::OnceLock::new(),
            unsettled: std::sync::Mutex::default(),
            unsettled_held: std::sync::atomic::AtomicUsize::new(0),
            durability,
            #[cfg(test)]
            journal_hooks: std::sync::Mutex::default(),
        })
    }

    /// Run `read` on one of the registry's read-only connections: committed
    /// data, with no workspace registry lock and no wait for a writer (WAL)
    /// or for another reader, unless [`COMMITTED_READERS`] reads already run.
    /// The pool's mutex is a leaf, held only to take or give back a
    /// connection, never during `read`. `None` when there is no reader (an
    /// in-memory registry): the caller reads under the registry.
    pub(crate) fn read_committed<T>(
        &self,
        read: impl FnOnce(&Connection) -> anyhow::Result<T>,
    ) -> Option<anyhow::Result<T>> {
        let lease = self.readers.as_ref()?.lease()?;
        Some(read(lease.connection.as_ref()?))
    }

    /// The committed terminal registry revision (one meta row), on the point
    /// reader. `None` when there is no reader (an in-memory registry).
    pub(crate) fn committed_terminal_revision(&self) -> Option<anyhow::Result<u64>> {
        self.read_point(super::current_terminal_revision)
    }

    /// The committed resource revision (one meta row), on the point reader.
    /// `None` when there is no reader (an in-memory registry).
    pub(crate) fn committed_resource_revision(&self) -> Option<anyhow::Result<u64>> {
        self.read_point(super::current_resource_revision)
    }

    /// Run an O(1) `read` on the point reader; on the pool when it did not
    /// open. Private: only the bounded reads above run here, so no heavy read
    /// can hold it. Its mutex is held only for `read`, which runs no
    /// transaction of its own, so a read that panicked leaves the connection
    /// usable.
    fn read_point<T>(
        &self,
        read: impl FnOnce(&Connection) -> anyhow::Result<T>,
    ) -> Option<anyhow::Result<T>> {
        match &self.point_reader {
            Some(reader) => {
                Some(read(&reader.lock().unwrap_or_else(std::sync::PoisonError::into_inner)))
            }
            None => self.read_committed(read),
        }
    }

    /// The read-only connections open now (idle or in a read).
    #[cfg(test)]
    pub(crate) fn committed_readers_open(&self) -> usize {
        self.readers.as_ref().map_or(0, |readers| readers.pool().open)
    }

    /// Flush every registry commit made so far, soon, off this thread
    /// (`wal_durability`).
    pub(crate) fn request_flush(&self) {
        if let Some(durability) = &self.durability {
            durability.request_flush();
        }
    }

    /// Commits no flush was requested for (`WalDurability::unrequested_commits`).
    #[cfg(test)]
    pub(crate) fn unrequested_commits_for_test(&self) -> u64 {
        self.durability
            .as_ref()
            .map_or(0, super::wal_durability::WalDurability::unrequested_commits)
    }

    /// (committed, synced) registry commits for `server-stats` `write_path`.
    ///
    /// The committed count is also a CORRECTNESS key, not only a diagnostic: the session snapshot cache
    /// (`resource_api/committed_snapshot.rs`) is current only while this count is unchanged. It must move
    /// inside every COMMIT that writes a WAL frame on this connection (the WAL hook, `wal_durability.rs`
    /// `note_commit`). A `PRAGMA wal_autocheckpoint` or another `sqlite3_wal_hook` on this connection
    /// replaces that hook, and the snapshot is then stale for ever; the guard is
    /// `a_warm_snapshot_shows_the_next_commit_of_each_kind` (`mux/tests/snapshot_read.rs`).
    pub(crate) fn durability_counts(&self) -> (u64, u64) {
        self.durability.as_ref().map(|durability| durability.counts()).unwrap_or_default()
    }

    /// Bytes of the WAL frames this registry's commits appended (`server-stats`
    /// `write_path.registry_wal_frame_bytes`); 0 for an in-memory registry.
    pub(crate) fn wal_frame_bytes(&self) -> u64 {
        self.durability.as_ref().map(|durability| durability.wal_frame_bytes()).unwrap_or_default()
    }

    /// (size now, high-water) of this registry's WAL file (`server-stats`
    /// `write_path.registry_wal_file_bytes` and `registry_wal_file_high_water_bytes`); 0 in memory.
    pub(crate) fn wal_file_bytes(&self) -> (u64, u64) {
        self.durability.as_ref().map(|durability| durability.wal_file_bytes()).unwrap_or_default()
    }

    /// The connection for a request thread. The caller holds the workspace
    /// registry lock (or owns the registry outright), never the state lock
    /// unless it pinned this lock before taking state.
    #[track_caller]
    pub(crate) fn get(&self) -> RegistryConnectionGuard<'_> {
        self.debug_assert_lock_order();
        self.check_rank();
        RegistryConnectionGuard { guard: self.connection.lock(), _rank: record_rank() }
    }

    /// Hold the connection lock for a request flow before it takes the
    /// state lock (lock order: registry -> connection -> state), so the flow
    /// never holds state while it waits behind a writer commit.
    #[track_caller]
    pub(crate) fn pin(&self) -> RegistryConnectionPin {
        self.debug_assert_lock_order();
        self.check_rank();
        RegistryConnectionPin { _guard: self.connection.lock_arc(), _rank: record_rank() }
    }

    /// Check the lock rank before a blocking acquisition that is not a
    /// re-entry.
    #[track_caller]
    fn check_rank(&self) {
        if !self.connection.is_owned_by_current_thread() {
            HeldRank::check(LockRank::RegistryConnection, CONNECTION_LOCK_NAME);
        }
    }

    pub(crate) fn write_path_stats(&self) -> &crate::diagnostics::WritePathStats {
        &self.write_path_stats
    }

    /// True while this thread holds the connection lock (a pin or a guard).
    /// A thread that holds it must not wait for a journal writer receipt:
    /// the writer needs this lock to commit.
    pub(crate) fn is_held_by_current_thread(&self) -> bool {
        self.connection.is_owned_by_current_thread()
    }

    /// Request-side lock order checks: never on the journal writer thread
    /// (counted in release, `writer_registry_locks`), and never first taken
    /// while this thread holds the mux state lock (re-entry after a pin is
    /// fine).
    fn debug_assert_lock_order(&self) {
        if in_journal_writer_commit() {
            crate::diagnostics::writer_took_registry_lock();
        }
        debug_assert!(
            !in_journal_writer_commit(),
            "the journal writer reached a request-side registry connection path"
        );
        debug_assert!(
            STATE_HOLDS.with(Cell::get) == 0 || self.connection.is_owned_by_current_thread(),
            "registry connection taken while holding the state lock; pin it first \
             (lock order: registry -> connection -> state, Mux::lock_state_pinned)"
        );
    }

    /// The connection for the journal writer, waiting at most until
    /// `deadline`. `None` when the deadline passed first.
    #[track_caller]
    pub(crate) fn get_until(&self, deadline: Instant) -> Option<RegistryConnectionGuard<'_>> {
        self.check_rank();
        let guard = self.connection.try_lock_until(deadline)?;
        Some(RegistryConnectionGuard { guard, _rank: record_rank() })
    }

    #[cfg(test)]
    pub(crate) fn try_get(&self) -> Option<RegistryConnectionGuard<'_>> {
        let guard = self.connection.try_lock()?;
        Some(RegistryConnectionGuard { guard, _rank: record_rank() })
    }
}

fn record_rank() -> HeldRank {
    HeldRank::record(LockRank::RegistryConnection, CONNECTION_LOCK_NAME)
}
