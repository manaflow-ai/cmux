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
//! - an automation caller never queues on the lock: it parks on the gate,
//!   and each release wakes one parked automation caller while no frontend
//!   waits. An automation caller that gets the lock while a frontend waits
//!   gives it straight back, so a frontend request gets the lock at the next
//!   release, behind no automation queue;
//! - while frontends keep waiting, one automation caller (the timekeeper,
//!   the only parked caller with a timeout) reserves an admission so that an
//!   automation caller gets the lock at least every [`AUTOMATION_ADMIT_GAP`].
//!   At most one admission is reserved; new frontend callers wait behind
//!   it, so frontends releasing and retaking the lock cannot barge past it;
//! - a caller that holds any ranked lock never waits on the gate
//!   ([`crate::lock_rank::HeldRank::may_yield`]): it could hold up the very
//!   request it waits for. It queues on the lock, as Program work (terminal
//!   output, hooks) does.
//!
//! This is Chromium's task priority applied to a lock: work posted at
//! `TaskPriority::USER_BLOCKING` runs before `USER_VISIBLE` and
//! `BEST_EFFORT` work, which still gets a bounded share
//! (base/task/thread_pool/priority_queue.cc,
//! base/task/thread_pool/thread_group.cc `CanRunPolicy`). The single
//! timekeeper and the one-at-a-time wake are the thread group's: it wakes
//! one idle worker per task (`ThreadGroupImpl::EnsureEnoughWorkersLockRequired`),
//! never all of them.

use cmux_threads::sync::{Condvar, Mutex};
use std::mem::ManuallyDrop;
use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering, fence};
use std::time::{Duration, Instant};

use crate::diagnostics::{LockClassStats, LockClassesSnapshot};
use crate::event_cause::EventCause;
use crate::lock_rank::HeldRank;
use crate::panic_free::RecoverPoison;

/// While frontend callers wait, an automation caller gets the lock at least
/// this often (p06-scheduler.md: "automation is admitted at least every
/// 4 ms").
pub(crate) const AUTOMATION_ADMIT_GAP: Duration = Duration::from_millis(4);

/// The admission is reserved this long before it is due: the holder and the
/// frontends already queued on the lock release it within the lead.
pub(crate) const RESERVE_LEAD: Duration = Duration::from_millis(2);

/// The admission state of one lock.
pub(crate) struct PriorityGate {
    /// The clock origin of `last_admission`.
    origin: Instant,
    /// Frontend callers past a failed attempt that have not got the lock.
    frontend_waiting: AtomicUsize,
    /// Nanoseconds after `origin` of the last automation acquisition: the
    /// next automation admission is due [`AUTOMATION_ADMIT_GAP`] after it.
    last_admission: AtomicU64,
    /// An automation admission is reserved: the reserved caller takes the
    /// lock at the next release, and new frontend callers wait behind it.
    reserved: AtomicBool,
    /// A parked automation caller times the next admission.
    timekeeper: AtomicBool,
    /// Callers parked on any of the gate's condvars: a release takes the
    /// epoch lock only when there is one.
    parked: AtomicUsize,
    /// Automation callers parked on `automation`.
    automation_parked: AtomicUsize,
    /// Deadline waiters parked on `any_release`.
    watchers: AtomicUsize,
    /// Bumped by every release that finds a parked caller: a caller reads it
    /// before its attempt and parks only if it is unchanged, so no release
    /// is missed between the attempt and the wait.
    epoch: Mutex<u64>,
    /// Parked automation callers; a release wakes one.
    automation: Condvar,
    /// The reserved caller; every release wakes it.
    reserved_turn: Condvar,
    /// Frontend callers behind the reservation; woken when it is used.
    frontends: Condvar,
    /// Deadline waiters; every release wakes them all.
    any_release: Condvar,
    stats: LockClassStats,
    /// Returns from a condvar wait (the wakeups a release costs).
    #[cfg(test)]
    wakeups: AtomicU64,
}

