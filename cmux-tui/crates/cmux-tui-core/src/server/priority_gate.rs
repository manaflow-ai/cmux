//! Lock admission by class (plans/cmux-next/chrome-parity/p06-scheduler.md,
//! "Lock admission by class").
//!
//! The registry lock, the registry connection lock and the mux state lock
//! each acquire through a [`PriorityGate`]. The class is the thread's
//! [`EventCause`] (the request's origin, entered by the dispatcher and
//! carried to pool jobs):
//!
//! - a frontend caller that must wait counts itself in `frontend_waiting`
//!   and queues on the lock;
//! - an automation caller never queues on the lock while a frontend caller
//!   waits: it waits on the gate's release condvar instead, so a frontend
//!   request gets the lock at the next release, behind no automation queue;
//! - while frontends keep waiting, one automation caller is let through at
//!   least every [`AUTOMATION_ADMIT_GAP`], so agents never starve: its
//!   admission is a reservation that new frontend callers wait behind, so
//!   frontends releasing and retaking the lock cannot barge past it;
//! - a caller that holds any ranked lock never yields
//!   ([`crate::lock_rank::HeldRank::may_yield`]): it could hold up the very
//!   request it yields to. Program work (terminal output, hooks) queues as
//!   before.
//!
//! This is Chromium's task priority applied to a lock: work posted at
//! `TaskPriority::USER_BLOCKING` runs before `USER_VISIBLE` and
//! `BEST_EFFORT` work, which still gets a bounded share
//! (base/task/thread_pool/priority_queue.cc,
//! base/task/thread_pool/thread_group.cc `CanRunPolicy`).

use std::ops::{Deref, DerefMut};
#[cfg(test)]
use std::sync::MutexGuard;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering, fence};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::diagnostics::{LockClassStats, LockClassesSnapshot};
use crate::event_cause::EventCause;
use crate::lock_rank::HeldRank;
use crate::panic_free::RecoverPoison;

/// While frontend callers wait, an automation caller is let through at
/// least this often (p06-scheduler.md: "automation is admitted at least
/// every 4 ms").
pub(crate) const AUTOMATION_ADMIT_GAP: Duration = Duration::from_millis(4);

/// The admission state of one lock.
pub(crate) struct PriorityGate {
    /// The clock origin of `yield_mark`.
    origin: Instant,
    /// Frontend callers queued on the lock now.
    frontend_waiting: AtomicUsize,
    /// Nanoseconds after `origin` of the last automation admission while
    /// frontends waited: the next yielding automation caller is due
    /// [`AUTOMATION_ADMIT_GAP`] after it (and after it began to yield).
    yield_mark: AtomicU64,
    /// Automation callers whose admission came due and that have not got
    /// the lock yet: new frontend callers wait behind them.
    reserved: AtomicUsize,
    /// Callers waiting on `released` (yielding automation, frontends behind
    /// a reservation, deadline waiters): a release wakes them only when
    /// there is one.
    release_waiters: AtomicUsize,
    release_epoch: Mutex<u64>,
    released: Condvar,
    stats: LockClassStats,
}

/// How a caller got the lock: its class, how long it waited and when it
/// got the lock. [`Gated`] turns it into the hold record at release.
#[derive(Clone, Copy, Debug)]
pub(crate) struct HoldTicket {
    cause: EventCause,
    waited: Duration,
    acquired_at: Instant,
}

impl HoldTicket {
    pub(crate) fn waited(&self) -> Duration {
        self.waited
    }

    pub(crate) fn acquired_at(&self) -> Instant {
        self.acquired_at
    }
}

impl Default for PriorityGate {
    fn default() -> Self {
        Self::new()
    }
}

impl PriorityGate {
    pub(crate) fn new() -> Self {
        Self {
            origin: Instant::now(),
            frontend_waiting: AtomicUsize::new(0),
            yield_mark: AtomicU64::new(0),
            reserved: AtomicUsize::new(0),
            release_waiters: AtomicUsize::new(0),
            release_epoch: Mutex::new(0),
            released: Condvar::new(),
            stats: LockClassStats::default(),
        }
    }

    /// Per-class wait and hold (`server-stats` `lock_classes`).
    pub(crate) fn snapshot(&self) -> LockClassesSnapshot {
        self.stats.snapshot()
    }

