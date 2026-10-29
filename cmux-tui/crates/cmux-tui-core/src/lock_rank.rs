//! Debug-build lock ranks (lockdep style) for the mux and surface locks.
//!
//! Order, outer first: workspace registry -> journal writer -> registry
//! connection -> `Mux::state` -> PTY input turn -> Kitty limits request ->
//! PTY geometry -> terminal -> PTY runtime -> Kitty limits -> attach taps ->
//! leaf. A thread may acquire a ranked lock only when its rank is
//! after every rank the thread already holds. A blocking acquisition at a rank
//! equal to or before a held rank panics in debug and test builds and names
//! both locks, so every test, Testbox gate and debug dogfood build checks the
//! order on every path it runs. `try_lock` cannot deadlock: it is recorded but
//! not checked. In release builds the rank, the name and the thread-local
//! stack are compiled out; [`RankedMutex`] is then a plain [`Mutex`]. Holds
//! of the ranks up to `Mux::state` are counted in every build: lock
//! admission never makes a thread wait while it holds one
//! ([`HeldRank::may_yield`]).
//!
//! Debug and test builds also time a contended [`RankedMutex::lock`]: the
//! lock is tried first and only a failed try reads the clock, and a wait of
//! `cmux_threads::LOCK_WAIT_BUDGET` (2 ms) or more on a thread that
//! disallows blocking records a `lock-wait` site at the caller
//! (`cmux_threads::lock_wait::note_timed_lock_wait`), read with
//! `cmux_threads::blocking::snapshot`. Chromium times only the contended
//! path the same way: base/synchronization/lock_impl.h (`LockImpl::Lock`
//! tries first) and base/synchronization/lock_metrics_recorder.h.

use std::ops::{Deref, DerefMut};
#[cfg(debug_assertions)]
use std::panic::Location;
use std::sync::{LockResult, Mutex, MutexGuard, PoisonError, TryLockError, TryLockResult};
#[cfg(debug_assertions)]
use std::time::Instant;

/// Rank of a ranked lock. A thread acquires ranks in ascending order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum LockRank {
    /// `Mux::workspace_registry` (the registry `SignaledMutex`).
    WorkspaceRegistry,
    /// Not a lock: the journal writer thread holds this rank for each loop
    /// iteration (`JournalWriterCommitScope`). It ranks after the registry,
    /// so the writer can never take the registry lock: a request thread
    /// holds the registry while it waits for a writer receipt.
    JournalWriter,
    /// `RegistryConnection`, the SQLite connection lock. It is reentrant for
    /// its holder; only the first acquisition on a thread is ranked.
    RegistryConnection,
    /// `Mux::state`.
    MuxState,
    /// Not a mutex: a terminal's input turn, taken from its
    /// `pty_input_fifo::PtyInputFifo` and held for one whole input (a `send` with
    /// its paste and Return, an INPUT frame, an image paste, a clear-history
    /// key). The write it holds the turn for takes the terminal (a paste's
    /// bracketed mode) and the runtime lock, so it ranks before both. It
    /// ranks after `Mux::state`, so an input turn never takes the registry or
    /// the state lock: a turn can wait behind a write the child does not
    /// read, and nothing daemon-wide may wait with it.
    PtyInput,
    /// `PtyTerminalRuntime::kitty_limits_request`, held for a whole Kitty
    /// limits request, including the runtime, terminal and taps it takes.
    KittyLimitsRequest,
    /// `PtyTerminalRuntime::geometry`.
    Geometry,
    /// `PtyTerminalRuntime::term`.
    Terminal,
    /// `PtyTerminalRuntime::runtime`.
    Runtime,
    /// `PtyTerminalRuntime::kitty_graphics_limits`; a commit resynchronizes
    /// the attach taps while it holds it.
    KittyLimits,
    /// `PtyTerminalRuntime::taps` (byte and snapshot attach taps); a tap
    /// update reads the last attach colors.
    AttachTaps,
    /// Locks that never take another ranked lock while held (render hub,
    /// title, mouse encoders, attach colors, `Mux::default_colors`).
    Leaf,
}

#[cfg(debug_assertions)]
mod held {
    use super::LockRank;
    use std::cell::RefCell;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Held {
        rank: LockRank,
        name: &'static str,
        id: u64,
    }