/// How a caller got the lock: its class and when it got the lock (its wait
/// is recorded at admission). [`Gated`] turns it into the hold record at
/// release.
#[derive(Clone, Copy, Debug)]
pub(crate) struct HoldTicket {
    cause: EventCause,
    acquired_at: Instant,
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
            last_admission: AtomicU64::new(0),
            reserved: AtomicBool::new(false),
            timekeeper: AtomicBool::new(false),
            parked: AtomicUsize::new(0),
            automation_parked: AtomicUsize::new(0),
            watchers: AtomicUsize::new(0),
            epoch: Mutex::new(0),
            automation: Condvar::new(),
            reserved_turn: Condvar::new(),
            frontends: Condvar::new(),
            any_release: Condvar::new(),
            stats: LockClassStats::default(),
            #[cfg(test)]
            wakeups: AtomicU64::new(0),
        }
    }

    /// Per-class wait and hold (`server-stats` `lock_classes`).
    pub(crate) fn snapshot(&self) -> LockClassesSnapshot {
        self.stats.snapshot()
    }

    /// One acquisition by this thread's class, split into the attempt and
    /// the wait for a wrapper that times contended waits
    /// (`cmux_threads::LockHolder`, `crate::diagnostics::timed_acquire`). A frontend caller counts as waiting
    /// from before its attempt until the admission drops, so no automation
    /// caller starts a hold between its failed attempt and its wait.
    pub(crate) fn admission(&self) -> Admission<'_> {
        let cause = EventCause::current();
        let frontend =
            (cause == EventCause::Frontend).then(|| Counted::enter(&self.frontend_waiting));
        Admission { gate: self, cause, _frontend: frontend }
    }

    /// A ticket for a lock taken outside [`Self::admission`] (a deadline wait,
    /// a test's `try_lock`), so its release still records the hold and
    /// wakes the gate's waiters.
    pub(crate) fn ticket(&self, waited: Duration) -> HoldTicket {
        let cause = EventCause::current();
        self.stats.waited(cause, waited);
        HoldTicket { cause, acquired_at: Instant::now() }
    }

    /// The acquisition's one clock read.
    fn admitted(&self, cause: EventCause, waited_from: Option<Instant>) -> HoldTicket {
        let acquired_at = Instant::now();
        let waited = waited_from.map_or(Duration::ZERO, |start| acquired_at - start);
        self.stats.waited(cause, waited);
        if cause == EventCause::Automation {
            self.last_admission.fetch_max(self.nanos(acquired_at), Ordering::SeqCst);
        }
        HoldTicket { cause, acquired_at }
    }

    /// An automation attempt. Without the reservation it is made only while
    /// no frontend waits, and a lock got while a frontend began to wait is
    /// given straight back: the frontend counts itself before it queues, so
    /// it waits behind at most the hold it found.
    fn try_automation<G>(&self, try_acquire: &impl Fn() -> Option<G>, reserved: bool) -> Option<G> {
        if !reserved
            && (self.frontend_waiting.load(Ordering::SeqCst) > 0
                || self.reserved.load(Ordering::SeqCst))
        {
            return None;
        }
        let guard = try_acquire()?;
        if !reserved && self.frontend_waiting.load(Ordering::SeqCst) > 0 && HeldRank::may_yield() {
            drop(guard);
            self.released();
            return None;
        }
        Some(guard)
    }

    /// The automation wait: parked on the gate until a release wakes this
    /// caller while no frontend waits, or until its reserved admission.
    fn park_automation<G>(
        &self,
        try_acquire: &impl Fn() -> Option<G>,
        start: Instant,
    ) -> (G, HoldTicket) {
        let _parked = Parked::enter(self, Some(&self.automation_parked));
        let mut yielded = false;
        let mut timekeeper: Option<(Flag<'_>, Instant)> = None;
        let mut reservation: Option<Reservation<'_>> = None;
        loop {
            let seen = self.epoch_value();
            if let Some(guard) = self.try_automation(try_acquire, reservation.is_some()) {
                // The admission is recorded before the reservation drops, so
                // the next one is timed from this acquisition.
                let ticket = self.admitted(EventCause::Automation, Some(start));
                drop(reservation);
                if timekeeper.take().is_some() {
                    // A frontend that began to wait meanwhile found the flag
                    // set and woke nobody: hand the timing on.
                    self.kick_timekeeper();
                }
                return (guard, ticket);
            }
            let frontends = self.frontend_waiting.load(Ordering::SeqCst) > 0;
            if reservation.is_none() && frontends {
                if !yielded {
                    yielded = true;
                    self.stats.automation_yielded();
                }
                // While an admission is reserved no caller times the next
                // one: the reservation's end wakes one to do it.
                timekeeper = if self.reserved.load(Ordering::SeqCst) {
                    None
                } else {
                    timekeeper.or_else(|| Some((Flag::claim(&self.timekeeper)?, Instant::now())))
                };
                if let Some((_, since)) = &timekeeper
                    && Instant::now() >= self.reserve_at(*since)
                {
                    reservation = Reservation::claim(self);
                    if reservation.is_some() {
                        timekeeper = None;
                        self.stats.automation_admitted_while_yielding();
                        continue;
                    }
                }
            } else {
                timekeeper = None;
            }
            let epoch = self.epoch.lock().recover_poison();
            if *epoch != seen {
                continue;
            }
            // The timekeeper drops its flag before it reads the count, a
            // frontend counts itself before it reads the flag: one of them
            // sees the other, so a waiting frontend always has a timekeeper
            // or a reservation whose end elects one.
            if reservation.is_none()
                && timekeeper.is_none()
                && self.frontend_waiting.load(Ordering::SeqCst) > 0
                && !self.timekeeper.load(Ordering::SeqCst)
                && !self.reserved.load(Ordering::SeqCst)
            {
                continue;
            }
            let condvar =
                if reservation.is_some() { &self.reserved_turn } else { &self.automation };
            let timeout = timekeeper.as_ref().map(|(_, since)| {
                self.reserve_at(*since).saturating_duration_since(Instant::now())
            });
            drop(self.park(condvar, epoch, timeout));
        }
    }

    /// When a timekeeper timing since `since` reserves the next automation
    /// admission: due a gap after the last one, and after frontends began
    /// to keep automation out, so the first frontend never waits behind it.
    fn reserve_at(&self, since: Instant) -> Instant {
        let last = self.origin + Duration::from_nanos(self.last_admission.load(Ordering::SeqCst));
        last.max(since) + AUTOMATION_ADMIT_GAP - RESERVE_LEAD
    }

    /// A frontend began to wait: wake one parked automation caller to time
    /// automation's next admission, unless one already does or an open
    /// reservation will elect one when it ends.
    fn kick_timekeeper(&self) {
        fence(Ordering::SeqCst);
        if self.automation_parked.load(Ordering::SeqCst) == 0
            || self.timekeeper.load(Ordering::SeqCst)
            || self.reserved.load(Ordering::SeqCst)
        {
            return;
        }
        let mut epoch = self.epoch.lock().recover_poison();
        *epoch = epoch.wrapping_add(1);
        self.automation.notify_one();
    }

    /// A frontend caller with no ranked lock waits while an automation
    /// admission is reserved: the reserved caller takes the lock at the
    /// next release and wakes this caller when it has.
    fn wait_behind_reservation(&self) {
        if !self.reserved.load(Ordering::SeqCst) {
            return;
        }
        let _parked = Parked::enter(self, None);
        let mut epoch = self.epoch.lock().recover_poison();
        while self.reserved.load(Ordering::SeqCst) {
            epoch = self.park(&self.frontends, epoch, None);
        }
    }

    fn park<'a>(
        &self,
        condvar: &Condvar,
        epoch: std::sync::MutexGuard<'a, u64>,
        timeout: Option<Duration>,
    ) -> std::sync::MutexGuard<'a, u64> {
        let epoch = match timeout {
            // wakeup-allow: deadline automation's next due admission, timed only while a frontend waits on the lock
            Some(timeout) => condvar.wait_timeout(epoch, timeout).recover_poison().0,
            None => condvar.wait(epoch).recover_poison(),
        };
        #[cfg(test)]
        self.wakeups.fetch_add(1, Ordering::Relaxed);
        epoch
    }

    fn epoch_value(&self) -> u64 {
        *self.epoch.lock().recover_poison()
    }

    fn nanos(&self, at: Instant) -> u64 {
        u64::try_from(at.saturating_duration_since(self.origin).as_nanos()).unwrap_or(u64::MAX)
    }

    /// Watch releases until the token drops (a deadline waiter): read
    /// [`ReleaseWatch::epoch`] before each attempt, then
    /// [`ReleaseWatch::wait`].
    #[cfg(test)]
    pub(crate) fn watch_releases(&self) -> ReleaseWatch<'_> {
        self.watchers.fetch_add(1, Ordering::SeqCst);
        ReleaseWatch { gate: self, _parked: Parked::enter(self, None) }
    }

    /// After a hold ended: record it (none for a re-entry) and, when the
    /// lock is `free`, wake the one caller that can act on it.
    fn release(&self, hold: Option<(EventCause, Duration)>, free: bool) {
        if let Some((cause, held)) = hold {
            self.stats.held(cause, held);
        }
        if free {
            self.released();
        }
    }

    /// The lock is free: wake the one caller that can act on it.
    fn released(&self) {
        // Pairs with the fence in `Parked::enter`: either this release sees
        // the parked caller, or that caller's next attempt sees the release.
        fence(Ordering::SeqCst);
        if self.parked.load(Ordering::SeqCst) == 0 {
            return;
        }
        let mut epoch = self.epoch.lock().recover_poison();
        *epoch = epoch.wrapping_add(1);
        if self.reserved.load(Ordering::SeqCst) {
            self.reserved_turn.notify_one();
        } else if self.frontend_waiting.load(Ordering::SeqCst) == 0 {
            self.automation.notify_one();
        }
        if self.watchers.load(Ordering::SeqCst) > 0 {
            self.any_release.notify_all();
        }
    }

    /// A reservation held open for a test, as a timekeeper holds one.
    #[cfg(test)]
    pub(crate) fn reserve_for_test(&self) -> impl Drop + '_ {
        Reservation::claim(self).expect("no admission is reserved")
    }

    /// Condvar wakeups so far.
    #[cfg(test)]
    pub(crate) fn wakeups(&self) -> u64 {
        self.wakeups.load(Ordering::Relaxed)
    }
}