    /// Acquire for this thread's class. `try_acquire` takes the lock without
    /// blocking (`None`: it is held); `block` queues on it.
    pub(crate) fn acquire<G>(
        &self,
        mut try_acquire: impl FnMut() -> Option<G>,
        block: impl FnOnce() -> G,
    ) -> (G, HoldTicket) {
        let cause = EventCause::current();
        let may_try = match cause {
            EventCause::Frontend => self.reserved.load(Ordering::SeqCst) == 0,
            EventCause::Automation => self.frontend_waiting.load(Ordering::SeqCst) == 0,
            EventCause::Program => true,
        };
        if may_try && let Some(guard) = try_acquire() {
            return (guard, self.admitted(cause, None));
        }
        let start = Instant::now();
        let guard = match cause {
            EventCause::Frontend => {
                let _waiting = Counted::enter(&self.frontend_waiting);
                self.wait_behind_reservations();
                block()
            }
            EventCause::Automation if HeldRank::may_yield() => {
                self.yield_to_frontend(&mut try_acquire)
            }
            EventCause::Automation | EventCause::Program => block(),
        };
        (guard, self.admitted(cause, Some(start)))
    }

    /// A ticket for a lock taken outside [`Self::acquire`] (a deadline wait,
    /// a test's `try_lock`), so its release still records the hold and
    /// wakes the gate's waiters.
    pub(crate) fn ticket(&self, waited: Duration) -> HoldTicket {
        let cause = EventCause::current();
        self.stats.waited(cause, waited);
        HoldTicket { cause, waited, acquired_at: Instant::now() }
    }

    fn admitted(&self, cause: EventCause, waited_from: Option<Instant>) -> HoldTicket {
        let acquired_at = Instant::now();
        let waited = waited_from.map_or(Duration::ZERO, |start| acquired_at - start);
        self.stats.waited(cause, waited);
        if cause == EventCause::Automation && self.frontend_waiting.load(Ordering::SeqCst) > 0 {
            self.yield_mark.fetch_max(self.nanos(acquired_at), Ordering::SeqCst);
        }
        HoldTicket { cause, waited, acquired_at }
    }

    /// The automation slow path: never queue on the lock while a frontend
    /// waits, until this caller's admission comes due; then hold a
    /// reservation until the lock is free.
    fn yield_to_frontend<G>(&self, try_acquire: &mut impl FnMut() -> Option<G>) -> G {
        let _waiter = self.register_waiter();
        let mut yielded_since = None;
        let mut reservation = None;
        let mut epoch = self.release_epoch.lock().recover_poison();
        loop {
            // The epoch lock is held from the attempt to the wait, and a
            // release takes it to wake: no release is missed between them.
            let yields = reservation.is_none() && self.frontend_waiting.load(Ordering::SeqCst) > 0;
            if !yields {
                if let Some(guard) = try_acquire() {
                    return guard;
                }
                if reservation.is_none() {
                    // No frontend waits: a later yield is a new one, due a
                    // gap after it begins.
                    yielded_since = None;
                }
                epoch = self.released.wait(epoch).recover_poison();
                continue;
            }
            let now = Instant::now();
            let yielded_since = *yielded_since.get_or_insert_with(|| {
                self.stats.automation_yielded();
                now
            });
            let due = self.due_at(yielded_since);
            if now < due {
                epoch = self.released.wait_timeout(epoch, due - now).recover_poison().0;
            } else if self.claim_admission(now) {
                self.stats.automation_admitted_while_yielding();
                reservation = Some(Counted::enter(&self.reserved));
            }
            // Else another automation caller took this admission.
        }
    }

    /// A frontend caller waits while an automation admission is reserved:
    /// the reserved caller takes the lock at the next release.
    fn wait_behind_reservations(&self) {
        if self.reserved.load(Ordering::SeqCst) == 0 {
            return;
        }
        let _waiter = self.register_waiter();
        let mut epoch = self.release_epoch.lock().recover_poison();
        // The reserved caller drops its reservation once it holds the lock
        // and wakes this caller when it releases it.
        while self.reserved.load(Ordering::SeqCst) > 0 {
            epoch = self.released.wait(epoch).recover_poison();
        }
    }

    /// When an automation caller yielding since `yielded_since` is due: a
    /// gap after both that and the last automation admission.
    fn due_at(&self, yielded_since: Instant) -> Instant {
        let last = self.origin + Duration::from_nanos(self.yield_mark.load(Ordering::SeqCst));
        last.max(yielded_since) + AUTOMATION_ADMIT_GAP
    }

