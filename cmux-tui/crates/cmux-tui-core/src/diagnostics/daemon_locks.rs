//! Wait and hold time of the daemon's state and registry locks, by caller
//! class and request op (`debug-daemon-locks`; the plan names it
//! `debug.daemon_locks`).
//!
//! Chrome keeps one fixed-bucket histogram per metric with atomic counts
//! (base/metrics/histogram.h, buckets fixed at creation) and splits task
//! latency by the task's priority (base/task/thread_pool/task_tracker.cc,
//! `ThreadPool.TaskLatencyMicroseconds.<priority>`). Here the metric is a
//! lock acquisition, the priority is the caller class of the request that
//! took it, and each (class, op) pair has its own pair of histograms.
//!
//! The request dispatcher enters a [`LockCallerScope`] for the connection's
//! caller class and a [`LockOpScope`] for the request's op; both are
//! thread-local and restore the outer value when they drop. A request a
//! worker thread answers carries them as a [`LockScope`] the worker enters
//! again. A lock taken outside any request (PTY output, reaps, timers)
//! counts as [`LockCaller::Program`] under [`LockOp::NONE`].
//!
//! Cost per acquisition: one thread-local read, one slot lookup (an atomic
//! load once the slot exists), two clock reads when the lock is free (its
//! acquisition and its release; the wait is zero with no read) and a third
//! only when it was held, plus eight relaxed atomic adds. No lock.

use std::cell::Cell;
use std::marker::PhantomData;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde::Serialize;

use super::{LogLinearHistogram, SUB_BUCKETS};

/// Who a lock acquisition works for, by the request it runs in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum LockCaller {
    /// The verified app (request origin `user`): the person's frontend.
    Frontend = 0,
    /// Every other request: agents, the CLI, pages, remote clients.
    Automation = 1,
    /// No request: daemon threads (PTY output, reaps, timers).
    Program = 2,
}

impl LockCaller {
    pub const ALL: [Self; 3] = [Self::Frontend, Self::Automation, Self::Program];

    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::Frontend => "frontend",
            Self::Automation => "automation",
            Self::Program => "program",
        }
    }

    const fn from_repr(repr: u8) -> Self {
        match repr {
            0 => Self::Frontend,
            1 => Self::Automation,
            _ => Self::Program,
        }
    }
}

/// A connection's caller class, kept where its reader and dispatcher read
/// it without a lock; the origin gate sets it when the connection's origin
/// changes. A connection starts as automation.
#[derive(Debug)]
pub struct LockCallerCell(AtomicU8);

impl Default for LockCallerCell {
    fn default() -> Self {
        Self(AtomicU8::new(LockCaller::Automation as u8))
    }
}

impl LockCallerCell {
    pub fn get(&self) -> LockCaller {
        LockCaller::from_repr(self.0.load(Ordering::Relaxed))
    }

    pub fn set(&self, caller: LockCaller) {
        self.0.store(caller as u8, Ordering::Relaxed);
    }
}

/// A request op as a dense index the server assigns (its commands, resource
/// operations and routed lines); [`Self::NONE`] outside any request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LockOp(pub u16);

impl LockOp {
    pub const NONE: Self = Self(0);
}

/// Ops a lock table holds; a larger index counts in the last slot.
pub const LOCK_OPS: usize = 1024;

thread_local! {
    static SCOPE: Cell<(LockCaller, LockOp)> =
        const { Cell::new((LockCaller::Program, LockOp::NONE)) };
}

fn current_scope() -> (LockCaller, LockOp) {
    // A lock taken during thread teardown counts as program work.
    SCOPE.try_with(Cell::get).unwrap_or((LockCaller::Program, LockOp::NONE))
}

fn set_scope(update: impl FnOnce((LockCaller, LockOp)) -> (LockCaller, LockOp)) {
    let _ = SCOPE.try_with(|scope| scope.set(update(scope.get())));
}

/// The caller class of the request this thread is handling. Not `Send`:
/// it restores the outer class on the thread that entered it.
#[must_use = "the caller class ends when this drops"]
pub struct LockCallerScope {
    previous: LockCaller,
    _thread: PhantomData<*const ()>,
}