/// See [`PriorityGate::admission`].
pub(crate) struct Admission<'a> {
    gate: &'a PriorityGate,
    cause: EventCause,
    /// A frontend caller's place in `frontend_waiting`.
    _frontend: Option<Counted<'a>>,
}

impl Admission<'_> {
    /// The attempt without waiting: `None` when the caller must wait (the
    /// lock is held, or the gate keeps this class out).
    pub(crate) fn try_admit<G>(
        &self,
        try_acquire: &impl Fn() -> Option<G>,
    ) -> Option<(G, HoldTicket)> {
        let gate = self.gate;
        match self.cause {
            EventCause::Frontend if gate.reserved.load(Ordering::SeqCst) => None,
            EventCause::Automation => gate.try_automation(try_acquire, false),
            EventCause::Frontend | EventCause::Program => try_acquire(),
        }
        .map(|guard| (guard, gate.admitted(self.cause, None)))
    }

    /// The wait after a failed [`Self::try_admit`].
    pub(crate) fn admit<G>(
        &self,
        try_acquire: &impl Fn() -> Option<G>,
        block: impl FnOnce() -> G,
    ) -> (G, HoldTicket) {
        let gate = self.gate;
        let start = Instant::now();
        match self.cause {
            EventCause::Frontend => {
                gate.kick_timekeeper();
                if HeldRank::may_yield() {
                    gate.wait_behind_reservation();
                }
                (block(), gate.admitted(self.cause, Some(start)))
            }
            EventCause::Automation if HeldRank::may_yield() => {
                gate.park_automation(try_acquire, start)
            }
            EventCause::Automation | EventCause::Program => {
                (block(), gate.admitted(self.cause, Some(start)))
            }
        }
    }
}

