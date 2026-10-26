//! `SignaledMutex`: a mutex whose unlock wakes deadline waiters and whose
//! acquisitions feed hold and wait telemetry (`server-stats`), and
//! [`Mux::lock_state_pinned`], the state lock taken under the registry.
//! Both locks time every acquisition by the request's caller class and op
//! (`debug-daemon-locks`, crate::diagnostics::DaemonLockTable).

use std::ops::{Deref, DerefMut};
#[cfg(test)]
use std::sync::TryLockResult;
use std::sync::{Condvar, LockResult, Mutex, MutexGuard, PoisonError, TryLockError};
use std::time::{Duration, Instant};

use super::{Mux, State, WorkspaceRegistry};
use crate::diagnostics::{DaemonLockTable, LockSlot, lock_clock, timed_acquire};
use crate::lock_rank::{HeldRank, LockRank};
use crate::workspace_registry::registry_connection::RegistryConnectionPin;

pub(crate) struct SignaledMutex<T> {
    value: Mutex<T>,
    release_epoch: Mutex<u64>,
    released: Condvar,
    /// Contention record with `#[track_caller]` attribution, reported by
    /// `server-stats` so lock convoys are visible without external sampling.
    stats: crate::diagnostics::LockStats,
    /// Wait and hold by caller class and op (`debug-daemon-locks`).
    by_request: DaemonLockTable,
}

impl<T> SignaledMutex<T> {
    pub(super) fn new(value: T) -> Self {
        Self {
            value: Mutex::new(value),
            release_epoch: Mutex::new(0),
            released: Condvar::new(),
            stats: crate::diagnostics::LockStats::new(),
            by_request: DaemonLockTable::new(),
        }
    }

    pub(super) fn stats(&self) -> &crate::diagnostics::LockStats {
        &self.stats
    }

    pub(super) fn by_request(&self) -> &DaemonLockTable {
        &self.by_request
    }

    fn guard<'a>(
        &'a self,
        value: MutexGuard<'a, T>,
        site: crate::diagnostics::LockSite,
        held: Held<'a>,
        blocker: Option<crate::diagnostics::LockSite>,
    ) -> SignaledMutexGuard<'a, T> {
        self.stats.acquired(site, held.waited, blocker, held.acquired_at);
        SignaledMutexGuard {
            value: Some(value),
            owner: self,
            site,
            held,
            _rank: HeldRank::record(LockRank::WorkspaceRegistry, REGISTRY_LOCK_NAME),
        }
    }

    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<SignaledMutexGuard<'_, T>> {
        debug_assert_not_journal_writer_commit();
        HeldRank::check(LockRank::WorkspaceRegistry, REGISTRY_LOCK_NAME);
        let site = std::panic::Location::caller();
        let slot = self.by_request.current();
        // The holder site is read only when the lock is held: a free lock
        // has no blocker to name.
        let mut blocker = None;
        let (value, acquired_at, waited) = timed_acquire(
            slot,
            || try_acquire(self.value.try_lock()),
            || {
                blocker = self.stats.wait_started();
                self.value.lock()
            },
        );
        let held = Held { slot, acquired_at, waited };
        match value {
            Ok(value) => Ok(self.guard(value, site, held, blocker)),
            Err(error) => {
                Err(PoisonError::new(self.guard(error.into_inner(), site, held, blocker)))
            }
        }
    }

    #[cfg(test)]
    #[track_caller]
    pub(super) fn try_lock(&self) -> TryLockResult<SignaledMutexGuard<'_, T>> {
        self.try_lock_at(std::panic::Location::caller(), lock_clock(), None)
    }

    #[cfg(test)]
    fn try_lock_at(
        &self,
        site: crate::diagnostics::LockSite,
        waited_from: Instant,
        blocker: Option<crate::diagnostics::LockSite>,
    ) -> TryLockResult<SignaledMutexGuard<'_, T>> {
        let value = match self.value.try_lock() {
            Ok(value) => Ok(value),
            Err(TryLockError::WouldBlock) => return Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(error)) => Err(error.into_inner()),
        };
        let held = Held::waited_since(self.by_request.current(), waited_from);
        match value {
            Ok(value) => Ok(self.guard(value, site, held, blocker)),
            Err(value) => Err(TryLockError::Poisoned(PoisonError::new(
                self.guard(value, site, held, blocker),
            ))),
        }
    }

    /// Deadline wait. The session journal writer used it on the registry
    /// before it moved to the registry connection lock; only tests use it now.
    #[cfg(test)]
    #[track_caller]
    pub(super) fn lock_until(
        &self,
        deadline: Instant,
    ) -> anyhow::Result<SignaledMutexGuard<'_, T>> {
        debug_assert_not_journal_writer_commit();
        HeldRank::check(LockRank::WorkspaceRegistry, REGISTRY_LOCK_NAME);
        let site = std::panic::Location::caller();
        let waited_from = lock_clock();
        let blocker = self.stats.wait_started();
        loop {
            match self.try_lock_at(site, waited_from, blocker) {
                Ok(value) => return Ok(value),
                Err(TryLockError::Poisoned(_)) => {
                    self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                    anyhow::bail!("mutex is poisoned")
                }
                Err(TryLockError::WouldBlock) => {}
            }

            let observed = *self.release_epoch.lock().unwrap();
            match self.try_lock_at(site, waited_from, blocker) {
                Ok(value) => return Ok(value),
                Err(TryLockError::Poisoned(_)) => {
                    self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                    anyhow::bail!("mutex is poisoned")
                }
                Err(TryLockError::WouldBlock) => {}
            }

            let mut epoch = self.release_epoch.lock().unwrap();
            if *epoch != observed {
                continue;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                return Err(crate::JournalContention::MUTEX_DEADLINE.into());
            }
            let (next, result) = self.released.wait_timeout(epoch, remaining).unwrap();
            epoch = next;
            if result.timed_out() && *epoch == observed {
                self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                return Err(crate::JournalContention::MUTEX_DEADLINE.into());
            }
        }
    }
}

