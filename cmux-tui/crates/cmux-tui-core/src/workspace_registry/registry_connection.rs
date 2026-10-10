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

pub(crate) type RegistryConnectionGuard<'a> = ReentrantMutexGuard<'a, Connection>;

/// An owned hold of the connection lock that borrows nothing from the
/// registry, so the holder can still call `&mut WorkspaceRegistry` methods
/// (they re-enter the lock on the same thread).
pub(crate) type RegistryConnectionPin = ArcReentrantMutexGuard<RawMutex, RawThreadId, Connection>;

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
    #[cfg(test)]
    pub(super) journal_hooks: std::sync::Mutex<JournalCommitHooks>,
}

thread_local! {
    static IN_JOURNAL_WRITER_COMMIT: Cell<bool> = const { Cell::new(false) };
    static STATE_HOLDS: Cell<usize> = const { Cell::new(0) };
}

/// Counts the mux state lock holds of the current thread (`StateMutex`).
pub(crate) fn note_state_lock(acquired: bool) {
    STATE_HOLDS.with(|holds| {
        holds.set(if acquired { holds.get() + 1 } else { holds.get().saturating_sub(1) });
    });
}

/// Marks the current thread as inside a journal writer commit until dropped.
pub(crate) struct JournalWriterCommitScope {
    previous: bool,
}

impl JournalWriterCommitScope {
    pub(crate) fn enter() -> Self {
        Self { previous: IN_JOURNAL_WRITER_COMMIT.with(|flag| flag.replace(true)) }
    }
}

impl Drop for JournalWriterCommitScope {
    fn drop(&mut self) {
        IN_JOURNAL_WRITER_COMMIT.with(|flag| flag.set(self.previous));
    }
}

/// True while this thread runs a journal writer commit. The registry lock
/// asserts it is false: the writer must never take the registry or state.
pub(crate) fn in_journal_writer_commit() -> bool {
    IN_JOURNAL_WRITER_COMMIT.with(Cell::get)
}

impl RegistryConnection {
    pub(super) fn new(connection: Connection) -> Arc<Self> {
        Arc::new(Self {
            connection: Arc::new(ReentrantMutex::new(connection)),
            #[cfg(test)]
            journal_hooks: std::sync::Mutex::default(),
        })
    }

    /// The connection for a request thread. The caller holds the workspace
    /// registry lock (or owns the registry outright), never the state lock
    /// unless it pinned this lock before taking state.
    pub(crate) fn get(&self) -> RegistryConnectionGuard<'_> {
        self.debug_assert_lock_order();
        self.connection.lock()
    }

    /// Hold the connection lock for a request flow before it takes the
    /// state lock (lock order: registry -> connection -> state), so the flow
    /// never holds state while it waits behind a writer commit.
    pub(crate) fn pin(&self) -> RegistryConnectionPin {
        self.debug_assert_lock_order();
        self.connection.lock_arc()
    }

    /// Request-side lock order checks: never on the journal writer thread
    /// inside a commit, and never first taken while this thread holds the
    /// mux state lock (re-entry after a pin is fine).
    fn debug_assert_lock_order(&self) {
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
    pub(crate) fn get_until(&self, deadline: Instant) -> Option<RegistryConnectionGuard<'_>> {
        self.connection.try_lock_until(deadline)
    }

    #[cfg(test)]
    pub(crate) fn try_get(&self) -> Option<RegistryConnectionGuard<'_>> {
        self.connection.try_lock()
    }
}