    /// Take the admission that is due at `now`; false when another caller
    /// took it first.
    fn claim_admission(&self, now: Instant) -> bool {
        let mark = self.yield_mark.load(Ordering::SeqCst);
        let due = Duration::from_nanos(mark) + AUTOMATION_ADMIT_GAP;
        let now = self.nanos(now);
        u128::from(now) >= due.as_nanos()
            && self
                .yield_mark
                .compare_exchange(mark, now, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
    }

    fn nanos(&self, at: Instant) -> u64 {
        u64::try_from(at.saturating_duration_since(self.origin).as_nanos()).unwrap_or(u64::MAX)
    }

    /// Count the caller as a release waiter until the token drops, so every
    /// release wakes it.
    pub(crate) fn register_waiter(&self) -> ReleaseWaiter<'_> {
        self.release_waiters.fetch_add(1, Ordering::SeqCst);
        // Pairs with the fence in `released`: either the releaser
        // sees this waiter, or this waiter's next attempt sees the release.
        fence(Ordering::SeqCst);
        ReleaseWaiter { gate: self }
    }

    /// The release epoch, for a deadline waiter that registered with
    /// [`Self::register_waiter`].
    #[cfg(test)]
    pub(crate) fn release_epoch(&self) -> MutexGuard<'_, u64> {
        self.release_epoch.lock().recover_poison()
    }

    /// Wait at most `timeout` for the next release.
    #[cfg(test)]
    pub(crate) fn wait_release<'a>(
        &self,
        epoch: MutexGuard<'a, u64>,
        timeout: Duration,
    ) -> MutexGuard<'a, u64> {
        self.released.wait_timeout(epoch, timeout).recover_poison().0
    }

    /// After the lock was released: record the hold (none for a re-entry),
    /// wake the waiters.
    fn released(&self, ticket: Option<&HoldTicket>) {
        if let Some(ticket) = ticket {
            self.stats.held(ticket.cause, ticket.acquired_at.elapsed());
        }
        fence(Ordering::SeqCst);
        if self.release_waiters.load(Ordering::SeqCst) > 0 {
            let mut epoch = self.release_epoch.lock().recover_poison();
            *epoch = epoch.wrapping_add(1);
            self.released.notify_all();
        }
    }
}

/// A registered release waiter; see [`PriorityGate::register_waiter`].
pub(crate) struct ReleaseWaiter<'a> {
    gate: &'a PriorityGate,
}

impl Drop for ReleaseWaiter<'_> {
    fn drop(&mut self) {
        self.gate.release_waiters.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Counts a caller in `counter` until dropped.
struct Counted<'a>(&'a AtomicUsize);

impl<'a> Counted<'a> {
    fn enter(counter: &'a AtomicUsize) -> Self {
        counter.fetch_add(1, Ordering::SeqCst);
        Self(counter)
    }
}

impl Drop for Counted<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// A lock guard admitted through a gate. Its fields drop in order: the
/// guard (the unlock), then the release record, which wakes the gate's
/// waiters once the lock is free.
pub(crate) struct Gated<G, R: Deref<Target = PriorityGate>> {
    guard: G,
    release: Release<R>,
}

struct Release<R: Deref<Target = PriorityGate>> {
    gate: R,
    /// `None` for a re-entry of a reentrant lock: it waited for nothing,
    /// and its release still wakes the waiters in case it is the last hold.
    ticket: Option<HoldTicket>,
}

impl<R: Deref<Target = PriorityGate>> Drop for Release<R> {
    fn drop(&mut self) {
        self.gate.released(self.ticket.as_ref());
    }
}

impl<G, R: Deref<Target = PriorityGate>> Gated<G, R> {
    pub(crate) fn new(guard: G, gate: R, ticket: HoldTicket) -> Self {
        Self { guard, release: Release { gate, ticket: Some(ticket) } }
    }

    /// A re-entry of a reentrant lock this thread already holds.
    pub(crate) fn reentered(guard: G, gate: R) -> Self {
        Self { guard, release: Release { gate, ticket: None } }
    }

    /// When the hold began; `None` for a re-entry.
    pub(crate) fn acquired_at(&self) -> Option<Instant> {
        self.release.ticket.as_ref().map(HoldTicket::acquired_at)
    }
}

impl<G, R: Deref<Target = PriorityGate>> Deref for Gated<G, R> {
    type Target = G;

    fn deref(&self) -> &G {
        &self.guard
    }
}

impl<G, R: Deref<Target = PriorityGate>> DerefMut for Gated<G, R> {
    fn deref_mut(&mut self) -> &mut G {
        &mut self.guard
    }
}