impl LockCallerScope {
    pub fn enter(caller: LockCaller) -> Self {
        let previous = current_scope().0;
        set_scope(|(_, op)| (caller, op));
        Self { previous, _thread: PhantomData }
    }
}

impl Drop for LockCallerScope {
    fn drop(&mut self) {
        let previous = self.previous;
        set_scope(|(_, op)| (previous, op));
    }
}

/// The op of the request this thread is handling. Not `Send`.
#[must_use = "the op ends when this drops"]
pub struct LockOpScope {
    previous: LockOp,
    _thread: PhantomData<*const ()>,
}

impl LockOpScope {
    pub fn enter(op: LockOp) -> Self {
        let previous = current_scope().1;
        set_scope(|(caller, _)| (caller, op));
        Self { previous, _thread: PhantomData }
    }
}

impl Drop for LockOpScope {
    fn drop(&mut self) {
        let previous = self.previous;
        set_scope(|(caller, _)| (caller, previous));
    }
}

/// The caller class and op of the request a thread handles, as a value a
/// worker thread that answers the request enters again.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LockScope {
    pub caller: LockCaller,
    pub op: LockOp,
}

impl LockScope {
    /// This thread's caller class and op.
    pub fn current() -> Self {
        let (caller, op) = current_scope();
        Self { caller, op }
    }

    /// Makes this the thread's caller class and op until the guard drops.
    pub fn enter(self) -> LockScopeGuard {
        LockScopeGuard {
            _caller: LockCallerScope::enter(self.caller),
            _op: LockOpScope::enter(self.op),
        }
    }
}

/// [`LockScope::enter`]'s guard. Not `Send`.
#[must_use = "the scope ends when this drops"]
pub struct LockScopeGuard {
    // The op restores first, then the caller class: the reverse of entry.
    _op: LockOpScope,
    _caller: LockCallerScope,
}

#[cfg(test)]
thread_local! {
    static CLOCK_READS: Cell<u64> = const { Cell::new(0) };
}

/// The clock every timed lock reads; tests count its reads per thread.
#[inline]
pub(crate) fn lock_clock() -> Instant {
    #[cfg(test)]
    CLOCK_READS.with(|reads| reads.set(reads.get() + 1));
    Instant::now()
}

/// Clock reads [`lock_clock`] made on this thread.
#[cfg(test)]
pub(crate) fn lock_clock_reads() -> u64 {
    CLOCK_READS.with(Cell::get)
}

#[cfg(test)]
thread_local! {
    static ON_CONTENDED: std::cell::RefCell<Option<Box<dyn FnMut()>>> =
        const { std::cell::RefCell::new(None) };
}

/// Runs `hook` on this thread each time a timed acquisition finds its lock
/// held, after its wait began and before it blocks.
#[cfg(test)]
pub(crate) fn on_contended_lock(hook: impl FnMut() + 'static) {
    ON_CONTENDED.with(|slot| *slot.borrow_mut() = Some(Box::new(hook)));
}

/// Octaves of microseconds a lock histogram covers: the top bucket ends at
/// 2^28 - 1 us (about 268 s); a longer sample counts there.
const LOCK_OCTAVES: usize = 28;
const LOCK_BUCKETS: usize = LOCK_OCTAVES * SUB_BUCKETS;

/// Microseconds, in [`LogLinearHistogram`]'s buckets cut at
/// [`LOCK_OCTAVES`]: a percentile is at most 25% above the true value.
pub struct LockHistogram {
    buckets: [AtomicU64; LOCK_BUCKETS],
    count: AtomicU64,
    sum: AtomicU64,
    max: AtomicU64,
}

impl Default for LockHistogram {
    fn default() -> Self {
        Self {
            buckets: std::array::from_fn(|_| AtomicU64::new(0)),
            count: AtomicU64::new(0),
            sum: AtomicU64::new(0),
            max: AtomicU64::new(0),
        }
    }
}

