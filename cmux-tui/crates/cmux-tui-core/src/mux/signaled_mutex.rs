//! `SignaledMutex`: a mutex whose unlock wakes deadline waiters and whose
//! acquisitions feed hold and wait telemetry (`server-stats`), and
//! [`Mux::lock_state_pinned`], the state lock taken under the registry.
//! Both locks admit by class (`server::priority_gate`): a frontend request
//! goes before waiting automation, which still gets in every 4 ms.

use std::ops::{Deref, DerefMut};
#[cfg(test)]
use std::sync::TryLockResult;
use std::sync::{LockResult, Mutex, MutexGuard, PoisonError, TryLockError};
#[cfg(test)]
use std::time::Instant;

use super::{Mux, State, WorkspaceRegistry};
use crate::lock_rank::{HeldRank, LockRank};
use crate::server::priority_gate::{Gated, HoldTicket, PriorityGate};
use crate::workspace_registry::registry_connection::RegistryConnectionPin;

pub(crate) struct SignaledMutex<T> {
    value: Mutex<T>,
    /// Admission by class (`server::priority_gate`); its release condvar
    /// also wakes deadline waiters.
    gate: PriorityGate,
    /// Contention record with `#[track_caller]` attribution, reported by
    /// `server-stats` so lock convoys are visible without external sampling.
    stats: crate::diagnostics::LockStats,
}

/// A std mutex's `try_lock` as a gate attempt: `None` while it is held.
fn try_std<T>(mutex: &Mutex<T>) -> Option<LockResult<MutexGuard<'_, T>>> {
    match mutex.try_lock() {
        Ok(guard) => Some(Ok(guard)),
        Err(TryLockError::WouldBlock) => None,
        Err(TryLockError::Poisoned(poison)) => Some(Err(poison)),
    }
}

/// Wrap a gated std lock result, keeping the poison.
fn map_poison<G, W>(result: LockResult<G>, wrap: impl FnOnce(G) -> W) -> LockResult<W> {
    match result {
        Ok(guard) => Ok(wrap(guard)),
        Err(poison) => Err(PoisonError::new(wrap(poison.into_inner()))),
    }
}

impl<T> SignaledMutex<T> {
    pub(super) fn new(value: T) -> Self {
        Self {
            value: Mutex::new(value),
            gate: PriorityGate::new(),
            stats: crate::diagnostics::LockStats::new(),
        }
    }

    pub(super) fn stats(&self) -> &crate::diagnostics::LockStats {
        &self.stats
    }

    /// Per-class wait and hold (`server-stats` `lock_classes`).
    pub(super) fn class_stats(&self) -> crate::diagnostics::LockClassesSnapshot {
        self.gate.snapshot()
    }

    fn guard<'a>(
        &'a self,
        value: MutexGuard<'a, T>,
        ticket: HoldTicket,
        site: crate::diagnostics::LockSite,
        blocker: Option<crate::diagnostics::LockSite>,
        rank: HeldRank,
    ) -> SignaledMutexGuard<'a, T> {
        self.stats.acquired(site, ticket.waited(), blocker);
        SignaledMutexGuard {
            value: Gated::new(value, &self.gate, ticket),
            owner: self,
            site,
            _rank: rank,
        }
    }

    /// Lock, admitted by this thread's class (`server::priority_gate`).
    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<SignaledMutexGuard<'_, T>> {
        debug_assert_not_journal_writer_commit();
        // Raised before the wait (crate::lock_rank `RankWait`).
        let wait = HeldRank::acquire(LockRank::WorkspaceRegistry, REGISTRY_LOCK_NAME);
        let site = std::panic::Location::caller();
        let blocker = self.stats.wait_started();
        let (value, ticket) = self.gate.acquire(|| try_std(&self.value), || self.value.lock());
        map_poison(value, |value| self.guard(value, ticket, site, blocker, wait.held()))
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
        let value = try_std(&self.value).ok_or(TryLockError::WouldBlock)?;
        let ticket = self.gate.ticket(waited_from.elapsed());
        map_poison(value, |value| self.guard(value, ticket, site, blocker, registry_rank()))
            .map_err(TryLockError::Poisoned)
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
        // A release after the epoch read wakes the wait below, so none is
        // missed between the attempt and the wait.
        let watch = self.gate.watch_releases();
        loop {
            let seen = watch.epoch();
            match self.try_lock_at(site, waited_from, blocker) {
                Ok(value) => return Ok(value),
                Err(TryLockError::Poisoned(_)) => {
                    self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                    anyhow::bail!("mutex is poisoned")
                }
                Err(TryLockError::WouldBlock) => {}
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                self.stats.wait_failed(site, waited_from.elapsed(), blocker);
                return Err(crate::JournalContention::MUTEX_DEADLINE.into());
            }
            watch.wait(seen, remaining);
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
    /// The lock; dropping it unlocks, then wakes the gate's waiters.
    value: Gated<MutexGuard<'a, T>, &'a PriorityGate>,
    owner: &'a SignaledMutex<T>,
    site: crate::diagnostics::LockSite,
    /// Lock rank `WorkspaceRegistry` (crate::lock_rank), released after the
    /// lock.
    _rank: HeldRank,
}