    thread_local! {
        static HELD: RefCell<Vec<Held>> = const { RefCell::new(Vec::new()) };
    }

    static NEXT_ID: AtomicU64 = AtomicU64::new(1);

    #[track_caller]
    #[allow(
        clippy::panic,
        reason = "INVARIANT: the debug and test lock-order DCHECK; release builds compile it out"
    )]
    pub(super) fn check(rank: LockRank, name: &'static str) {
        let violation = HELD.with(|held| {
            held.borrow()
                .iter()
                .max_by_key(|entry| entry.rank)
                .filter(|inner| inner.rank >= rank)
                .map(|inner| (inner.name, inner.rank))
        });
        // Panic outside the closure so the location is the acquisition site.
        if let Some((held_name, held_rank)) = violation {
            // crash-allow: the debug and test lock-order assertion; release builds compile it out.
            panic!(
                "lock order violation: acquiring {name} ({rank:?}) while this thread holds \
                 {held_name} ({held_rank:?}); the order is workspace.registry > journal.writer > \
                 registry.connection > mux.state > pty.input > pty.kitty_limits_request > \
                 pty.geometry > pty.term > pty.runtime > pty.kitty_graphics_limits > \
                 pty.taps > leaf (see PtyTerminalRuntime)"
            );
        }
    }

    pub(super) fn push(rank: LockRank, name: &'static str) -> u64 {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        HELD.with(|held| held.borrow_mut().push(Held { rank, name, id }));
        id
    }

    /// Lock admission found no counted rank held (`free`): then no rank of
    /// any kind may be held, or the thread would yield while holding a lock.
    #[track_caller]
    pub(super) fn assert_none_held_if(free: bool) {
        if !free {
            return;
        }
        let held_name = HELD.with(|held| held.borrow().first().map(|entry| entry.name));
        debug_assert!(
            held_name.is_none(),
            "lock admission would yield while this thread holds {held_name:?}: nothing \
             waits for another class while it holds a ranked lock"
        );
    }

    /// `work` must not run while this thread holds `rank`.
    #[track_caller]
    pub(super) fn assert_not_held(rank: LockRank, work: &'static str) {
        let held_name = HELD.with(|held| {
            held.borrow().iter().find(|entry| entry.rank == rank).map(|entry| entry.name)
        });
        debug_assert!(held_name.is_none(), "{work} ran while this thread holds {held_name:?}");
    }

    pub(super) fn pop(id: u64) {
        // Guards may drop out of order, and during thread teardown.
        let _ = HELD.try_with(|held| {
            let mut held = held.borrow_mut();
            if let Some(index) = held.iter().rposition(|entry| entry.id == id) {
                held.remove(index);
            }
        });
    }
}

/// Debug and test builds: panic when this thread holds `rank` (`work` names
/// what must run outside it, as the mux event fan-out runs outside
/// `Mux::state`). Release builds compile it out.
#[track_caller]
#[inline]
pub(crate) fn debug_assert_rank_not_held(rank: LockRank, work: &'static str) {
    #[cfg(debug_assertions)]
    held::assert_not_held(rank, work);
    #[cfg(not(debug_assertions))]
    let _ = (rank, work);
}

/// The last rank whose holds are counted in every build: lock admission
/// (`server::priority_gate`) gates the registry, connection and state locks,
/// and the lock order allows a thread to hold only these ranks while it
/// acquires one of them.
const LAST_ADMISSION_RANK: LockRank = LockRank::MuxState;

