//! `SignaledMutex`: a mutex whose unlock wakes deadline waiters and whose
//! acquisitions feed hold and wait telemetry (`server-stats`), and
//! [`Mux::lock_state_pinned`], the state lock taken under the registry.

use std::cell::Cell;
use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Condvar, LockResult, Mutex, MutexGuard, PoisonError};
use std::sync::{TryLockError, TryLockResult};
use std::time::{Duration, Instant};

use super::{Mux, State, WorkspaceRegistry};
use crate::lock_rank::{HeldRank, LockRank};
use crate::workspace_registry::registry_connection::RegistryConnectionPin;

thread_local! {
    /// Requests a person waits on: a sidebar click (collapse or move a
    /// group, place a workspace), a new chat tab. Inside one, every registry
    /// lock this thread takes goes ahead of plain lockers (see
    /// [`SignaledMutex`]).
    static INTERACTIVE: Cell<usize> = const { Cell::new(0) };
}

/// Marks this thread's registry locks interactive until it drops. Nested
/// scopes are fine.
pub(crate) struct InteractiveScope(());

impl Drop for InteractiveScope {
    fn drop(&mut self) {
        INTERACTIVE.with(|depth| depth.set(depth.get().saturating_sub(1)));
    }
}

/// Run the rest of the current request's registry locks as interactive.
pub(crate) fn interactive_scope() -> InteractiveScope {
    INTERACTIVE.with(|depth| depth.set(depth.get().saturating_add(1)));
    InteractiveScope(())
}

fn in_interactive_scope() -> bool {
    INTERACTIVE.with(|depth| depth.get() > 0)
}

/// How many interactive acquisitions may go ahead of waiting plain lockers
/// in a row. After that, interactive lockers step aside until a plain one
/// takes the lock, so interactive writes (agents send personal writes too)
/// delay ordinary registry writers by at most this many holds and never
/// starve them.
const MAX_INTERACTIVE_STREAK: usize = 4;

/// The workspace registry lock. The mutex under it is not fair: a waiter
/// can lose to newcomers again and again, so on a busy Mac (about 50 agent
/// sessions writing status, the lock held most of the time) one short write
/// a person waits on could queue behind the whole crowd for seconds
/// ("workspace_group.update (no reply within 2.0 seconds)"). Locks taken
/// inside an [`interactive_scope`] go next: while one waits, a plain locker
/// neither queues for the lock nor keeps one it just won, up to
/// [`MAX_INTERACTIVE_STREAK`] interactive turns in a row; then the
/// interactive lockers step aside the same way until a plain one has had
/// its turn.
pub(crate) struct SignaledMutex<T> {
    value: Mutex<T>,
    release_epoch: Mutex<u64>,
    released: Condvar,
    /// Interactive lockers waiting for `value`.
    interactive_waiters: AtomicUsize,
    /// Interactive acquisitions since the last plain one.
    interactive_streak: AtomicUsize,
    /// Plain lockers waiting for `value`.
    plain_waiters: AtomicUsize,
    /// Plain acquisitions so far (test probe, [`plain_turns_ahead_on_this_thread`]).
    #[cfg(test)]
    plain_turns: std::sync::atomic::AtomicU64,
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
            interactive_waiters: AtomicUsize::new(0),
            interactive_streak: AtomicUsize::new(0),
            plain_waiters: AtomicUsize::new(0),
            #[cfg(test)]
            plain_turns: std::sync::atomic::AtomicU64::new(0),
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
        let waited = waited_from.elapsed();
        self.stats.acquired(site, waited, blocker);
        #[cfg(test)]
        REGISTRY_LOCKS_TAKEN.with(|taken| taken.set(taken.get() + 1));
        SignaledMutexGuard {
            value: Some(value),
            owner: self,
            site,
            waited,
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
        let interactive = in_interactive_scope();
        #[cfg(test)]
        let turns_before = self.plain_turns.load(Ordering::Acquire);
        let locked = if interactive { self.lock_interactive() } else { self.lock_plain() };
        // Read with the lock held: each plain turn counted since `turns_before` took the lock in front of this
        // take (a plain take counts itself once, which is not in front of it).
        #[cfg(test)]
        PLAIN_TURNS_AHEAD.with(|ahead| {
            let turns = self.plain_turns.load(Ordering::Acquire).saturating_sub(turns_before);
            ahead.set(ahead.get() + turns.saturating_sub(u64::from(!interactive)));
        });
        match locked {
            Ok(value) => Ok(self.guard(value, site, waited_from, blocker)),
            Err(error) => {
                Err(PoisonError::new(self.guard(error.into_inner(), site, waited_from, blocker)))
            }
        }
    }

