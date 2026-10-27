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
//!
//! Every first acquisition on a thread is the connection's checked scope
//! (Chrome's `ScopedBlockingCall`, base/threading/scoped_blocking_call.h): it
//! notes `sqlite` at the code that asked for the connection, which checks
//! `cmux_threads::blocking` there (a thread that disallows blocking records
//! the site, or panics in `CMUX_DAEMON_BLOCKING=panic`) and, on a request
//! thread (`crate::request_path`), counts it; in a recording scope its
//! release notes `lock_hold_over_1ms` there when the hold lasted that long.
//! The lock itself is taken through a `cmux_threads::LockHolder`: a failed
//! try on a thread that disallows blocking is a `lock-wait` violation there,
//! and a wait of 2 ms or more is recorded with the name of the thread that
//! held the lock last before the waiter (`cmux_threads::lock_waits`, shown in
//! `server-stats` `request_path_io.lock_waits`).
//!
//! A first acquisition admits by class (`server::priority_gate`) inside the
//! `LockHolder`'s try and wait: a frontend request goes before waiting
//! automation; a re-entry never waits.
//!
//! The lock does not donate priority (parking_lot), so it boosts its owner
//! (`cmux_threads::OwnerBoost`, Chromium's priority-inheritance locks in
//! base/synchronization/lock_impl_posix.cc): a waiter of a higher QoS than
//! the owner (a request thread behind a Utility journal writer) raises the
//! owner to its QoS until the owner's last hold ends.

use std::cell::Cell;
use std::panic::Location;
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::{
    ArcReentrantMutexGuard, RawMutex, RawThreadId, ReentrantMutex, ReentrantMutexGuard,
};
use rusqlite::Connection;

use cmux_threads::{OwnerBoost, OwnerHold};

use crate::lock_rank::{HeldRank, LockRank, RankWait};
use crate::request_path::BlockingKind;
use crate::server::priority_gate::{Gated, HoldTicket, PriorityGate};

const CONNECTION_LOCK_NAME: &str = "registry.connection";

/// A held connection lock with lock rank `RegistryConnection`
/// (crate::lock_rank). Every acquisition records the rank, so the rank stays
/// held while any hold of this thread lives; only the first acquisition on a
/// thread is checked (a re-entry cannot deadlock).
pub(crate) struct RegistryConnectionGuard<'a> {
    /// Dropped before the lock: the last hold ends the owner's boost while
    /// this thread still owns it.
    _boost: OwnerHold<&'a OwnerBoost>,
    /// The lock; dropping it unlocks (or leaves a re-entry), then wakes the
    /// gate's waiters.
    guard: Gated<ReentrantMutexGuard<'a, Connection>, &'a PriorityGate>,
    _rank: HeldRank,
    /// Dropped after the lock, so a note never prints under it.
    _request_path: RequestPathHold,
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
    /// Dropped before the lock (see `RegistryConnectionGuard`).
    _boost: OwnerHold<Arc<OwnerBoost>>,
    _guard: Gated<ArcReentrantMutexGuard<RawMutex, RawThreadId, Connection>, Arc<PriorityGate>>,
    _rank: HeldRank,
    _request_path: RequestPathHold,
}

/// Holds this long or longer are noted as `lock_hold_over_1ms`.
const LONG_HOLD: Duration = Duration::from_millis(1);

/// A connection hold as a request thread sees it: a first acquisition notes
/// `sqlite` at `site` before it waits; a re-entry notes nothing (it cannot
/// block). In a recording scope (`record`, `panic:<kinds>`) the hold starts
/// its clock once the lock is taken, so its release can note a long hold
/// (not a long wait) at the same site; other modes take no clock.
struct RequestPathHold {
    since: Option<(Instant, &'static Location<'static>)>,
}

impl RequestPathHold {
    const NONE: Self = Self { since: None };

    /// Note the acquisition `sqlite` at `site`; the site to time, or `None`
    /// for a re-entry or a scope that does not record.
    fn note_acquire(
        reentry: bool,
        site: &'static Location<'static>,
    ) -> Option<&'static Location<'static>> {
        if reentry {
            return None;
        }
        (crate::request_path::note_at(BlockingKind::Sqlite, site)
            == crate::request_path::Noted::Recorded)
            .then_some(site)
    }

