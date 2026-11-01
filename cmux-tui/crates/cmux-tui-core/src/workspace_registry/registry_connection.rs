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
    /// Flushes the WAL to disk off every request path (`wal_durability`);
    /// `None` for an in-memory registry.
    durability: Option<super::wal_durability::WalDurability>,
    /// A read-only connection to the same file for reads of committed data
    /// that need neither the workspace registry lock nor this connection's
    /// lock ([`Self::read_committed`]). In WAL mode a reader sees the last
    /// committed state and never waits for a writer. `None` for an
    /// in-memory registry or when it could not open.
    reader: Option<std::sync::Mutex<Connection>>,
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

impl RegistryConnection {
    /// The connection of the registry stored at `database_path` (`None`:
    /// in memory). Its commits run `synchronous=NORMAL`; a file registry's
    /// WAL is flushed to disk by its syncer thread (`wal_durability`).
    pub(super) fn new(
        connection: Connection,
        database_path: Option<&std::path::Path>,
    ) -> Arc<Self> {
        let durability = database_path.map(|path| {
            super::wal_durability::WalDurability::attach(
                &connection,
                path,
                slow_durable_commit_delay(),
                false,
            )
        });
        let reader =
            database_path.and_then(|path| match super::open_registry_database_read_only(path) {
                Ok(reader) => Some(std::sync::Mutex::new(reader)),
                Err(error) => {
                    eprintln!("cmux-tui: registry reader connection unavailable: {error:#}");
                    None
                }
            });
        Arc::new(Self {
            connection: Arc::new(ReentrantMutex::new(connection)),
            reader,
            write_path_stats: crate::diagnostics::WritePathStats::default(),
            intent_sink: std::sync::OnceLock::new(),
            unsettled: std::sync::Mutex::default(),
            durability,
            #[cfg(test)]
            journal_hooks: std::sync::Mutex::default(),
        })
    }

    /// Run `read` on the registry's read-only connection: committed data,
    /// with no workspace registry lock and no wait for a writer (WAL). Its
    /// own mutex is a leaf held only for `read`. `None` when there is no
    /// reader (an in-memory registry): the caller reads under the registry.
    pub(crate) fn read_committed<T>(
        &self,
        read: impl FnOnce(&Connection) -> anyhow::Result<T>,
    ) -> Option<anyhow::Result<T>> {
        let reader = self.reader.as_ref()?;
        let connection = reader.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        Some(read(&connection))
    }

    /// Flush every registry commit made so far, soon, off this thread
    /// (`wal_durability`).
    pub(crate) fn request_flush(&self) {
        if let Some(durability) = &self.durability {
            durability.request_flush();
        }
    }

    /// (committed, synced) registry commits for `server-stats` `write_path`.
    pub(crate) fn durability_counts(&self) -> (u64, u64) {
        self.durability.as_ref().map(|durability| durability.counts()).unwrap_or_default()
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
