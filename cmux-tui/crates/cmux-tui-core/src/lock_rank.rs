//! Lock ranks (lockdep style) for the cmux-tui-core locks.
//!
//! cmux-tui-core uses [`Mutex`], [`MutexGuard`] and [`Condvar`] from this
//! module in place of `std::sync`. A lock's rank is part of its type:
//! `RankedMutex<T, { rank::PTY_TERM }>`, built with `RankedMutex::new`;
//! [`Mutex`] is the unranked form, which is not checked. A thread acquires
//! ranked locks in ascending rank order. In debug and test builds a blocking
//! acquisition at a rank equal to or below a rank the thread holds panics,
//! naming both locks and both acquisition sites, so
//! every test, Testbox gate and debug dogfood build checks the order on every
//! path it runs. `try_lock` cannot deadlock: it is recorded but not checked.
//! Release builds compile the ranks and the thread-local stack out; the types
//! are then plain `std::sync` wrappers.
//!
//! The rank table below follows the order recorded across the whole
//! workspace test suite (plans/cmux-next/refactor-log/surface-rs.md, "Lock
//! ranks"): every 10 for inserts; 2000-2990 holds the workspace registry,
//! journal writer and registry connection ranks.

use std::ops::{Deref, DerefMut};
use std::sync::{LockResult, PoisonError, TryLockError, TryLockResult, WaitTimeoutResult};
use std::time::Duration;