    /// Waits for the current holder, and for waiting plain lockers only once
    /// the streak cap is reached.
    fn lock_interactive(&self) -> LockResult<MutexGuard<'_, T>> {
        self.interactive_waiters.fetch_add(1, Ordering::AcqRel);
        let locked = loop {
            self.wait_while(|| self.plain_goes_first());
            match self.value.lock() {
                // Plain lockers are owed a turn: hand the lock to one.
                Ok(value) if self.plain_goes_first() => drop(value),
                locked => break locked,
            }
        };
        self.interactive_streak.fetch_add(1, Ordering::AcqRel);
        // Plain lockers wait for this count to reach zero; the guard's drop
        // (every release) wakes them.
        self.interactive_waiters.fetch_sub(1, Ordering::AcqRel);
        locked
    }

    fn lock_plain(&self) -> LockResult<MutexGuard<'_, T>> {
        self.plain_waiters.fetch_add(1, Ordering::AcqRel);
        let locked = loop {
            self.wait_while(|| self.interactive_goes_first());
            match self.value.lock() {
                // An interactive locker queued meanwhile: hand the lock to it
                // (this unlock wakes a waiter) and queue again after it.
                Ok(value) if self.interactive_goes_first() => drop(value),
                locked => break locked,
            }
        };
        self.interactive_streak.store(0, Ordering::Release);
        self.plain_waiters.fetch_sub(1, Ordering::AcqRel);
        // With the lock held, so a waiter that takes the lock next reads this turn.
        #[cfg(test)]
        self.plain_turns.fetch_add(1, Ordering::AcqRel);
        locked
    }

    /// An interactive locker waits and has not used up its streak.
    fn interactive_goes_first(&self) -> bool {
        self.interactive_waiters.load(Ordering::Acquire) > 0
            && self.interactive_streak.load(Ordering::Acquire) < MAX_INTERACTIVE_STREAK
    }

    /// The interactive streak is used up and a plain locker waits. Never
    /// true together with [`Self::interactive_goes_first`], so the two
    /// kinds never both step aside.
    fn plain_goes_first(&self) -> bool {
        self.plain_waiters.load(Ordering::Acquire) > 0
            && self.interactive_streak.load(Ordering::Acquire) >= MAX_INTERACTIVE_STREAK
    }

    /// Wait while `owed` (the other kind goes first). Every release
    /// notifies `released`, and the other kind releases after it took the
    /// lock, so the wait ends at most one hold after its turn; the short
    /// timeout only bounds a missed wakeup. Nothing waits here at idle.
    fn wait_while(&self, owed: impl Fn() -> bool) {
        if !owed() {
            return;
        }
        let mut epoch = self.release_epoch.lock().unwrap_or_else(PoisonError::into_inner);
        while owed() {
            epoch = self
                .released
                .wait_timeout(epoch, Duration::from_millis(20))
                .unwrap_or_else(PoisonError::into_inner)
                .0;
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

#[cfg(test)]
thread_local! {
    static PLAIN_TURNS_AHEAD: Cell<u64> = const { Cell::new(0) };
}

/// How many plain lockers took the registry lock in front of this thread's own takes, summed over its takes (test
/// hook): for each `lock` call, the plain acquisitions between the call and its return. The holder at the call
/// is not a turn in front (at most one such hold per take); a plain locker that has the lock at the call and
/// has not counted itself yet can add 1 to that take. Only `lock` counts: `try_lock` and `lock_until` do not. A
/// test proves with it that a person's request does not queue behind a crowd of writers by counting turns, with
/// no timing: a wait in wall time grows with the host's load, a place in the queue does not.
#[cfg(test)]
pub(crate) fn plain_turns_ahead_on_this_thread() -> u64 {
    PLAIN_TURNS_AHEAD.with(Cell::get)
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
    waited: Duration,
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
        self.owner.stats.released(self.site, self.acquired_at.elapsed(), self.waited);
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
/// Its acquisitions feed hold and wait telemetry by `#[track_caller]` site
/// (`server-stats` `locks.state`), as the registry's do.
pub(crate) struct StateMutex {
    value: Mutex<State>,
    stats: crate::diagnostics::LockStats,
    /// The routing tables of the last finished change (R-DAEMON-STATE stage S1): a guard that changed them publishes
    /// them when it drops, under the lock, so `Mux::surface` reads them with one atomic load and never waits.
    routes: arc_swap::ArcSwap<crate::route_table::RouteSnapshot>,
    /// Whether guards publish `routes` (the stage S1 switch). Off, `routes` holds no table of the state, so a route
    /// write never copies a table a snapshot shares. Read and written only under the lock.
    publish_routes: std::sync::atomic::AtomicBool,
}

/// A held mux state lock.
pub(crate) struct StateGuard<'a> {
    /// Dropped after `Drop::drop` records the release (fields drop after
    /// the body), so the release is recorded while the lock is held.
    guard: MutexGuard<'a, State>,
    stats: &'a crate::diagnostics::LockStats,
    /// The mutex, for `Drop::drop` to publish the routing tables when they changed (R-DAEMON-STATE stage S1).
    owner: &'a StateMutex,
    site: crate::diagnostics::LockSite,
    waited: Duration,
    acquired_at: Instant,
    /// Lock rank `MuxState` (crate::lock_rank), released after the lock.
    _rank: HeldRank,
    /// The routing snapshot this guard replaced. It drops after `guard` (fields drop in order), so the tables and
    /// surfaces it may hold last are freed after the lock is released, never under it.
    retired: Option<std::sync::Arc<crate::route_table::RouteSnapshot>>,
    /// Whether this thread was already unwinding when it took the lock, as `std::sync::MutexGuard` records it.
    panicking_at_lock: bool,
}

impl<'a> StateGuard<'a> {
    fn new(
        guard: MutexGuard<'a, State>,
        owner: &'a StateMutex,
        site: crate::diagnostics::LockSite,
        waited_from: Instant,
        blocker: Option<crate::diagnostics::LockSite>,
    ) -> StateGuard<'a> {
        let stats = &owner.stats;
        // The journal writer must never take state (counted in release):
        // the lock order puts it after the writer's rank.
        let on_writer = crate::workspace_registry::registry_connection::in_journal_writer_commit();
        if on_writer {
            crate::diagnostics::writer_took_registry_lock();
        }
        debug_assert!(!on_writer, "the journal writer took the mux state lock");
        crate::workspace_registry::registry_connection::note_state_lock(true);
        #[cfg(test)]
        STATE_LOCKS_TAKEN.with(|taken| taken.set(taken.get() + 1));
        let waited = waited_from.elapsed();
        stats.acquired(site, waited, blocker);
        StateGuard {
            guard,
            stats,
            owner,
            site,
            waited,
            acquired_at: Instant::now(),
            _rank: HeldRank::record(LockRank::MuxState, STATE_LOCK_NAME),
            retired: None,
            panicking_at_lock: std::thread::panicking(),
        }
    }
}

const STATE_LOCK_NAME: &str = "mux.state";

#[cfg(test)]
thread_local! {
    static STATE_LOCKS_TAKEN: Cell<u64> = const { Cell::new(0) };
}

#[cfg(test)]
thread_local! {
    static REGISTRY_LOCKS_TAKEN: Cell<u64> = const { Cell::new(0) };
}

/// How many times this thread has taken the workspace registry lock (test hook): a test proves a read never takes
/// the writer's lock by counting, with no timing (REGISTRY WAL, the snapshot read).
#[cfg(test)]
pub(crate) fn registry_locks_taken_on_this_thread() -> u64 {
    REGISTRY_LOCKS_TAKEN.with(Cell::get)
}

/// How many times this thread has taken the mux state lock (test hook): a test proves a path never takes the session
/// lock by counting, with no timing (TYPING UNDER LOAD F4).
#[cfg(test)]
pub(crate) fn state_locks_taken_on_this_thread() -> u64 {
    STATE_LOCKS_TAKEN.with(Cell::get)
}

impl Drop for StateGuard<'_> {
    fn drop(&mut self) {
        // Publish the routing tables a change replaced, while the lock is still held, so publications follow the
        // order of the changes (R-DAEMON-STATE stage S1). A guard that changed no route compares three pointers. A
        // panic that began while this guard held the lock cut its change short: the `MutexGuard` field poisons the
        // mutex right after this (the same test std makes), and the half-made tables are never published.
        let owner = self.owner;
        let cut_short = std::thread::panicking() && !self.panicking_at_lock;
        if !cut_short
            && owner.publish_routes.load(Ordering::Relaxed)
            && !owner.routes.load().is_current(&self.guard)
        {
            let published = std::sync::Arc::new(crate::route_table::RouteSnapshot::of(&self.guard));
            self.retired = Some(owner.routes.swap(published));
        }
        // Record the release while the lock is still held, so the next
        // holder's record is never erased by this older unlock.
        self.stats.released(self.site, self.acquired_at.elapsed(), self.waited);
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
    /// `publish_routes` is the mux's stage S1 switch (R-DAEMON-STATE).
    pub(crate) fn new(state: State, publish_routes: bool) -> Self {
        let routes = arc_swap::ArcSwap::from_pointee(if publish_routes {
            crate::route_table::RouteSnapshot::of(&state)
        } else {
            crate::route_table::RouteSnapshot::default()
        });
        Self {
            value: Mutex::new(state),
            stats: crate::diagnostics::LockStats::new(),
            routes,
            publish_routes: std::sync::atomic::AtomicBool::new(publish_routes),
        }
    }

    /// Turns route publication on or off (tests); on, the current tables are published first, under the lock.
    #[cfg(test)]
    pub(crate) fn set_route_publishing_for_test(&self, on: bool) {
        let state = self.value.lock().unwrap_or_else(PoisonError::into_inner);
        let snapshot = if on {
            crate::route_table::RouteSnapshot::of(&state)
        } else {
            crate::route_table::RouteSnapshot::default()
        };
        self.routes.store(std::sync::Arc::new(snapshot));
        self.publish_routes.store(on, Ordering::Relaxed);
    }

    /// Whether a writer panicked while it held the session state.
    pub(crate) fn is_poisoned(&self) -> bool {
        self.value.is_poisoned()
    }

    /// The routing tables as of the last finished change: one atomic load, never a wait (R-DAEMON-STATE stage S1).
    pub(crate) fn routes(
        &self,
    ) -> arc_swap::Guard<std::sync::Arc<crate::route_table::RouteSnapshot>> {
        self.routes.load()
    }

    /// Hold and wait telemetry by site (`server-stats` `locks.state`).
    pub(crate) fn stats(&self) -> &crate::diagnostics::LockStats {
        &self.stats
    }

    #[track_caller]
    pub(crate) fn lock(&self) -> LockResult<StateGuard<'_>> {
        HeldRank::check(LockRank::MuxState, STATE_LOCK_NAME);
        let site = std::panic::Location::caller();
        let waited_from = Instant::now();
        let blocker = self.stats.wait_started();
        match self.value.lock() {
            Ok(guard) => Ok(StateGuard::new(guard, self, site, waited_from, blocker)),
            Err(poison) => Err(PoisonError::new(StateGuard::new(
                poison.into_inner(),
                self,
                site,
                waited_from,
                blocker,
            ))),
        }
    }

    /// The state lock if it is free now (the accept loop, which never waits
    /// for it, and the snapshot reader that builds, `resource_api/committed_snapshot.rs`).
    /// A try cannot deadlock, so it skips the rank check `lock` makes.
    #[track_caller]
    pub(crate) fn try_lock(&self) -> TryLockResult<StateGuard<'_>> {
        let site = std::panic::Location::caller();
        let waited_from = Instant::now();
        match self.value.try_lock() {
            Ok(guard) => Ok(StateGuard::new(guard, self, site, waited_from, None)),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => Err(TryLockError::Poisoned(PoisonError::new(
                StateGuard::new(poison.into_inner(), self, site, waited_from, None),
            ))),
        }
    }
}