thread_local! {
    /// Holds of ranks up to [`LAST_ADMISSION_RANK`] on this thread, counted
    /// in release builds too.
    static ADMISSION_RANK_HOLDS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

impl LockRank {
    /// Every lock: a thread lowered to UTILITY for an automation request is
    /// raised before it waits for one and while it holds it
    /// (`cmux_tui_platform::qos::LockBoost`), so a
    /// frontend request or the PTY echo path never waits behind a UTILITY
    /// thread. Release builds rank every `RankedMutex` as `Leaf`, so the rule
    /// cannot depend on the rank. The journal writer rank is not a lock.
    const fn raises_holder(self) -> bool {
        !matches!(self, Self::JournalWriter)
    }

    fn boost(self) -> cmux_tui_platform::qos::LockBoost {
        if self.raises_holder() {
            cmux_tui_platform::qos::LockBoost::hold()
        } else {
            cmux_tui_platform::qos::LockBoost::none()
        }
    }
}

/// One rank this thread holds; dropping it releases the rank. In release
/// builds only the holder's QoS boost and the count of the ranks lock
/// admission reads are kept.
pub(crate) struct HeldRank {
    #[cfg(debug_assertions)]
    id: u64,
    counted: bool,
    /// Dropped with the rank, after the lock the guard releases first.
    _boost: cmux_tui_platform::qos::LockBoost,
}

/// A checked rank this thread is about to block on: the boost is taken
/// before the wait, so the lock is never handed to a lowered waiter.
#[must_use = "the boost holds only until the lock is recorded with `held`"]
pub(crate) struct RankWait {
    rank: LockRank,
    name: &'static str,
    boost: cmux_tui_platform::qos::LockBoost,
}

impl RankWait {
    /// A re-entry of a reentrant lock this thread holds: no order check and
    /// no wait.
    #[inline]
    pub(crate) fn reentry(rank: LockRank, name: &'static str) -> Self {
        Self { rank, name, boost: rank.boost() }
    }

    /// Record that this thread now holds the rank it waited for.
    #[inline]
    pub(crate) fn held(self) -> HeldRank {
        HeldRank::with_boost(self.rank, self.name, self.boost)
    }
}

impl HeldRank {
    /// Check that `rank` may be acquired now. Call before blocking on the lock.
    #[track_caller]
    #[inline]
    pub(crate) fn check(rank: LockRank, name: &'static str) {
        #[cfg(debug_assertions)]
        held::check(rank, name);
        #[cfg(not(debug_assertions))]
        let _ = (rank, name);
    }

    /// [`Self::check`], then raise a lowered thread before it blocks on the
    /// lock; [`RankWait::held`] records the acquisition.
    #[track_caller]
    #[inline]
    pub(crate) fn acquire(rank: LockRank, name: &'static str) -> RankWait {
        Self::check(rank, name);
        RankWait { rank, name, boost: rank.boost() }
    }

    /// Record that this thread now holds `rank`, taken without a wait (a
    /// `try_lock`, a re-entry).
    #[inline]
    pub(crate) fn record(rank: LockRank, name: &'static str) -> Self {
        Self::with_boost(rank, name, rank.boost())
    }

    #[inline]
    fn with_boost(
        rank: LockRank,
        name: &'static str,
        _boost: cmux_tui_platform::qos::LockBoost,
    ) -> Self {
        let counted = rank <= LAST_ADMISSION_RANK;
        if counted {
            ADMISSION_RANK_HOLDS.with(|holds| holds.set(holds.get() + 1));
        }
        #[cfg(debug_assertions)]
        {
            Self { id: held::push(rank, name), counted, _boost }
        }
        #[cfg(not(debug_assertions))]
        {
            let _ = name;
            Self { counted, _boost }
        }
    }

    /// True when this thread holds no ranked lock, so a lock admission may
    /// make it wait (`server::priority_gate`): a thread that yields while it
    /// holds a lock could hold up the very request it yields to. Debug and
    /// test builds check the whole rank stack against the count.
    #[inline]
    pub(crate) fn may_yield() -> bool {
        let free = ADMISSION_RANK_HOLDS.with(std::cell::Cell::get) == 0;
        #[cfg(debug_assertions)]
        held::assert_none_held_if(free);
        free
    }
}

impl Drop for HeldRank {
    #[inline]
    fn drop(&mut self) {
        #[cfg(debug_assertions)]
        held::pop(self.id);
        if self.counted {
            // Guards may drop during thread teardown.
            let _ = ADMISSION_RANK_HOLDS.try_with(|holds| holds.set(holds.get().saturating_sub(1)));
        }
    }
}

/// A [`Mutex`] with a lock rank. The API mirrors `std::sync::Mutex`.
pub(crate) struct RankedMutex<T> {
    inner: Mutex<T>,
    #[cfg(debug_assertions)]
    rank: LockRank,
    #[cfg(debug_assertions)]
    name: &'static str,
    /// Test builds only: what a test reads of [`Self::wait_timed`].
    #[cfg(test)]
    probe: WaitProbe,
}

/// The threads past a failed try of a [`RankedMutex`], so a test starts a
/// hold only once its waiter is contended, and the last wait it measured.
#[cfg(test)]
#[derive(Default)]
struct WaitProbe {
    waiting: std::sync::atomic::AtomicU32,
    last_wait_nanos: std::sync::atomic::AtomicU64,
}

impl<T> RankedMutex<T> {
    pub(crate) fn new(rank: LockRank, name: &'static str, value: T) -> Self {
        #[cfg(not(debug_assertions))]
        let _ = (rank, name);
        Self {
            inner: Mutex::new(value),
            #[cfg(debug_assertions)]
            rank,
            #[cfg(debug_assertions)]
            name,
            #[cfg(test)]
            probe: WaitProbe::default(),
        }
    }

    #[cfg(debug_assertions)]
    fn rank(&self) -> (LockRank, &'static str) {
        (self.rank, self.name)
    }

    #[cfg(not(debug_assertions))]
    fn rank(&self) -> (LockRank, &'static str) {
        (LockRank::Leaf, "")
    }

    #[track_caller]
    #[inline]
    pub(crate) fn lock(&self) -> LockResult<RankedGuard<'_, T>> {
        let (rank, name) = self.rank();
        let wait = HeldRank::acquire(rank, name);
        match self.lock_timed() {
            Ok(guard) => Ok(RankedGuard { guard, _held: wait.held() }),
            Err(poison) => Err(PoisonError::new(RankedGuard {
                guard: poison.into_inner(),
                _held: wait.held(),
            })),
        }
    }

    /// The inner lock, tried first; a contended wait is timed
    /// ([`Self::wait_timed`]).
    #[cfg(debug_assertions)]
    #[track_caller]
    #[inline]
    fn lock_timed(&self) -> LockResult<MutexGuard<'_, T>> {
        match self.inner.try_lock() {
            Ok(guard) => Ok(guard),
            Err(TryLockError::Poisoned(poison)) => Err(poison),
            Err(TryLockError::WouldBlock) => self.wait_timed(Location::caller()),
        }
    }

    #[cfg(not(debug_assertions))]
    #[inline]
    fn lock_timed(&self) -> LockResult<MutexGuard<'_, T>> {
        self.inner.lock()
    }

    /// Waits for the inner lock after a failed try and reports the wait for
    /// `site`. The report never panics, so it may run with the guard taken.
    #[cfg(debug_assertions)]
    #[cold]
    #[inline(never)]
    fn wait_timed(&self, site: &'static Location<'static>) -> LockResult<MutexGuard<'_, T>> {
        let since = Instant::now();
        #[cfg(test)]
        self.probe.waiting.fetch_add(1, std::sync::atomic::Ordering::AcqRel);
        let locked = self.inner.lock();
        let waited = since.elapsed();
        #[cfg(test)]
        {
            let nanos = u64::try_from(waited.as_nanos()).unwrap_or(u64::MAX);
            self.probe.last_wait_nanos.store(nanos, std::sync::atomic::Ordering::Release);
            self.probe.waiting.fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
        }
        cmux_threads::lock_wait::note_timed_lock_wait(waited, site);
        locked
    }

    #[inline]
    pub(crate) fn try_lock(&self) -> TryLockResult<RankedGuard<'_, T>> {
        let (rank, name) = self.rank();
        match self.inner.try_lock() {
            Ok(guard) => Ok(RankedGuard { guard, _held: HeldRank::record(rank, name) }),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => {
                Err(TryLockError::Poisoned(PoisonError::new(RankedGuard {
                    guard: poison.into_inner(),
                    _held: HeldRank::record(rank, name),
                })))
            }
        }
    }
}