const REGISTRY_LOCK_NAME: &str = "workspace.registry";

impl<T> Deref for SignaledMutexGuard<'_, T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        &self.value
    }
}

impl<T> DerefMut for SignaledMutexGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.value
    }
}

impl<T> Drop for SignaledMutexGuard<'_, T> {
    fn drop(&mut self) {
        // Clear holder attribution before the inner mutex is released (the
        // fields drop after this body), so a waiter that acquires next can
        // never have its holder record erased by this older unlock.
        let held = self.value.end_hold().unwrap_or_default();
        self.owner.stats.released(self.site, held);
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
/// It admits by class (`server::priority_gate`).
pub(crate) struct StateMutex {
    state: Mutex<State>,
    gate: PriorityGate,
}

/// A held mux state lock.
pub(crate) struct StateGuard<'a> {
    /// The lock; dropping it unlocks, then wakes the gate's waiters.
    guard: Gated<MutexGuard<'a, State>, &'a PriorityGate>,
    /// Lock rank `MuxState` (crate::lock_rank), released after the lock.
    _rank: HeldRank,
}

impl StateGuard<'_> {
    fn new<'a>(
        guard: Gated<MutexGuard<'a, State>, &'a PriorityGate>,
        rank: HeldRank,
    ) -> StateGuard<'a> {
        // A request thread may hold state while it waits for a writer
        // receipt: the writer must never take state (counted in release).
        let on_writer = crate::workspace_registry::registry_connection::in_journal_writer_commit();
        if on_writer {
            crate::diagnostics::writer_took_registry_lock();
        }
        debug_assert!(!on_writer, "the journal writer took the mux state lock");
        crate::workspace_registry::registry_connection::note_state_lock(true);
        StateGuard { guard, _rank: rank }
    }
}

const STATE_LOCK_NAME: &str = "mux.state";

/// The state rank of a `try_lock`, which never waits.
#[cfg(test)]
fn state_rank() -> HeldRank {
    HeldRank::record(LockRank::MuxState, STATE_LOCK_NAME)
}

/// The registry rank of a `try_lock`, which never waits.
#[cfg(test)]
fn registry_rank() -> HeldRank {
    HeldRank::record(LockRank::WorkspaceRegistry, REGISTRY_LOCK_NAME)
}

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
        Self { state: Mutex::new(state), gate: PriorityGate::new() }
    }

    /// Lock, admitted by this thread's class (`server::priority_gate`).
    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<StateGuard<'_>> {
        // Raised before the wait (crate::lock_rank `RankWait`).
        let wait = HeldRank::acquire(LockRank::MuxState, STATE_LOCK_NAME);
        let (guard, ticket) = self.gate.acquire(|| try_std(&self.state), || self.state.lock());
        map_poison(guard, |guard| {
            StateGuard::new(Gated::new(guard, &self.gate, ticket), wait.held())
        })
    }

    #[cfg(test)]
    pub(crate) fn try_lock(&self) -> TryLockResult<StateGuard<'_>> {
        let guard = try_std(&self.state).ok_or(TryLockError::WouldBlock)?;
        let ticket = self.gate.ticket(std::time::Duration::ZERO);
        map_poison(guard, |guard| {
            StateGuard::new(Gated::new(guard, &self.gate, ticket), state_rank())
        })
        .map_err(TryLockError::Poisoned)
    }

    /// Per-class wait and hold (`server-stats` `lock_classes`).
    pub(crate) fn class_stats(&self) -> crate::diagnostics::LockClassesSnapshot {
        self.gate.snapshot()
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
    /// Both acquisitions admit by class (`server::priority_gate`); the flow
    /// holds the registry, so an automation flow never yields here and a
    /// frontend flow is counted while it waits.
    ///
    /// It first settles the receipts of earlier indeterminate registry
    /// commits that arrived since (cx-g1fa.3): their state updates and
    /// revisions land before this flow reads state.
    // std's LockResult shape: the poison carries the held guards, which
    // callers recover in place.
    #[allow(clippy::result_large_err)]
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

    /// Per-class wait and hold on the registry, connection and state locks
    /// (`server-stats` `lock_classes`).
    pub(crate) fn lock_class_stats(&self) -> crate::diagnostics::DaemonLockClassesSnapshot {
        crate::diagnostics::DaemonLockClassesSnapshot {
            registry: self.workspace_registry.class_stats(),
            registry_connection: self.registry_connection.class_stats(),
            state: self.state.class_stats(),
        }
    }
}

#[cfg(test)]
#[path = "signaled_mutex_class_tests.rs"]
mod signaled_mutex_class_tests;

#[cfg(test)]
#[path = "lock_qos_tests.rs"]
mod lock_qos_tests;