/// A caller parked on the gate (and, for automation, on its condvar) until
/// dropped; releases wake it.
struct Parked<'a> {
    gate: &'a PriorityGate,
    class: Option<&'a AtomicUsize>,
}

impl<'a> Parked<'a> {
    fn enter(gate: &'a PriorityGate, class: Option<&'a AtomicUsize>) -> Self {
        gate.parked.fetch_add(1, Ordering::SeqCst);
        if let Some(class) = class {
            class.fetch_add(1, Ordering::SeqCst);
        }
        fence(Ordering::SeqCst);
        Self { gate, class }
    }
}

impl Drop for Parked<'_> {
    fn drop(&mut self) {
        if let Some(class) = self.class {
            class.fetch_sub(1, Ordering::SeqCst);
        }
        self.gate.parked.fetch_sub(1, Ordering::SeqCst);
    }
}

/// The reserved automation admission. Dropping it (once the reserved caller
/// holds the lock) wakes the frontends behind it and, while frontends still
/// wait, one parked automation caller to time the next admission.
struct Reservation<'a> {
    gate: &'a PriorityGate,
}

impl<'a> Reservation<'a> {
    /// The token exists only when this caller set the flag: its drop
    /// clears it.
    fn claim(gate: &'a PriorityGate) -> Option<Self> {
        let won =
            gate.reserved.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_ok();
        if won { Some(Self { gate }) } else { None }
    }
}

impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        let gate = self.gate;
        gate.reserved.store(false, Ordering::SeqCst);
        fence(Ordering::SeqCst);
        if gate.parked.load(Ordering::SeqCst) == 0 {
            return;
        }
        let mut epoch = gate.epoch.lock().recover_poison();
        *epoch = epoch.wrapping_add(1);
        gate.frontends.notify_all();
        if gate.frontend_waiting.load(Ordering::SeqCst) > 0 {
            gate.automation.notify_one();
        }
    }
}