/// The state lock plus a hold of the registry connection taken before it.
/// Fields drop in order: state first, then the connection. A flow never
/// waits for a journal writer receipt while it holds one: it drops it first
/// (the writer needs the connection, and state readers must not queue
/// behind the disk).
pub(crate) struct PinnedState<'a> {
    state: StateGuard<'a>,
    _connection: RegistryConnectionPin,
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
    /// The test hook a state mutation runs after the part that reads the
    /// session (`set_state_commit_after_apply_hook_for_test`); nothing
    /// outside tests.
    pub(crate) fn run_state_commit_after_apply_hook(&self) {
        #[cfg(test)]
        if let Some(hook) = self.state_commit_after_apply.lock().unwrap().clone() {
            hook();
        }
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
        // Wait for the answers of earlier indeterminate commits before the
        // pin: the writer needs the connection to commit and answer, so a
        // wait under the pin could only run out. The caller holds the
        // registry, so no new indeterminate commit appears after this. A
        // commit still unanswered stays; the flow's own prepare refuses to
        // build on it (`drain_unsettled` without waiting).
        let _ = registry.connection.drain_unsettled();
        let connection = registry.connection.pin();
        let (mut pinned, poisoned) = match self.state.lock() {
            Ok(state) => (PinnedState { state, _connection: connection }, false),
            Err(poison) => {
                (PinnedState { state: poison.into_inner(), _connection: connection }, true)
            }
        };
        // Non-blocking: the answers that can arrive were taken before the
        // pin; one still unanswered stays for a later holder, and the
        // prepare paths refuse to build on it (drain_unsettled).
        self.settle_registry_receipts(registry, &mut pinned.state);
        if poisoned { Err(PoisonError::new(pinned)) } else { Ok(pinned) }
    }
}