/// Rank constants, outer locks first.
#[rustfmt::skip]
pub mod rank {
    /// Not checked.
    pub const UNRANKED: u16 = 0;
    // Pre-state locks: operation gates, test hooks, client sizing.
    pub const CHECKPOINT_PATH_LOCK: u16 = 100;
    pub const AGENT_SESSION_READER_SLOT: u16 = 110;
    pub const CONVERSATION_STORE_GATE: u16 = 120;
    pub const CONVERSATION_STORE: u16 = 130;
    pub const MUX_AGENT_ROSTER_FOLD: u16 = 140;
    pub const MUX_LAYOUT_UNDO_BEFORE_COMMIT_HOOK: u16 = 150;
    pub const MUX_SCREEN_CREATED_HOOK: u16 = 160;
    pub const MUX_SIDEBAR_PLUGIN: u16 = 170;
    pub const MUX_EXIT_SETTLE_GATE: u16 = 180;
    pub const CLOSED_HISTORY_REOPEN: u16 = 190;
    pub const FRONTEND_BROWSER_KEYED_CREATION: u16 = 200;
    pub const MUX_RESOURCE_CREATION_HANDOFF: u16 = 210;
    pub const MUX_RESOURCE_CREATION_EXECUTION: u16 = 220;
    pub const MUX_PROVIDER_WORKSPACE: u16 = 230;
    pub const MUX_AGENT_HOOK_FENCES: u16 = 240;
    pub const MUX_VIEWPORT_SPLIT_AFTER_SPAWN_HOOK: u16 = 250;
    pub const MUX_WORKSPACE_LIFECYCLE: u16 = 260;
    pub const MUX_CLIENT_SIZING_LIFECYCLE: u16 = 270;
    pub const MUX_TERMINAL_CREATE_AFTER_RESERVATION_HOOK: u16 = 280;
    pub const MUX_TERMINAL_SPAWN_AFTER_CELL_PIXEL_SNAPSHOT_HOOK: u16 = 290;
    pub const MUX_CELL_PIXEL_LIFECYCLE: u16 = 300;
    pub const MUX_CLIENT_SIZING: u16 = 310;
    pub const MUX_PENDING_WORKSPACE_SURFACES: u16 = 320;
    /// `Mux::feed_local`: before the workspace registry and state.
    pub const MUX_FEED_LOCAL: u16 = 330;
    // 2000-2990: workspace registry -> journal writer -> registry connection.
    /// `Mux::workspace_registry` (the registry `SignaledMutex`).
    pub const WORKSPACE_REGISTRY: u16 = 2000;
    /// Not a lock: the journal writer thread holds this rank for each loop
    /// iteration (`JournalWriterCommitScope`). It ranks after the registry,
    /// so the writer can never take the registry lock: a request thread holds
    /// the registry while it waits for a writer receipt.
    pub const JOURNAL_WRITER: u16 = 2010;
    /// `Mux::agent_roster`: taken under the registry, and it reads the
    /// registry connection while held.
    pub const MUX_AGENT_ROSTER: u16 = 2015;
    /// `RegistryConnection`, the SQLite connection lock. It is reentrant for
    /// its holder; only the first acquisition on a thread is ranked.
    pub const REGISTRY_CONNECTION: u16 = 2020;
    pub const MUX_STATE: u16 = 3000;
    // Post-state locks.
    pub const APPS_SUPERVISOR: u16 = 3100;
    pub const BROWSER_NAVIGATION_HOLD: u16 = 3110;
    pub const BROWSER_COMMAND_ORDER: u16 = 3120;
    pub const BROWSER_SESSION: u16 = 3130;
    pub const BROWSER_STATE: u16 = 3140;
    pub const BROWSER_HOST_GATE: u16 = 3150;
    pub const BROWSER_HOST_BACKOFF: u16 = 3160;
    pub const EVENT_BUS_SUBSCRIBERS: u16 = 3170;
    pub const JOURNAL_PLUGIN_SUPERVISOR: u16 = 3180;
    pub const MUX_BROWSER_RUNTIME: u16 = 3190;
    pub const MUX_CELL_PIXEL_BEFORE_PUBLISH_HOOK: u16 = 3200;
    pub const MUX_KITTY_IMAGE_BUDGET: u16 = 3210;
    pub const MUX_KITTY_IMAGE_BUDGET_OPERATION_HOOK: u16 = 3220;
    pub const MUX_NOTIFICATION_LEDGER: u16 = 3230;
    pub const MUX_NOTIFICATION_READS: u16 = 3240;
    pub const MUX_PLACEMENT_NOTIFICATIONS: u16 = 3250;
    pub const MUX_SURFACE_OPTIONS: u16 = 3260;
    pub const MUX_PENDING_CELL_PIXELS: u16 = 3270;
    pub const MUX_TERMINAL_REAPER_EVENTS: u16 = 3280;
    pub const MUX_TERMINAL_SPAWN_BEFORE_CELL_PIXEL_RECONCILE_HOOK: u16 = 3290;
    pub const TERMINAL_REAP_EVENTS: u16 = 3300;
    /// `PtyTerminalRuntime::kitty_limits_request`, held for a whole Kitty
    /// limits request, including the runtime, terminal and taps it takes.
    pub const PTY_KITTY_LIMITS_REQUEST: u16 = 3305;
    pub const PTY_GEOMETRY: u16 = 3310;
    pub const PTY_TERM: u16 = 3320;
    pub const PTY_RENDER: u16 = 3475;
    pub const PTY_RUNTIME: u16 = 3340;
    pub const AGENT_SESSION_ATTACH: u16 = 3350;
    pub const SERVER_CLIPBOARD_READ: u16 = 3360;
    pub const CONNECTION_SCHEDULER: u16 = 3370;
    pub const LAUNCH_SNAPSHOT_EVENTS: u16 = 3380;
    pub const LOOPBACK_FORWARDER: u16 = 3390;
    pub const MESSAGE_WRITER_WAIT_WAKEUPS: u16 = 3400;
    pub const TERMINAL_CREATION_QUEUE: u16 = 3410;
    pub const URL_OPEN: u16 = 3420;
    pub const BOUNDED_OUTBOUND: u16 = 3430;
    pub const PTY_JOURNAL_CAPTURE_GATE: u16 = 3440;
    pub const JOURNAL_INGRESS_GATE: u16 = 3450;
    pub const JOURNAL_INGRESS_EPOCH: u16 = 3460;
    pub const PTY_KITTY_GRAPHICS_LIMITS: u16 = 3470;
    pub const PTY_TAPS: u16 = 3480;
    pub const PTY_PENDING_HOST_BINDING: u16 = 3490;
    pub const PTY_READER_THREAD: u16 = 3500;
    pub const HOST_FRAMES_QUEUE: u16 = 3510;
    pub const SNAPSHOT_ATTACH_GATE: u16 = 3520;
    pub const ATTACHMENT_VIEWER_SIZE: u16 = 3530;
    pub const CONTROL_DEFERRED_CELL_PIXEL_HANDLER: u16 = 3540;
    pub const CONTROL_INPUT_ACK_SHUTDOWN: u16 = 3550;
    pub const HOST_CHILD_SIGNAL: u16 = 3560;
    pub const HOST_VIEWER_SIZES: u16 = 3570;
    pub const HOST_SOURCE_ORDER: u16 = 3580;
    pub const HOST_SIZE: u16 = 3590;
    pub const HOST_CELL_PIXELS: u16 = 3600;
    pub const HOST_WRITER: u16 = 3610;
    pub const HOST_PARSER_PROGRESS: u16 = 3620;
    pub const HOST_TERM: u16 = 3630;
    pub const HOST_MASTER: u16 = 3640;
    pub const HOST_BROADCAST: u16 = 3650;
    pub const HOST_STATE_BROADCAST: u16 = 3660;
    /// `Mux::pending_terminals`: taken under state; holds only leaf locks
    /// (the respawn guard), so it ranks just below LEAF.
    pub const MUX_PENDING_TERMINALS: u16 = 8000;
    /// Locks that never take another lock while held.
    pub const LEAF: u16 = 9000;
}