/// The workspace registry is the only production `SignaledMutex`. Lock
/// order: workspace registry -> registry connection -> state; the journal
/// writer takes only the connection lock, never this one. Release builds
/// count a violation (`server-stats` `write_path.writer_registry_locks`).
#[track_caller]
fn debug_assert_not_journal_writer_commit() {
    if crate::workspace_registry::registry_connection::in_journal_writer_commit() {
        crate::diagnostics::writer_took_registry_lock();
    }
    debug_assert!(
        !crate::workspace_registry::registry_connection::in_journal_writer_commit(),
        "the session journal writer must not take the workspace registry lock"
    );
}

/// A free lock's [`timed_acquire`] attempt: `None` when it is held.
fn try_acquire<G>(attempt: Result<G, TryLockError<G>>) -> Option<LockResult<G>> {
    match attempt {
        Ok(guard) => Some(Ok(guard)),
        Err(TryLockError::Poisoned(poison)) => Some(Err(poison)),
        Err(TryLockError::WouldBlock) => None,
    }
}

/// One timed acquisition: its (caller class, op) slot, when it was
/// acquired and how long it waited.
struct Held<'a> {
    slot: &'a LockSlot,
    acquired_at: Instant,
    waited: Duration,
}

impl<'a> Held<'a> {
    /// An acquisition now whose wait began at `waited_from` (test paths
    /// that acquire with `try_lock`).
    #[cfg(test)]
    fn waited_since(slot: &'a LockSlot, waited_from: Instant) -> Self {
        let acquired_at = lock_clock();
        let waited = acquired_at.saturating_duration_since(waited_from);
        slot.waited(waited);
        Self { slot, acquired_at, waited }
    }

    /// Records the hold (the release's one clock read) and returns it.
    fn release(&self) -> Duration {
        let held = lock_clock().saturating_duration_since(self.acquired_at);
        self.slot.held(held);
        held
    }
}

pub(crate) struct SignaledMutexGuard<'a, T> {
    value: Option<MutexGuard<'a, T>>,
    owner: &'a SignaledMutex<T>,
    site: crate::diagnostics::LockSite,
    held: Held<'a>,
    /// Lock rank `WorkspaceRegistry` (crate::lock_rank), released after the
    /// lock.
    _rank: HeldRank,
}

const REGISTRY_LOCK_NAME: &str = "workspace.registry";

impl<T> Deref for SignaledMutexGuard<'_, T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        self.value.as_deref().expect("signaled mutex guard has a value")
    }
}

impl<T> DerefMut for SignaledMutexGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.value.as_deref_mut().expect("signaled mutex guard has a value")
    }
}

impl<T> Drop for SignaledMutexGuard<'_, T> {
    fn drop(&mut self) {
        // Clear holder attribution before the inner mutex is released, so a
        // waiter that acquires next can never have its holder record erased
        // by this older unlock.
        self.owner.stats.released(self.site, self.held.release());
        drop(self.value.take());
        let mut epoch = self.owner.release_epoch.lock().unwrap();
        *epoch = epoch.wrapping_add(1);
        self.owner.released.notify_all();
    }
}

// The state lock taken under the workspace registry.
//
// Lock order: workspace registry -> registry connection -> state. The
// journal writer takes only the connection lock (never registry, never
// state). A request thread that commits and then projects takes the
// connection lock before state, so state is never held across a writer
// fsync: [`Mux::lock_state_pinned`] is that step.

/// The mux state mutex. It counts holds per thread (`note_state_lock`) so
/// the registry connection lock can assert it is never first taken while
/// this thread holds state (lock order: registry -> connection -> state).
/// Every acquisition is timed by caller class and op (`debug-daemon-locks`).
pub(crate) struct StateMutex {
    state: Mutex<State>,
    by_request: DaemonLockTable,
}

/// A held mux state lock.
pub(crate) struct StateGuard<'a> {
    guard: MutexGuard<'a, State>,
    held: Held<'a>,
    /// Lock rank `MuxState` (crate::lock_rank), released after the lock.
    _rank: HeldRank,
}