impl LockHistogram {
    fn record(&self, duration: Duration) {
        let micros = u64::try_from(duration.as_micros()).unwrap_or(u64::MAX);
        // A wait past the top bucket's bound counts in the top bucket.
        let bucket = self.buckets.get(LogLinearHistogram::bucket_index(micros));
        if let Some(bucket) = bucket.or(self.buckets.last()) {
            bucket.fetch_add(1, Ordering::Relaxed);
        }
        self.count.fetch_add(1, Ordering::Relaxed);
        // A u64 of microseconds does not wrap within any daemon's lifetime.
        self.sum.fetch_add(micros, Ordering::Relaxed);
        self.max.fetch_max(micros, Ordering::Relaxed);
    }

    fn add_into(&self, merged: &mut MergedHistogram) {
        for (total, bucket) in merged.buckets.iter_mut().zip(&self.buckets) {
            *total += bucket.load(Ordering::Relaxed);
        }
        merged.sum = merged.sum.saturating_add(self.sum.load(Ordering::Relaxed));
        merged.max = merged.max.max(self.max.load(Ordering::Relaxed));
    }

    fn snapshot(&self) -> LockHistogramSnapshot {
        let mut merged = MergedHistogram::default();
        self.add_into(&mut merged);
        merged.snapshot()
    }

    fn sum(&self) -> u64 {
        self.sum.load(Ordering::Relaxed)
    }

    fn count(&self) -> u64 {
        self.count.load(Ordering::Relaxed)
    }
}

/// Plain counts read from one or more [`LockHistogram`]s.
struct MergedHistogram {
    buckets: [u64; LOCK_BUCKETS],
    sum: u64,
    max: u64,
}

impl Default for MergedHistogram {
    fn default() -> Self {
        Self { buckets: [0; LOCK_BUCKETS], sum: 0, max: 0 }
    }
}

impl MergedHistogram {
    fn snapshot(&self) -> LockHistogramSnapshot {
        // The count is the buckets' sum, so the percentiles agree with it
        // while recorders run.
        let count: u64 = self.buckets.iter().sum();
        let percentile = |fraction: f64| -> u64 {
            if count == 0 {
                return 0;
            }
            let rank = ((count as f64) * fraction).ceil().max(1.0) as u64;
            let mut seen = 0;
            for (index, bucket) in self.buckets.iter().enumerate() {
                seen += bucket;
                if seen >= rank {
                    return LogLinearHistogram::bucket_upper_bound(index).min(self.max);
                }
            }
            self.max
        };
        LockHistogramSnapshot {
            count,
            mean: self.sum.checked_div(count).unwrap_or(0),
            max: self.max,
            p50: percentile(0.50),
            p95: percentile(0.95),
            p99: percentile(0.99),
        }
    }
}

/// Microseconds. A percentile is its bucket's upper bound, never above
/// `max`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct LockHistogramSnapshot {
    pub count: u64,
    pub mean: u64,
    pub max: u64,
    pub p50: u64,
    pub p95: u64,
    pub p99: u64,
}

/// The wait and hold histograms of one (caller class, op) pair of one lock.
#[derive(Default)]
pub struct LockSlot {
    wait: LockHistogram,
    hold: LockHistogram,
}

impl LockSlot {
    pub(crate) fn waited(&self, waited: Duration) {
        self.wait.record(waited);
    }

    pub(crate) fn held(&self, held: Duration) {
        self.hold.record(held);
    }
}

/// Every (caller class, op) slot of one lock, made on first use.
pub struct DaemonLockTable {
    slots: Box<[OnceLock<Box<LockSlot>>]>,
}

impl Default for DaemonLockTable {
    fn default() -> Self {
        Self::new()
    }
}

impl DaemonLockTable {
    pub fn new() -> Self {
        Self { slots: (0..LockCaller::ALL.len() * LOCK_OPS).map(|_| OnceLock::new()).collect() }
    }