/// The constant name of a rank, for violation messages.
#[cfg(debug_assertions)]
fn rank_name(r: u16) -> &'static str {
    use rank::*;
    macro_rules! names {
        ($($c:ident),* $(,)?) => { match r { $($c => stringify!($c),)* _ => "an unnamed rank" } };
    }
    names!(
        UNRANKED,
        CHECKPOINT_PATH_LOCK,
        AGENT_SESSION_READER_SLOT,
        CONVERSATION_STORE_GATE,
        CONVERSATION_STORE,
        MUX_AGENT_ROSTER_FOLD,
        MUX_LAYOUT_UNDO_BEFORE_COMMIT_HOOK,
        MUX_SCREEN_CREATED_HOOK,
        MUX_SIDEBAR_PLUGIN,
        MUX_EXIT_SETTLE_GATE,
        CLOSED_HISTORY_REOPEN,
        FRONTEND_BROWSER_KEYED_CREATION,
        MUX_RESOURCE_CREATION_HANDOFF,
        MUX_RESOURCE_CREATION_EXECUTION,
        MUX_PROVIDER_WORKSPACE,
        MUX_AGENT_HOOK_FENCES,
        MUX_VIEWPORT_SPLIT_AFTER_SPAWN_HOOK,
        MUX_WORKSPACE_LIFECYCLE,
        MUX_CLIENT_SIZING_LIFECYCLE,
        MUX_TERMINAL_CREATE_AFTER_RESERVATION_HOOK,
        MUX_TERMINAL_SPAWN_AFTER_CELL_PIXEL_SNAPSHOT_HOOK,
        MUX_CELL_PIXEL_LIFECYCLE,
        MUX_CLIENT_SIZING,
        MUX_PENDING_WORKSPACE_SURFACES,
        MUX_FEED_LOCAL,
        WORKSPACE_REGISTRY,
        JOURNAL_WRITER,
        MUX_AGENT_ROSTER,
        REGISTRY_CONNECTION,
        MUX_STATE,
        APPS_SUPERVISOR,
        BROWSER_NAVIGATION_HOLD,
        BROWSER_COMMAND_ORDER,
        BROWSER_SESSION,
        BROWSER_STATE,
        BROWSER_HOST_GATE,
        BROWSER_HOST_BACKOFF,
        EVENT_BUS_SUBSCRIBERS,
        JOURNAL_PLUGIN_SUPERVISOR,
        MUX_BROWSER_RUNTIME,
        MUX_CELL_PIXEL_BEFORE_PUBLISH_HOOK,
        MUX_KITTY_IMAGE_BUDGET,
        MUX_KITTY_IMAGE_BUDGET_OPERATION_HOOK,
        MUX_NOTIFICATION_LEDGER,
        MUX_NOTIFICATION_READS,
        MUX_PLACEMENT_NOTIFICATIONS,
        MUX_SURFACE_OPTIONS,
        MUX_PENDING_CELL_PIXELS,
        MUX_TERMINAL_REAPER_EVENTS,
        MUX_TERMINAL_SPAWN_BEFORE_CELL_PIXEL_RECONCILE_HOOK,
        TERMINAL_REAP_EVENTS,
        PTY_KITTY_LIMITS_REQUEST,
        PTY_GEOMETRY,
        PTY_TERM,
        PTY_RENDER,
        PTY_RUNTIME,
        AGENT_SESSION_ATTACH,
        SERVER_CLIPBOARD_READ,
        CONNECTION_SCHEDULER,
        LAUNCH_SNAPSHOT_EVENTS,
        LOOPBACK_FORWARDER,
        MESSAGE_WRITER_WAIT_WAKEUPS,
        TERMINAL_CREATION_QUEUE,
        URL_OPEN,
        BOUNDED_OUTBOUND,
        PTY_JOURNAL_CAPTURE_GATE,
        JOURNAL_INGRESS_GATE,
        JOURNAL_INGRESS_EPOCH,
        PTY_KITTY_GRAPHICS_LIMITS,
        PTY_TAPS,
        PTY_PENDING_HOST_BINDING,
        PTY_READER_THREAD,
        HOST_FRAMES_QUEUE,
        SNAPSHOT_ATTACH_GATE,
        ATTACHMENT_VIEWER_SIZE,
        CONTROL_DEFERRED_CELL_PIXEL_HANDLER,
        CONTROL_INPUT_ACK_SHUTDOWN,
        HOST_CHILD_SIGNAL,
        HOST_VIEWER_SIZES,
        HOST_SOURCE_ORDER,
        HOST_SIZE,
        HOST_CELL_PIXELS,
        HOST_WRITER,
        HOST_PARSER_PROGRESS,
        HOST_TERM,
        HOST_MASTER,
        HOST_BROADCAST,
        HOST_STATE_BROADCAST,
        MUX_PENDING_TERMINALS,
        LEAF,
    )
}

