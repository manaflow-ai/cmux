//! `SignaledMutex`: a mutex whose unlock wakes deadline waiters and whose
//! acquisitions feed hold and wait telemetry (`server-stats`), and
//! [`Mux::lock_state_pinned`], the state lock taken under the registry.
//! Both locks admit by class (`server::priority_gate`): a frontend request
//! goes before waiting automation, which still gets in every 4 ms. Both also
//! time every acquisition by the request's caller class and op
//! (`debug-daemon-locks`, crate::diagnostics::DaemonLockTable).

use cmux_threads::sync::Mutex;
use std::ops::{Deref, DerefMut};
#[cfg(test)]
use std::sync::TryLockResult;
use std::sync::{LockResult, MutexGuard, PoisonError, TryLockError};
use std::time::{Duration, Instant};

use super::{Mux, State, WorkspaceRegistry};
use crate::diagnostics::{DaemonLockTable, LockSlot, lock_clock, timed_acquire};
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
    /// Wait and hold by caller class and op (`debug-daemon-locks`).
    by_request: DaemonLockTable,
}

/// A std mutex's `try_lock` as a gate attempt: `None` while it is held
/// (also the free attempt [`timed_acquire`] makes first).
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
            by_request: DaemonLockTable::new(),
        }
    }

    pub(super) fn stats(&self) -> &crate::diagnostics::LockStats {
        &self.stats
    }

    /// Per-class wait and hold (`server-stats` `lock_classes`).
    pub(super) fn class_stats(&self) -> crate::diagnostics::LockClassesSnapshot {
        self.gate.snapshot()
    }

    pub(super) fn by_request(&self) -> &DaemonLockTable {
        &self.by_request
    }

    fn guard<'a>(
        &'a self,
        value: MutexGuard<'a, T>,
        ticket: HoldTicket,
        site: crate::diagnostics::LockSite,
        acquired: Acquired<'a>,
        blocker: Option<crate::diagnostics::LockSite>,
        rank: HeldRank,
    ) -> SignaledMutexGuard<'a, T> {
        let Acquired { held, waited } = acquired;
        self.stats.acquired(site, waited, blocker, held.acquired_at);
        SignaledMutexGuard {
            value: Gated::new(value, &self.gate, ticket),
            owner: self,
            site,
            held,
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
        let slot = self.by_request.current();
        let admission = self.gate.admission();
        let try_value = || try_std(&self.value);
        // The holder site is read only when the lock is not taken at once: a
        // free lock has no blocker to name.
        let mut blocker = None;
        let ((value, ticket), acquired_at, waited) = timed_acquire(
            slot,
            || admission.try_admit(&try_value),
            || {
                blocker = self.stats.wait_started();
                admission.admit(&try_value, || self.value.lock())
            },
        );
        drop(admission);
        let acquired = Acquired { held: Held { slot, acquired_at }, waited };
        map_poison(value, |value| self.guard(value, ticket, site, acquired, blocker, wait.held()))
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
        let value = try_std(&self.value).ok_or(TryLockError::WouldBlock)?;
        let acquired = Acquired::since(self.by_request.current(), waited_from);
        let ticket = self.gate.ticket(acquired.waited);
        map_poison(value, |value| {
            self.guard(value, ticket, site, acquired, blocker, registry_rank())
        })
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
        let waited_from = lock_clock();
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

/// One timed hold: its (caller class, op) slot and when it was acquired.
struct Held<'a> {
    slot: &'a LockSlot,
    acquired_at: Instant,
}

/// A timed acquisition: its hold and how long it waited.
struct Acquired<'a> {
    held: Held<'a>,
    waited: Duration,
}

impl<'a> Acquired<'a> {
    /// An acquisition now whose wait began at `waited_from` (test paths
    /// that acquire with `try_lock`).
    #[cfg(test)]
    fn since(slot: &'a LockSlot, waited_from: Instant) -> Self {
        let acquired_at = lock_clock();
        let waited = acquired_at.saturating_duration_since(waited_from);
        slot.waited(waited);
        Self { held: Held { slot, acquired_at }, waited }
    }
}

impl Held<'_> {
    /// Records the hold (the release's one clock read) and returns it.
    fn release(&self) -> Duration {
        let held = lock_clock().saturating_duration_since(self.acquired_at);
        self.slot.held(held);
        held
    }
}

pub(crate) struct SignaledMutexGuard<'a, T> {
    /// The lock; dropping it unlocks, then wakes the gate's waiters.
    value: Gated<MutexGuard<'a, T>, &'a PriorityGate>,
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
        let held = self.held.release();
        self.value.record_hold(held);
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
/// It admits by class (`server::priority_gate`), and every acquisition is
/// timed by caller class and op (`debug-daemon-locks`).
pub(crate) struct StateMutex {
    state: Mutex<State>,
    gate: PriorityGate,
    by_request: DaemonLockTable,
}

/// A held mux state lock.
pub(crate) struct StateGuard<'a> {
    /// The lock; dropping it unlocks, then wakes the gate's waiters.
    guard: Gated<MutexGuard<'a, State>, &'a PriorityGate>,
    held: Held<'a>,
    /// Lock rank `MuxState` (crate::lock_rank), released after the lock.
    _rank: HeldRank,
}

impl<'a> StateGuard<'a> {
    fn new(
        guard: Gated<MutexGuard<'a, State>, &'a PriorityGate>,
        held: Held<'a>,
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
        StateGuard { guard, held, _rank: rank }
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
        let held = self.held.release();
        self.guard.record_hold(held);
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
        Self {
            state: Mutex::new(state),
            gate: PriorityGate::new(),
            by_request: DaemonLockTable::new(),
        }
    }

    pub(crate) fn by_request(&self) -> &DaemonLockTable {
        &self.by_request
    }

    /// Lock, admitted by this thread's class (`server::priority_gate`).
    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<StateGuard<'_>> {
        // Raised before the wait (crate::lock_rank `RankWait`).
        let wait = HeldRank::acquire(LockRank::MuxState, STATE_LOCK_NAME);
        let slot = self.by_request.current();
        let admission = self.gate.admission();
        let try_state = || try_std(&self.state);
        let ((guard, ticket), acquired_at, _waited) = timed_acquire(
            slot,
            || admission.try_admit(&try_state),
            || admission.admit(&try_state, || self.state.lock()),
        );
        drop(admission);
        let held = Held { slot, acquired_at };
        map_poison(guard, |guard| {
            StateGuard::new(Gated::new(guard, &self.gate, ticket), held, wait.held())
        })
    }

    #[cfg(test)]
    pub(crate) fn try_lock(&self) -> TryLockResult<StateGuard<'_>> {
        let guard = try_std(&self.state).ok_or(TryLockError::WouldBlock)?;
        let Acquired { held, waited } = Acquired::since(self.by_request.current(), lock_clock());
        let ticket = self.gate.ticket(waited);
        map_poison(guard, |guard| {
            StateGuard::new(Gated::new(guard, &self.gate, ticket), held, state_rank())
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