/// A flag this caller set and clears when dropped.
struct Flag<'a>(&'a AtomicBool);

impl<'a> Flag<'a> {
    /// The token exists only when this caller set the flag: its drop
    /// clears it.
    fn claim(flag: &'a AtomicBool) -> Option<Self> {
        let won = flag.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_ok();
        if won { Some(Self(flag)) } else { None }
    }
}

impl Drop for Flag<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// A deadline waiter; see [`PriorityGate::watch_releases`].
#[cfg(test)]
pub(crate) struct ReleaseWatch<'a> {
    gate: &'a PriorityGate,
    _parked: Parked<'a>,
}

#[cfg(test)]
impl ReleaseWatch<'_> {
    /// The release epoch, read before an attempt.
    pub(crate) fn epoch(&self) -> u64 {
        self.gate.epoch_value()
    }

    /// Wait at most `timeout` for a release after `seen`.
    pub(crate) fn wait(&self, seen: u64, timeout: Duration) {
        let epoch = self.gate.epoch.lock().recover_poison();
        if *epoch == seen {
            drop(self.gate.park(&self.gate.any_release, epoch, Some(timeout)));
        }
    }
}

#[cfg(test)]
impl Drop for ReleaseWatch<'_> {
    fn drop(&mut self) {
        self.gate.watchers.fetch_sub(1, Ordering::SeqCst);
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

/// A guard of a lock the gate admits to.
pub(crate) trait GateGuard {
    /// Unlock. True when the lock is free of this thread now; false when an
    /// outer hold of a reentrant lock still keeps it, so no waiter can act.
    fn unlock(self) -> bool;
}

impl<T> GateGuard for std::sync::MutexGuard<'_, T> {
    fn unlock(self) -> bool {
        drop(self);
        true
    }
}

impl<T> GateGuard for parking_lot::ReentrantMutexGuard<'_, T> {
    fn unlock(self) -> bool {
        let mutex = Self::remutex(&self);
        drop(self);
        !mutex.is_owned_by_current_thread()
    }
}

impl<T> GateGuard
    for parking_lot::lock_api::ArcReentrantMutexGuard<
        parking_lot::RawMutex,
        parking_lot::RawThreadId,
        T,
    >
{
    fn unlock(self) -> bool {
        !Self::into_arc(self).is_owned_by_current_thread()
    }
}

/// A lock guard admitted through a gate. Dropping it unlocks, records the
/// hold, then wakes a waiter once the lock is free of this thread.
pub(crate) struct Gated<G: GateGuard, R: Deref<Target = PriorityGate>> {
    /// Taken only by `drop`.
    guard: ManuallyDrop<G>,
    gate: R,
    /// `None` for a re-entry of a reentrant lock: it waited for nothing.
    ticket: Option<HoldTicket>,
    /// The hold, once the caller measured it ([`Gated::record_hold`]).
    held: Option<Duration>,
}

impl<G: GateGuard, R: Deref<Target = PriorityGate>> Drop for Gated<G, R> {
    fn drop(&mut self) {
        // SAFETY: `guard` is taken here only, and never used after.
        let guard = unsafe { ManuallyDrop::take(&mut self.guard) };
        let free = guard.unlock();
        let hold = self.ticket.map(|ticket| {
            (ticket.cause, self.held.unwrap_or_else(|| ticket.acquired_at.elapsed()))
        });
        self.gate.release(hold, free);
    }
}

impl<G: GateGuard, R: Deref<Target = PriorityGate>> Gated<G, R> {
    pub(crate) fn new(guard: G, gate: R, ticket: HoldTicket) -> Self {
        Self { guard: ManuallyDrop::new(guard), gate, ticket: Some(ticket), held: None }
    }

    /// A re-entry of a reentrant lock this thread already holds.
    pub(crate) fn reentered(guard: G, gate: R) -> Self {
        Self { guard: ManuallyDrop::new(guard), gate, ticket: None, held: None }
    }

    /// The hold a caller already measured for its own release record, so
    /// the gate's record reads no clock of its own.
    pub(crate) fn record_hold(&mut self, held: Duration) {
        self.held = Some(held);
    }
}

impl<G: GateGuard, R: Deref<Target = PriorityGate>> Deref for Gated<G, R> {
    type Target = G;

    fn deref(&self) -> &G {
        &self.guard
    }
}

impl<G: GateGuard, R: Deref<Target = PriorityGate>> DerefMut for Gated<G, R> {
    fn deref_mut(&mut self) -> &mut G {
        &mut self.guard
    }
}