#[cfg(debug_assertions)]
mod held {
    use std::cell::RefCell;
    use std::panic::Location;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Held {
        rank: u16,
        at: &'static Location<'static>,
        id: u64,
    }

    thread_local! {
        static HELD: RefCell<Vec<Held>> = const { RefCell::new(Vec::new()) };
    }

    static NEXT_ID: AtomicU64 = AtomicU64::new(1);

    #[track_caller]
    pub(super) fn check(rank: u16) {
        let at = Location::caller();
        let violation = HELD.with(|held| {
            held.borrow()
                .iter()
                .max_by_key(|entry| entry.rank)
                .filter(|inner| inner.rank >= rank)
                .map(|inner| (inner.rank, inner.at))
        });
        // Panic outside the closure so the location is the acquisition site.
        if let Some((held_rank, held_at)) = violation {
            let message = format!(
                "lock order violation: acquiring {} ({rank}) at {at} while this thread holds {} \
                 ({held_rank}) taken at {held_at}; ranks must ascend (see lock_rank.rs)",
                super::rank_name(rank),
                super::rank_name(held_rank),
            );
            // Daemons spawned by tests often discard stderr: CMUX_TUI_LOCK_RANK_LOG
            // names a file that collects every violation of every process.
            if let Some(path) = std::env::var_os("CMUX_TUI_LOCK_RANK_LOG") {
                use std::io::Write as _;
                if let Ok(mut file) =
                    std::fs::OpenOptions::new().create(true).append(true).open(path)
                {
                    let _ = writeln!(file, "{message}");
                }
            }
            // crash-allow: the debug and test lock-order assertion; release builds compile it out.
            panic!("{message}");
        }
    }