impl<'a> StateGuard<'a> {
    fn new(guard: MutexGuard<'a, State>, held: Held<'a>) -> StateGuard<'a> {
        // A request thread may hold state while it waits for a writer
        // receipt: the writer must never take state (counted in release).
        let on_writer = crate::workspace_registry::registry_connection::in_journal_writer_commit();
        if on_writer {
            crate::diagnostics::writer_took_registry_lock();
        }
        debug_assert!(!on_writer, "the journal writer took the mux state lock");
        crate::workspace_registry::registry_connection::note_state_lock(true);
        StateGuard { guard, held, _rank: HeldRank::record(LockRank::MuxState, STATE_LOCK_NAME) }
    }
}

const STATE_LOCK_NAME: &str = "mux.state";

impl Drop for StateGuard<'_> {
    fn drop(&mut self) {
        self.held.release();
        crate::workspace_registry::registry_connection::note_state_lock(false);
    }
}

impl Deref for StateGuard<'_> {
    type Target = State;

    fn deref(&self) -> &State {
        &self.guard
    }
}

impl DerefMut for StateGuard<'_> {
    fn deref_mut(&mut self) -> &mut State {
        &mut self.guard
    }
}

impl StateMutex {
    pub(crate) fn new(state: State) -> Self {
        Self { state: Mutex::new(state), by_request: DaemonLockTable::new() }
    }

    pub(crate) fn by_request(&self) -> &DaemonLockTable {
        &self.by_request
    }

    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<StateGuard<'_>> {
        HeldRank::check(LockRank::MuxState, STATE_LOCK_NAME);
        let slot = self.by_request.current();
        let (guard, acquired_at, waited) =
            timed_acquire(slot, || try_acquire(self.state.try_lock()), || self.state.lock());
        let held = Held { slot, acquired_at, waited };
        match guard {
            Ok(guard) => Ok(StateGuard::new(guard, held)),
            Err(poison) => Err(PoisonError::new(StateGuard::new(poison.into_inner(), held))),
        }
    }

    #[cfg(test)]
    pub(crate) fn try_lock(&self) -> TryLockResult<StateGuard<'_>> {
        let guard = match self.state.try_lock() {
            Ok(guard) => Ok(guard),
            Err(TryLockError::WouldBlock) => return Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => Err(poison.into_inner()),
        };
        let held = Held::waited_since(self.by_request.current(), lock_clock());
        match guard {
            Ok(guard) => Ok(StateGuard::new(guard, held)),
            Err(guard) => {
                Err(TryLockError::Poisoned(PoisonError::new(StateGuard::new(guard, held))))
            }
        }
    }
}

/// The state lock plus a hold of the registry connection taken before it.
/// Fields drop in order: state first, then the connection.
pub(crate) struct PinnedState<'a> {
    state: StateGuard<'a>,
    /// `None` after [`PinnedState::unpin`].
    _connection: Option<RegistryConnectionPin>,
}

impl PinnedState<'_> {
    /// Release the connection pin and keep state: the flow is about to wait
    /// for a journal writer receipt, and the writer needs the connection
    /// (the writer takes neither the registry nor state). After this the
    /// flow must not touch the connection while it holds state.
    pub(crate) fn unpin(&mut self) {
        self._connection = None;
    }
}

impl Deref for PinnedState<'_> {
    type Target = State;

    fn deref(&self) -> &State {
        &self.state
    }
}

impl DerefMut for PinnedState<'_> {
    fn deref_mut(&mut self) -> &mut State {
        &mut self.state
    }
}

impl Mux {
    /// The registry and state locks' tables by caller class and op, named
    /// by lock rank (`debug-daemon-locks`).
    pub(crate) fn daemon_lock_tables(&self) -> [(&'static str, &DaemonLockTable); 2] {
        [
            (REGISTRY_LOCK_NAME, self.workspace_registry.by_request()),
            (STATE_LOCK_NAME, self.state.by_request()),
        ]
    }

    /// Lock state for a flow that holds `registry` and touches its database
    /// while state is held. The connection lock is taken first (see the
    /// module docs); registry methods called meanwhile re-enter it.
    ///
    /// It first settles the receipts of earlier indeterminate registry
    /// commits that arrived since (cx-g1fa.3): their state updates and
    /// revisions land before this flow reads state.
    #[track_caller]
    pub(crate) fn lock_state_pinned(
        &self,
        registry: &WorkspaceRegistry,
    ) -> LockResult<PinnedState<'_>> {
        let connection = Some(registry.connection.pin());
        let (mut pinned, poisoned) = match self.state.lock() {
            Ok(state) => (PinnedState { state, _connection: connection }, false),
            Err(poison) => {
                (PinnedState { state: poison.into_inner(), _connection: connection }, true)
            }
        };
        // Non-blocking: with the pin held the writer cannot commit, so an
        // unanswered one stays for a later holder; the prepare paths wait
        // for it (drain_unsettled) before they build on it.
        self.settle_registry_receipts(registry, &mut pinned.state);
        if poisoned { Err(PoisonError::new(pinned)) } else { Ok(pinned) }
    }
}