/// A held [`RankedMutex`]. The lock is released before its rank.
pub(crate) struct RankedGuard<'a, T> {
    guard: MutexGuard<'a, T>,
    _held: HeldRank,
}

impl<T> Deref for RankedGuard<'_, T> {
    type Target = T;

    #[inline]
    fn deref(&self) -> &T {
        &self.guard
    }
}

impl<T> DerefMut for RankedGuard<'_, T> {
    #[inline]
    fn deref_mut(&mut self) -> &mut T {
        &mut self.guard
    }
}

#[cfg(all(test, debug_assertions))]
mod tests {
    use super::{LockRank, RankedMutex};
    use cmux_threads::{BlockingKind, BlockingMode, LOCK_WAIT_BUDGET, ThreadQos};
    use std::panic::Location;
    use std::sync::Arc;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    /// The `file:line` of a lock call; `lock` returns it from the line it
    /// locks on.
    type Site = (&'static str, u32);

    /// A contended lock: the `lock-wait` records at its site and the wait
    /// the lock measured.
    struct Contended {
        count: u64,
        waited: Duration,
    }

    fn lock_wait_count((file, line): Site) -> u64 {
        cmux_threads::blocking::snapshot()
            .site(file, line)
            .filter(|site| site.kinds.contains(BlockingKind::LockWait))
            .map_or(0, |site| site.count)
    }

    /// Starts `body` on a thread that disallows blocking, in panic mode.
    fn spawn_disallowed<R: Send + 'static>(
        body: impl FnOnce() -> R + Send + 'static,
    ) -> std::thread::JoinHandle<R> {
        cmux_threads::spawn("lock-rank-waiter", ThreadQos::UserInitiated, move || {
            cmux_threads::with_blocking_disallowed(|| {
                cmux_threads::blocking::with_mode(BlockingMode::Panic, body)
            })
        })
        .expect("spawn waiter")
    }