    #[track_caller]
    pub(super) fn push(rank: u16) -> u64 {
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let at = Location::caller();
        HELD.with(|held| held.borrow_mut().push(Held { rank, at, id }));
        id
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

/// One rank this thread holds; dropping it releases the rank. Zero-sized in
/// release builds.
pub struct HeldRank {
    #[cfg(debug_assertions)]
    id: u64,
}

impl HeldRank {
    /// Check that `rank` may be acquired now. Call before blocking on a lock.
    #[track_caller]
    #[inline]
    pub fn check(rank: u16) {
        #[cfg(debug_assertions)]
        if rank != rank::UNRANKED {
            held::check(rank);
        }
        #[cfg(not(debug_assertions))]
        let _ = rank;
    }

    /// Record that this thread now holds `rank`.
    #[track_caller]
    #[inline]
    pub fn record(rank: u16) -> Self {
        #[cfg(debug_assertions)]
        {
            Self { id: if rank == rank::UNRANKED { 0 } else { held::push(rank) } }
        }
        #[cfg(not(debug_assertions))]
        {
            let _ = rank;
            Self {}
        }
    }
}

#[cfg(debug_assertions)]
impl Drop for HeldRank {
    fn drop(&mut self) {
        if self.id != 0 {
            held::pop(self.id);
        }
    }
}

/// An unranked lock: not checked, and never recorded as held.
pub type Mutex<T> = RankedMutex<T, { rank::UNRANKED }>;

/// `std::sync::Mutex` with the lock rank `R`. Construct a ranked field with
/// `RankedMutex::new` so `R` is inferred from the field type.
#[derive(Default)]
pub struct RankedMutex<T: ?Sized, const R: u16> {
    inner: std::sync::Mutex<T>,
}

impl<T: ?Sized + std::fmt::Debug, const R: u16> std::fmt::Debug for RankedMutex<T, R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.inner.fmt(f)
    }
}

impl<T, const R: u16> RankedMutex<T, R> {
    #[inline]
    pub const fn new(value: T) -> Self {
        Self { inner: std::sync::Mutex::new(value) }
    }

    #[inline]
    pub fn into_inner(self) -> LockResult<T> {
        self.inner.into_inner()
    }
}

impl<T: ?Sized, const R: u16> RankedMutex<T, R> {
    #[track_caller]
    #[inline]
    pub fn lock(&self) -> LockResult<MutexGuard<'_, T>> {
        HeldRank::check(R);
        match self.inner.lock() {
            Ok(guard) => Ok(MutexGuard { guard, _held: HeldRank::record(R) }),
            Err(poison) => Err(PoisonError::new(MutexGuard {
                guard: poison.into_inner(),
                _held: HeldRank::record(R),
            })),
        }
    }

    #[track_caller]
    #[inline]
    pub fn try_lock(&self) -> TryLockResult<MutexGuard<'_, T>> {
        match self.inner.try_lock() {
            Ok(guard) => Ok(MutexGuard { guard, _held: HeldRank::record(R) }),
            Err(TryLockError::WouldBlock) => Err(TryLockError::WouldBlock),
            Err(TryLockError::Poisoned(poison)) => {
                Err(TryLockError::Poisoned(PoisonError::new(MutexGuard {
                    guard: poison.into_inner(),
                    _held: HeldRank::record(R),
                })))
            }
        }
    }

    #[inline]
    pub fn get_mut(&mut self) -> LockResult<&mut T> {
        self.inner.get_mut()
    }

    #[inline]
    pub fn is_poisoned(&self) -> bool {
        self.inner.is_poisoned()
    }

    #[inline]
    pub fn clear_poison(&self) {
        self.inner.clear_poison();
    }
}