    /// The cell of (caller, op); an op past the table counts in its last op.
    #[allow(
        clippy::indexing_slicing,
        reason = "INVARIANT: slots has ALL.len() * LOCK_OPS cells; the op is clamped below LOCK_OPS"
    )]
    fn cell(&self, caller: LockCaller, op: LockOp) -> &OnceLock<Box<LockSlot>> {
        &self.slots[caller as usize * LOCK_OPS + usize::from(op.0).min(LOCK_OPS - 1)]
    }

    /// The slot of this thread's caller class and op. Read it before the
    /// lock is taken: the first use of a slot allocates it.
    pub(crate) fn current(&self) -> &LockSlot {
        let (caller, op) = current_scope();
        self.cell(caller, op).get_or_init(Box::default)
    }

    /// Per caller class (all its ops merged) and per (class, op) pair, the
    /// pairs ordered by total hold time. `op_name` names a [`LockOp`].
    pub fn snapshot(
        &self,
        lock: &'static str,
        op_name: &dyn Fn(LockOp) -> String,
    ) -> LockTableSnapshot {
        let mut callers = Vec::with_capacity(LockCaller::ALL.len());
        let mut ops = Vec::new();
        for caller in LockCaller::ALL {
            let (mut wait, mut hold) = (MergedHistogram::default(), MergedHistogram::default());
            for op in 0..LOCK_OPS {
                let op = LockOp(op as u16);
                let Some(slot) = self.cell(caller, op).get() else { continue };
                if slot.wait.count() == 0 && slot.hold.count() == 0 {
                    continue;
                }
                slot.wait.add_into(&mut wait);
                slot.hold.add_into(&mut hold);
                ops.push((
                    slot.hold.sum(),
                    slot.wait.sum(),
                    OpLockSnapshot {
                        op: op_name(op),
                        caller: caller.wire_name(),
                        wait_us: slot.wait.snapshot(),
                        hold_us: slot.hold.snapshot(),
                    },
                ));
            }
            callers.push(CallerLockSnapshot {
                caller: caller.wire_name(),
                wait_us: wait.snapshot(),
                hold_us: hold.snapshot(),
            });
        }
        ops.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)).then_with(|| a.2.op.cmp(&b.2.op)));
        LockTableSnapshot { lock, callers, ops: ops.into_iter().map(|(_, _, op)| op).collect() }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct LockTableSnapshot {
    /// The lock's rank name (`workspace.registry`, `mux.state`).
    pub lock: &'static str,
    /// Every caller class, its ops merged.
    pub callers: Vec<CallerLockSnapshot>,
    /// Every (class, op) pair that took the lock, by total hold time.
    pub ops: Vec<OpLockSnapshot>,
}

#[derive(Clone, Debug, Serialize)]
pub struct CallerLockSnapshot {
    pub caller: &'static str,
    pub wait_us: LockHistogramSnapshot,
    pub hold_us: LockHistogramSnapshot,
}

#[derive(Clone, Debug, Serialize)]
pub struct OpLockSnapshot {
    pub op: String,
    pub caller: &'static str,
    pub wait_us: LockHistogramSnapshot,
    pub hold_us: LockHistogramSnapshot,
}

/// Times one acquisition into `slot`: `try_acquire` first, so a free lock
/// costs one clock read here; only a held one reads the clock before it
/// blocks in `acquire`. Returns the guard, when it was acquired and how
/// long it waited.
#[inline]
pub(crate) fn timed_acquire<G>(
    slot: &LockSlot,
    try_acquire: impl FnOnce() -> Option<G>,
    acquire: impl FnOnce() -> G,
) -> (G, Instant, Duration) {
    if let Some(guard) = try_acquire() {
        let acquired = lock_clock();
        slot.waited(Duration::ZERO);
        return (guard, acquired, Duration::ZERO);
    }
    let waited_from = lock_clock();
    #[cfg(test)]
    ON_CONTENDED.with(|hook| hook.borrow_mut().as_mut().map(|hook| hook()));
    let guard = acquire();
    let acquired = lock_clock();
    let waited = acquired.saturating_duration_since(waited_from);
    slot.waited(waited);
    (guard, acquired, waited)
}

#[cfg(test)]
#[path = "daemon_locks_tests.rs"]
mod tests;
