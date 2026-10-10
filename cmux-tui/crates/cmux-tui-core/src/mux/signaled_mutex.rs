//! `SignaledMutex`: a mutex whose unlock wakes deadline waiters and whose
//! acquisitions feed hold and wait telemetry (`server-stats`), and
//! [`Mux::lock_state_pinned`], the state lock taken under the registry.

use std::ops::{Deref, DerefMut};
use std::sync::{Condvar, LockResult, Mutex, MutexGuard, PoisonError};
#[cfg(test)]
use std::sync::{TryLockError, TryLockResult};
use std::time::Instant;

use super::{Mux, State, WorkspaceRegistry};
use crate::lock_rank::{HeldRank, LockRank};
use crate::workspace_registry::registry_connection::RegistryConnectionPin;

pub(crate) struct SignaledMutex<T> {
    value: Mutex<T>,
    release_epoch: Mutex<u64>,
    released: Condvar,
    /// Contention record with `#[track_caller]` attribution, reported by
    /// `server-stats` so lock convoys are visible without external sampling.
    stats: crate::diagnostics::LockStats,
}

impl<T> SignaledMutex<T> {
    pub(super) fn new(value: T) -> Self {
        Self {
            value: Mutex::new(value),
            release_epoch: Mutex::new(0),
            released: Condvar::new(),
            stats: crate::diagnostics::LockStats::new(),
        }
    }

    pub(super) fn stats(&self) -> &crate::diagnostics::LockStats {
        &self.stats
    }

    fn guard<'a>(
        &'a self,
        value: MutexGuard<'a, T>,
        site: crate::diagnostics::LockSite,
        waited_from: Instant,
        blocker: Option<crate::diagnostics::LockSite>,
    ) -> SignaledMutexGuard<'a, T> {
        self.stats.acquired(site, waited_from.elapsed(), blocker);
        SignaledMutexGuard {
            value: Some(value),
            owner: self,
            site,
            acquired_at: Instant::now(),
            _rank: HeldRank::record(LockRank::WorkspaceRegistry, REGISTRY_LOCK_NAME),
        }
    }

    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<SignaledMutexGuard<'_, T>> {
        debug_assert_not_journal_writer_commit();
        HeldRank::check(LockRank::WorkspaceRegistry, REGISTRY_LOCK_NAME);
        let site = std::panic::Location::caller();
        let waited_from = Instant::now();
        let blocker = self.stats.wait_started();
        match self.value.lock() {
            Ok(value) => Ok(self.guard(value, site, waited_from, blocker)),
            Err(error) => {
                Err(PoisonError::new(self.guard(error.into_inner(), site, waited_from, blocker)))
            }
        }
    }

    #[cfg(test)]
    #[track_caller]
    pub(super) fn try_lock(&self) -> TryLockResult<SignaledMutexGuard<'_, T>> {
        self.try_lock_at(std::panic::Location::caller(), Instant::now(), None)
    }

    #[cfg(test)]
    fn try_lock_at(
        &self,
        site: crate::diagnostics::LockSite,
        waited_from: Instant,
        blocker: Option<crate::diagnostics::LockSite>,
    ) -> TryLockResult<SignaledMutexGuard<'_, T>> {
        match self.value.try_lock() {
            Ok(value) => Ok(self.guard(value, site, waited_from, blocker)),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(error)) => Err(TryLockError::Poisoned(PoisonError::new(
                self.guard(error.into_inner(), site, waited_from, blocker),
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
        let waited_from = Instant::now();
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

pub(crate) struct SignaledMutexGuard<'a, T> {
    value: Option<MutexGuard<'a, T>>,
    owner: &'a SignaledMutex<T>,
    site: crate::diagnostics::LockSite,
    acquired_at: Instant,
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
        self.owner.stats.released(self.site, self.acquired_at.elapsed());
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
pub(crate) struct StateMutex(Mutex<State>);

/// A held mux state lock.
pub(crate) struct StateGuard<'a> {
    guard: MutexGuard<'a, State>,
    /// Lock rank `MuxState` (crate::lock_rank), released after the lock.
    _rank: HeldRank,
}

impl StateGuard<'_> {
    fn new(guard: MutexGuard<'_, State>) -> StateGuard<'_> {
        // A request thread may hold state while it waits for a writer
        // receipt: the writer must never take state (counted in release).
        let on_writer = crate::workspace_registry::registry_connection::in_journal_writer_commit();
        if on_writer {
            crate::diagnostics::writer_took_registry_lock();
        }
        debug_assert!(!on_writer, "the journal writer took the mux state lock");
        crate::workspace_registry::registry_connection::note_state_lock(true);
        StateGuard { guard, _rank: HeldRank::record(LockRank::MuxState, STATE_LOCK_NAME) }
    }
}

const STATE_LOCK_NAME: &str = "mux.state";

impl Drop for StateGuard<'_> {
    fn drop(&mut self) {
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
        Self(Mutex::new(state))
    }

    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<StateGuard<'_>> {
        HeldRank::check(LockRank::MuxState, STATE_LOCK_NAME);
        match self.0.lock() {
            Ok(guard) => Ok(StateGuard::new(guard)),
            Err(poison) => Err(PoisonError::new(StateGuard::new(poison.into_inner()))),
        }
    }

    #[cfg(test)]
    pub(crate) fn try_lock(&self) -> TryLockResult<StateGuard<'_>> {
        match self.0.try_lock() {
            Ok(guard) => Ok(StateGuard::new(guard)),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => {
                Err(TryLockError::Poisoned(PoisonError::new(StateGuard::new(poison.into_inner()))))
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
    /// Lock state for a flow that holds `registry` and touches its database
    /// while state is held. The connection lock is taken first (see the
    /// module docs); registry methods called meanwhile re-enter it.
    ///
    /// It first settles the receipts of earlier indeterminate registry
    /// commits that arrived since (cx-g1fa.3): their state updates and
    /// revisions land before this flow reads state.
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
        self.settle_registry_receipts(registry, &mut pinned.state);
        if poisoned { Err(PoisonError::new(pinned)) } else { Ok(pinned) }
    }
}