/// A held [`Mutex`]. The lock is released before its rank.
pub struct MutexGuard<'a, T: ?Sized> {
    guard: std::sync::MutexGuard<'a, T>,
    _held: HeldRank,
}

impl<T: ?Sized> Deref for MutexGuard<'_, T> {
    type Target = T;

    #[inline]
    fn deref(&self) -> &T {
        &self.guard
    }
}

impl<T: ?Sized> DerefMut for MutexGuard<'_, T> {
    #[inline]
    fn deref_mut(&mut self) -> &mut T {
        &mut self.guard
    }
}

impl<T: ?Sized + std::fmt::Debug> std::fmt::Debug for MutexGuard<'_, T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        (**self).fmt(f)
    }
}

/// `std::sync::Condvar` for [`MutexGuard`]. The waiting thread keeps the rank
/// while it waits, because it acquires nothing until the wait returns.
#[derive(Debug, Default)]
pub struct Condvar(std::sync::Condvar);

type Rewrap<'a, T, X> = LockResult<(std::sync::MutexGuard<'a, T>, X)>;

fn rewrap<'a, T, X>(
    result: Rewrap<'a, T, X>,
    held: HeldRank,
) -> LockResult<(MutexGuard<'a, T>, X)> {
    match result {
        Ok((guard, extra)) => Ok((MutexGuard { guard, _held: held }, extra)),
        Err(poison) => {
            let (guard, extra) = poison.into_inner();
            Err(PoisonError::new((MutexGuard { guard, _held: held }, extra)))
        }
    }
}

fn unit<T>(result: LockResult<T>) -> LockResult<(T, ())> {
    result.map(|value| (value, ())).map_err(|poison| PoisonError::new((poison.into_inner(), ())))
}

fn drop_unit<T>(result: LockResult<(T, ())>) -> LockResult<T> {
    result.map(|(value, ())| value).map_err(|poison| PoisonError::new(poison.into_inner().0))
}

impl Condvar {
    #[inline]
    pub const fn new() -> Self {
        Self(std::sync::Condvar::new())
    }

    #[inline]
    pub fn notify_one(&self) {
        self.0.notify_one();
    }

    #[inline]
    pub fn notify_all(&self) {
        self.0.notify_all();
    }

    pub fn wait<'a, T>(&self, guard: MutexGuard<'a, T>) -> LockResult<MutexGuard<'a, T>> {
        let MutexGuard { guard, _held: held } = guard;
        drop_unit(rewrap(unit(self.0.wait(guard)), held))
    }

    pub fn wait_while<'a, T, F>(
        &self,
        guard: MutexGuard<'a, T>,
        condition: F,
    ) -> LockResult<MutexGuard<'a, T>>
    where
        F: FnMut(&mut T) -> bool,
    {
        let MutexGuard { guard, _held: held } = guard;
        drop_unit(rewrap(unit(self.0.wait_while(guard, condition)), held))
    }

    pub fn wait_timeout<'a, T>(
        &self,
        guard: MutexGuard<'a, T>,
        timeout: Duration,
    ) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)> {
        let MutexGuard { guard, _held: held } = guard;
        rewrap(self.0.wait_timeout(guard, timeout), held)
    }

    pub fn wait_timeout_while<'a, T, F>(
        &self,
        guard: MutexGuard<'a, T>,
        timeout: Duration,
        condition: F,
    ) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)>
    where
        F: FnMut(&mut T) -> bool,
    {
        let MutexGuard { guard, _held: held } = guard;
        rewrap(self.0.wait_timeout_while(guard, timeout, condition), held)
    }
}