    fn on_disallowed_thread<R: Send + 'static>(body: impl FnOnce() -> R + Send + 'static) -> R {
        cmux_threads::checked::sync::join(spawn_disallowed(body)).expect("waiter")
    }

    /// Holds a ranked mutex while a thread that disallows blocking, in panic
    /// mode, locks it with `lock`. The hold starts only once the waiter is
    /// past its failed try (as `contend` in cmux-threads' lock_wait tests),
    /// so the wait the lock measures lasts at least `hold` under any load.
    fn contend(hold: Duration, lock: fn(&RankedMutex<u32>) -> Site) -> Contended {
        let mutex = Arc::new(RankedMutex::new(LockRank::Leaf, "test.leaf", 0_u32));
        let guard = mutex.lock().expect("holder lock");
        let waiter = spawn_disallowed({
            let mutex = Arc::clone(&mutex);
            move || lock(&mutex)
        });
        while mutex.probe.waiting.load(Ordering::Acquire) == 0 {
            std::thread::yield_now();
        }
        cmux_threads::checked::sync::sleep(hold);
        drop(guard);
        let site = cmux_threads::checked::sync::join(waiter).expect("waiter");
        let waited = Duration::from_nanos(mutex.probe.last_wait_nanos.load(Ordering::Acquire));
        Contended { count: lock_wait_count(site), waited }
    }

    #[test]
    fn five_ms_holder_records_one_lock_wait_site_without_panic() {
        let contended = contend(Duration::from_millis(5), |mutex| {
            let (site, guard) = ((file!(), line!()), mutex.lock().expect("waiter lock"));
            drop(guard);
            site
        });
        assert!(contended.waited >= Duration::from_millis(5), "waited {:?}", contended.waited);
        assert_eq!(contended.count, 1);
    }

    /// A 0.1 ms hold bounds the measured wait from below only, so the
    /// record follows the wait the lock measured; a 0.1 ms wait given
    /// directly records nothing.
    #[test]
    fn tenth_ms_holder_records_no_lock_wait_site() {
        let contended = contend(Duration::from_micros(100), |mutex| {
            let (site, guard) = ((file!(), line!()), mutex.lock().expect("waiter lock"));
            drop(guard);
            site
        });
        assert!(contended.waited >= Duration::from_micros(100), "waited {:?}", contended.waited);
        assert_eq!(contended.count, u64::from(contended.waited >= LOCK_WAIT_BUDGET));

        let site = on_disallowed_thread(|| {
            let site = Location::caller();
            cmux_threads::lock_wait::note_timed_lock_wait(Duration::from_micros(100), site);
            (site.file(), site.line())
        });
        assert_eq!(lock_wait_count(site), 0);
    }

    #[test]
    fn an_uncontended_lock_records_no_lock_wait_site() {
        let mutex = Arc::new(RankedMutex::new(LockRank::Leaf, "test.leaf", 0_u32));
        let site = on_disallowed_thread({
            let mutex = Arc::clone(&mutex);
            move || {
                let (site, guard) = ((file!(), line!()), mutex.lock().expect("lock"));
                drop(guard);
                site
            }
        });
        assert_eq!(mutex.probe.last_wait_nanos.load(Ordering::Acquire), 0);
        assert_eq!(lock_wait_count(site), 0);
    }
}