    /// The hold of a lock just taken for `site`.
    fn held(site: Option<&'static Location<'static>>) -> Self {
        Self { since: site.map(|site| (Instant::now(), site)) }
    }
}

impl Drop for RequestPathHold {
    fn drop(&mut self) {
        if let Some((since, site)) = self.since
            && since.elapsed() >= LONG_HOLD
            && !std::thread::panicking()
        {
            crate::request_path::note_at(BlockingKind::LockHoldOver1ms, site);
        }
    }
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
    /// The thread that last took `connection` (lock waits name it).
    holder: cmux_threads::LockHolder,
    /// Admission by class of first acquisitions (`server::priority_gate`);
    /// shared with pins, which outlive no borrow of this.
    gate: Arc<PriorityGate>,
    /// Raises the owner to its highest waiter's QoS; shared with pins.
    boost: Arc<OwnerBoost>,
    /// Which thread commits durable writes (`server-stats` `write_path`).
    write_path_stats: crate::diagnostics::WritePathStats,
    /// The journal writer, once it runs (see `registry_intent`).
    pub(super) intent_sink: std::sync::OnceLock<Arc<dyn super::RegistryIntentSink>>,
    /// Indeterminate registry commits still owed to state (cx-g1fa.3).
    pub(super) unsettled: std::sync::Mutex<Vec<super::registry_intent::UnsettledReceipt>>,
    /// Flushes the WAL to disk off every request path (`wal_durability`);
    /// `None` for an in-memory registry.
    durability: Option<super::wal_durability::WalDurability>,
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
pub(crate) fn slow_durable_commit_delay() -> Option<Duration> {
    static DELAY: std::sync::OnceLock<Option<Duration>> = std::sync::OnceLock::new();
    *DELAY.get_or_init(|| {
        std::env::var("CMUX_TUI_DEBUG_SLOW_DURABLE_COMMIT_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|ms| *ms > 0)
            .map(Duration::from_millis)
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
        Arc::new(Self {
            connection: Arc::new(ReentrantMutex::new(connection)),
            holder: cmux_threads::LockHolder::default(),
            gate: Arc::new(PriorityGate::new()),
            boost: Arc::new(OwnerBoost::new()),
            write_path_stats: crate::diagnostics::WritePathStats::default(),
            intent_sink: std::sync::OnceLock::new(),
            unsettled: std::sync::Mutex::default(),
            durability,
            #[cfg(test)]
            journal_hooks: std::sync::Mutex::default(),
        })
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
        self.get_at(Location::caller())
    }

    /// [`Self::get`] for a site captured before a closure (closures are not
    /// `#[track_caller]`): `let site = Location::caller();` in the
    /// `#[track_caller]` method, then `get_at(site)` inside the closure.
    #[track_caller]
    pub(crate) fn get_at(&self, site: &'static Location<'static>) -> RegistryConnectionGuard<'_> {
        self.debug_assert_lock_order();
        let wait = self.acquire_rank();
        let reentry = self.connection.is_owned_by_current_thread();
        let timed = RequestPathHold::note_acquire(reentry, site);
        let guard = if reentry {
            Gated::reentered(self.connection.lock(), &*self.gate)
        } else {
            let (guard, ticket) =
                self.admit(site, || self.connection.try_lock(), || self.connection.lock());
            Gated::new(guard, &*self.gate, ticket)
        };
        RegistryConnectionGuard {
            _boost: OwnerBoost::hold(&*self.boost),
            guard,
            _rank: wait.held(),
            _request_path: RequestPathHold::held(timed),
        }
    }

    /// Hold the connection lock for a request flow before it takes the
    /// state lock (lock order: registry -> connection -> state), so the flow
    /// never holds state while it waits behind a writer commit.
    #[track_caller]
    pub(crate) fn pin(&self) -> RegistryConnectionPin {
        self.debug_assert_lock_order();
        let wait = self.acquire_rank();
        let site = Location::caller();
        let reentry = self.connection.is_owned_by_current_thread();
        let timed = RequestPathHold::note_acquire(reentry, site);
        let guard = if reentry {
            Gated::reentered(self.connection.lock_arc(), Arc::clone(&self.gate))
        } else {
            let (guard, ticket) =
                self.admit(site, || self.connection.try_lock_arc(), || self.connection.lock_arc());
            Gated::new(guard, Arc::clone(&self.gate), ticket)
        };
        RegistryConnectionPin {
            _boost: OwnerBoost::hold(Arc::clone(&self.boost)),
            _guard: guard,
            _rank: wait.held(),
            _request_path: RequestPathHold::held(timed),
        }
    }

    /// A first acquisition: the holder record (lock-wait attribution and
    /// the blocking check) around the class admission, so a caller the gate
    /// keeps waiting is a contended wait at `site` like one on the lock. A
    /// contended wait boosts the owner for as long as it lasts.
    fn admit<G>(
        &self,
        site: &'static Location<'static>,
        try_lock: impl Fn() -> Option<G>,
        lock: impl FnOnce() -> G,
    ) -> (G, HoldTicket) {
        let admission = self.gate.admission();
        self.holder.acquire(
            CONNECTION_LOCK_NAME,
            site,
            || admission.try_admit(&try_lock),
            || {
                let _waiting = self.boost.wait();
                admission.admit(&try_lock, lock)
            },
        )
    }

    /// Check the lock rank before a blocking acquisition that is not a
    /// re-entry, and raise a lowered thread before it waits
    /// (crate::lock_rank `RankWait`).
    #[track_caller]
    fn acquire_rank(&self) -> RankWait {
        if self.connection.is_owned_by_current_thread() {
            RankWait::reentry(LockRank::RegistryConnection, CONNECTION_LOCK_NAME)
        } else {
            HeldRank::acquire(LockRank::RegistryConnection, CONNECTION_LOCK_NAME)
        }
    }

    /// Per-class wait and hold of first acquisitions (`server-stats`
    /// `lock_classes`).
    pub(crate) fn class_stats(&self) -> crate::diagnostics::LockClassesSnapshot {
        self.gate.snapshot()
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

    /// The name of the thread that last took the connection lock.
    #[cfg(test)]
    pub(crate) fn last_holder(&self) -> Option<String> {
        self.holder.holder()
    }

    /// Condvar wakeups of the connection lock's gate.
    #[cfg(test)]
    pub(crate) fn gate_wakeups(&self) -> u64 {
        self.gate.wakeups()
    }

    /// Owner boosts started and refused.
    #[cfg(test)]
    pub(crate) fn owner_boosts(&self) -> cmux_threads::BoostCounts {
        self.boost.counts()
    }

    /// The threads waiting for the connection lock now.
    #[cfg(test)]
    pub(crate) fn lock_waiting(&self) -> u32 {
        self.holder.waiting()
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
        let wait = self.acquire_rank();
        let reentry = self.connection.is_owned_by_current_thread();
        let waited_from = Instant::now();
        let guard = self.holder.acquire_until(
            CONNECTION_LOCK_NAME,
            Location::caller(),
            || self.connection.try_lock(),
            || {
                let _waiting = self.boost.wait();
                self.connection.try_lock_until(deadline)
            },
        )?;
        // The journal writer, a program-class thread: it waits on the lock
        // itself, and its hold is recorded and its release wakes the gate.
        let guard = if reentry {
            Gated::reentered(guard, &*self.gate)
        } else {
            Gated::new(guard, &*self.gate, self.gate.ticket(waited_from.elapsed()))
        };
        Some(RegistryConnectionGuard {
            _boost: OwnerBoost::hold(&*self.boost),
            guard,
            _rank: wait.held(),
            _request_path: RequestPathHold::NONE,
        })
    }

    #[cfg(test)]
    pub(crate) fn try_get(&self) -> Option<RegistryConnectionGuard<'_>> {
        let reentry = self.connection.is_owned_by_current_thread();
        let guard = self.connection.try_lock()?;
        let guard = if reentry {
            Gated::reentered(guard, &*self.gate)
        } else {
            Gated::new(guard, &*self.gate, self.gate.ticket(Duration::ZERO))
        };
        Some(RegistryConnectionGuard {
            _boost: OwnerBoost::hold(&*self.boost),
            guard,
            _rank: record_rank(),
            _request_path: RequestPathHold::NONE,
        })
    }
}

#[cfg(test)]
fn record_rank() -> HeldRank {
    HeldRank::record(LockRank::RegistryConnection, CONNECTION_LOCK_NAME)
}

#[cfg(test)]
#[path = "registry_connection_blocking_tests.rs"]
mod blocking_tests;

#[cfg(test)]
#[path = "registry_connection_tests.rs"]
mod tests;
