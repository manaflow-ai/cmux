//! Hang watch for the processes that have no daemon request watchdog
//! (holder, terminal host, acpmux): a thread opens a [`HangScope`] with a
//! deadline around one unit of work, and the `mux-hang-watch` thread records
//! a scope still open past its deadline, once.
//!
//! Chrome's HangWatcher (base/threading/hang_watcher.cc, `HangWatchState`
//! and `HangWatchDeadline`): each watched thread owns one 64-bit atomic that
//! holds its current deadline, and opening a scope is one clock read and a
//! few stores into it, with no lock and no system call. Unlike Chrome's
//! fixed monitoring period:
//!
//! - A global armed-scope count wakes the watcher only when it goes from 0 to
//!   1 while the watcher is parked.
//! - While scopes open and close, the watcher sleeps to the earliest open
//!   deadline, at most one minimum deadline (the shortest [`HangSite`] seen),
//!   so detection is within deadline plus minimum deadline. The first scope
//!   of a site shorter than every site before wakes the watcher to plan its
//!   sleep again, once per such site. It parks with no
//!   timeout after a wake that finds no scope open and none opened since its
//!   last wake: 0 wakes while idle, and at most one wake per minimum deadline
//!   under any scope pattern.
//! - An overdue scope becomes one [`HangRecord`] in a ring of
//!   [`HANG_RING`] and one call of the process's [`HangSink`] (the hang log
//!   line, cmux-panic-log `hang`). A nested scope saves and restores the
//!   outer deadline, and a scope already recorded is not recorded again
//!   when it is restored (the watcher flags the word it recorded). The
//!   watcher reads a slot's deadline and site as one pair under a seqlock:
//!   each open and close writes both inside one generation, so a pair read
//!   across a nested open and close (which restores the same word) is not
//!   used. A panicking sink is counted, never fatal.
//!
//! The daemon does not use this: its one hang watcher is the request
//! watchdog (cmux-tui-core `server/request_watchdog.rs`).
//!
//! Lock carve-out: `owners` is held only when a thread claims or releases
//! its slot (once per thread and watcher) and when the watcher writes a
//! record; `ring` only to push a record and for [`HangWatcher::snapshot`];
//! `state` is the watcher's condvar mutex, taken by a scope only to wake a
//! parked watcher and by the first scope of a new shortest site. No scope
//! open or close takes a lock otherwise.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::io;
use std::marker::PhantomData;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU64, AtomicUsize, Ordering, fence};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use crate::qos::ThreadQos;

/// The watcher thread's name.
pub const THREAD_NAME: &str = "mux-hang-watch";

/// Records kept for [`HangWatcher::snapshot`].
pub const HANG_RING: usize = 128;

/// Threads watched at once per watcher; a thread past it is counted in
/// [`HangSnapshot::unwatched`] and its scopes are not watched.
pub const MAX_WATCHED_THREADS: usize = 512;

/// Low bits of a slot word: the recorded flag and a per-thread sequence, so
/// a reused deadline is never mistaken for one already recorded.
const SEQ_BITS: u32 = 16;
/// Set by the watcher on the word of a scope it recorded; a nested scope
/// that saved the word restores it with the flag.
const RECORDED: u64 = 1 << (SEQ_BITS - 1);
const SEQ_MASK: u16 = (RECORDED - 1) as u16;

/// A watcher wake this far past its plan blames nobody.
const LATE_US: u64 = 100_000;

/// One kind of watched work and its deadline, declared as a `static`.
#[derive(Debug)]
pub struct HangSite {
    name: &'static str,
    deadline: Duration,
}

impl HangSite {
    pub const fn new(name: &'static str, deadline: Duration) -> Self {
        Self { name, deadline }
    }

    pub fn name(&self) -> &'static str {
        self.name
    }

    pub fn deadline(&self) -> Duration {
        self.deadline
    }

    fn deadline_us(&self) -> u64 {
        u64::try_from(self.deadline.as_micros()).unwrap_or(u64::MAX >> SEQ_BITS).max(1)
    }
}

/// A scope that was still open past its deadline.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HangRecord {
    /// The [`HangSite`] name.
    pub site: &'static str,
    pub deadline_ms: u64,
    /// The watched thread's name.
    pub thread: String,
    /// The kernel thread id (Linux tid, macOS pthread_threadid_np).
    pub tid: Option<u64>,
    /// How long the scope had been open when the watcher saw it.
    pub busy_ms: u64,
    /// When it was recorded, in ms since the watcher started.
    pub at_ms: u64,
}

/// Where each record goes, once, from the watcher thread.
pub type HangSink = Box<dyn Fn(&HangRecord) + Send + Sync>;

/// [`HangWatcher::snapshot`].
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HangSnapshot {
    /// The newest records, oldest first, at most [`HANG_RING`].
    pub recent: Vec<HangRecord>,
    /// Every record since start.
    pub total: u64,
    /// Scopes opened on a thread that found every slot taken.
    pub unwatched: u64,
    /// Times the watcher thread woke.
    pub wakeups: u64,
    /// Records whose sink panicked.
    pub sink_panics: u64,
    /// Overdue scopes not recorded because the watcher itself woke over
    /// 100 ms late.
    pub unblamed: u64,
}

/// One watched thread's deadline, as Chrome's `HangWatchDeadline`.
struct Slot {
    /// 0, or `(deadline_us + 1) << SEQ_BITS | RECORDED? | seq`.
    word: AtomicU64,
    /// The open scope's site; null with no scope open.
    site: AtomicPtr<HangSite>,
    /// Seqlock over `word` and `site`, odd while they are written. Only the
    /// slot's owner writes it; a new owner claims the slot under `owners`
    /// after the old one released it there.
    generation: AtomicU64,
}

impl Slot {
    fn new() -> Self {
        Self {
            word: AtomicU64::new(0),
            site: AtomicPtr::new(std::ptr::null_mut()),
            generation: AtomicU64::new(0),
        }
    }

    /// Starts a write of `word` and `site`; pass the result to
    /// [`Slot::end_write`].
    fn begin_write(&self) -> u64 {
        let generation = self.generation.load(Ordering::Relaxed).wrapping_add(1);
        self.generation.store(generation, Ordering::Relaxed);
        fence(Ordering::Release);
        generation
    }

    fn end_write(&self, generation: u64) {
        self.generation.store(generation.wrapping_add(1), Ordering::Release);
    }
}

struct Owner {
    thread: String,
    tid: Option<u64>,
}

#[derive(Default)]
struct Ring {
    recent: VecDeque<HangRecord>,
    total: u64,
}

impl Ring {
    fn push(&mut self, record: HangRecord, capacity: usize) {
        if self.recent.len() == capacity {
            self.recent.pop_front();
        }
        self.recent.push_back(record);
        self.total += 1;
    }
}

#[derive(Default)]
struct State {
    stop: bool,
    /// The minimum deadline went down: a sleeping watcher plans again.
    replan: bool,
}

struct Shared {
    epoch: Instant,
    slots: Box<[Slot]>,
    /// Slots claimed so far (the watcher scans `slots[..claimed]`).
    claimed: AtomicUsize,
    owners: Mutex<Vec<Option<Owner>>>,
    armed: AtomicUsize,
    /// A scope opened since the watcher's last wake.
    touched: AtomicBool,
    /// The watcher waits with no timeout; a 0 -> 1 arm wakes it.
    parked: AtomicBool,
    stopped: AtomicBool,
    min_deadline_us: AtomicU64,
    state: Mutex<State>,
    wake: Condvar,
    ring: Mutex<Ring>,
    ring_capacity: usize,
    sink: HangSink,
    unwatched: AtomicU64,
    wakeups: AtomicU64,
    sink_panics: AtomicU64,
    unblamed: AtomicU64,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

fn deadline_of(word: u64) -> Option<u64> {
    (word >> SEQ_BITS).checked_sub(1)
}

impl Shared {
    fn now_us(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn slot(&self, index: usize) -> &Slot {
        &self.slots[index]
    }

    /// Claims a slot for the calling thread, `None` when all are taken.
    fn claim(&self) -> Option<usize> {
        let current = std::thread::current();
        let owner = Owner {
            thread: current.name().unwrap_or("unnamed").to_owned(),
            tid: crate::registry::current_tid(),
        };
        let mut owners = lock(&self.owners);
        let index = match owners.iter().position(Option::is_none) {
            Some(free) => free,
            None if owners.len() < self.slots.len() => {
                owners.push(None);
                self.claimed.store(owners.len(), Ordering::Release);
                owners.len() - 1
            }
            None => return None,
        };
        let slot = self.slot(index);
        slot.word.store(0, Ordering::Relaxed);
        owners[index] = Some(owner);
        Some(index)
    }

    fn release(&self, index: usize) {
        let mut owners = lock(&self.owners);
        let slot = self.slot(index);
        let generation = slot.begin_write();
        slot.word.store(0, Ordering::Relaxed);
        slot.site.store(std::ptr::null_mut(), Ordering::Relaxed);
        slot.end_write(generation);
        owners[index] = None;
    }

    /// A site shorter than every site before shortens the watcher's period:
    /// a watcher asleep on the longer period wakes to plan again.
    fn lower_min_deadline(&self, site_us: u64) {
        if self.min_deadline_us.fetch_min(site_us, Ordering::Relaxed) > site_us {
            lock(&self.state).replan = true;
            self.wake.notify_one();
        }
    }

    fn arm(&self) {
        if self.armed.fetch_add(1, Ordering::SeqCst) == 0 && self.parked.load(Ordering::SeqCst) {
            let _state = lock(&self.state);
            if self.parked.swap(false, Ordering::SeqCst) {
                self.wake.notify_one();
            }
        }
    }

    /// Records every overdue scope not recorded yet, or with `blame` false
    /// (the watcher itself woke late) flags it with no record; returns the
    /// earliest deadline still ahead.
    fn scan(&self, now: u64, blame: bool) -> Option<u64> {
        self.scan_with(now, blame, || {})
    }

    /// [`Shared::scan`]; `between` runs after an overdue word is read and
    /// before its site is (a test seam for a nested scope in that gap).
    fn scan_with(&self, now: u64, blame: bool, mut between: impl FnMut()) -> Option<u64> {
        let mut earliest: Option<u64> = None;
        let claimed = self.claimed.load(Ordering::Acquire);
        for index in 0..claimed {
            let slot = self.slot(index);
            let generation = slot.generation.load(Ordering::Acquire);
            let word = slot.word.load(Ordering::Relaxed);
            let Some(deadline) = deadline_of(word) else { continue };
            if deadline > now {
                earliest = Some(earliest.map_or(deadline, |e| e.min(deadline)));
                continue;
            }
            if word & RECORDED != 0 {
                continue;
            }
            between();
            let site = slot.site.load(Ordering::Relaxed);
            fence(Ordering::Acquire);
            // A pair read during or across a write is looked at on the next
            // wake; a nested open and close restores the same word, so only
            // the generation tells them apart.
            if !generation.is_multiple_of(2)
                || slot.generation.load(Ordering::Relaxed) != generation
            {
                continue;
            }
            // The flag goes on only while the word is still the one read: an
            // open after the pair was read swaps the word out, and keeps the
            // flag when the exchange came first.
            let marked = slot.word.compare_exchange(
                word,
                word | RECORDED,
                Ordering::AcqRel,
                Ordering::Relaxed,
            );
            if site.is_null() || marked.is_err() {
                continue;
            }
            if !blame {
                self.unblamed.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            // SAFETY: only `&'static HangSite`s are stored in `site`.
            let site: &'static HangSite = unsafe { &*site };
            self.record(index, site, deadline, now);
        }
        earliest
    }

    fn record(&self, index: usize, site: &'static HangSite, deadline: u64, now: u64) {
        let (thread, tid) = match lock(&self.owners).get(index) {
            Some(Some(owner)) => (owner.thread.clone(), owner.tid),
            _ => return,
        };
        let start = deadline.saturating_sub(site.deadline_us());
        let record = HangRecord {
            site: site.name,
            deadline_ms: site.deadline_us() / 1000,
            thread,
            tid,
            busy_ms: now.saturating_sub(start) / 1000,
            at_ms: now / 1000,
        };
        lock(&self.ring).push(record.clone(), self.ring_capacity);
        if catch_unwind(AssertUnwindSafe(|| (self.sink)(&record))).is_err() {
            self.sink_panics.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// The longest the watcher sleeps while scopes open and close.
    fn period(&self) -> Duration {
        Duration::from_micros(self.min_deadline_us.load(Ordering::Relaxed).max(1_000))
    }

    /// Waits until a scope arms the watcher; `false` once it stops.
    fn park(&self) -> bool {
        let mut state = lock(&self.state);
        loop {
            if state.stop {
                return false;
            }
            self.parked.store(true, Ordering::SeqCst);
            if self.armed.load(Ordering::SeqCst) > 0 {
                self.parked.store(false, Ordering::SeqCst);
                break;
            }
            state = self.wake.wait(state).unwrap_or_else(PoisonError::into_inner);
            if !self.parked.load(Ordering::SeqCst) {
                self.wakeups.fetch_add(1, Ordering::Relaxed);
                if state.stop {
                    return false;
                }
                break;
            }
        }
        // run() plans its first sleep from the period it reads after this.
        state.replan = false;
        true
    }

    /// Sleeps for `timeout`, or until a new shortest site needs a new plan;
    /// `false` once the watcher stops.
    fn sleep(&self, timeout: Duration) -> bool {
        let mut state = lock(&self.state);
        if state.stop {
            return false;
        }
        if !state.replan {
            // wakeup-allow: deadline the earliest open scope's deadline; with no scope open the watcher parks in park() with no timeout
            state =
                self.wake.wait_timeout(state, timeout).unwrap_or_else(PoisonError::into_inner).0;
        }
        state.replan = false;
        self.wakeups.fetch_add(1, Ordering::Relaxed);
        !state.stop
    }

    fn run(&self) {
        while self.park() {
            // Nothing is overdue yet: no scope was open before the one that
            // armed the watcher, and its deadline is at least one period.
            self.touched.store(false, Ordering::Relaxed);
            let mut wait = self.period();
            loop {
                let planned = self.now_us().saturating_add(micros(wait));
                if !self.sleep(wait) {
                    return;
                }
                let now = self.now_us();
                // A watcher that wakes late blames nobody (Chrome's
                // HangWatcher skips a monitoring pass that ran late): a
                // starved watcher thread is not a hang of the threads it
                // watches.
                let next = self.scan(now, now <= planned.saturating_add(LATE_US));
                let opened = self.touched.swap(false, Ordering::Relaxed);
                if !opened && self.armed.load(Ordering::SeqCst) == 0 {
                    break;
                }
                let period = self.period();
                wait = next.map_or(period, |deadline| {
                    Duration::from_micros(deadline.saturating_sub(now)).min(period)
                });
            }
        }
    }
}

/// The process's hang watcher: one `mux-hang-watch` thread at Utility.
/// Dropping it stops the thread.
pub struct HangWatcher {
    shared: Arc<Shared>,
}

impl HangWatcher {
    /// Starts the watcher thread; it parks until the first scope opens.
    pub fn start(sink: HangSink) -> io::Result<Self> {
        Self::start_with(sink, MAX_WATCHED_THREADS, HANG_RING)
    }

    fn start_with(sink: HangSink, threads: usize, ring: usize) -> io::Result<Self> {
        let watcher = Self::unstarted(sink, threads, ring);
        let shared = Arc::clone(&watcher.shared);
        crate::spawn(THREAD_NAME, ThreadQos::Utility, move || shared.run())?;
        Ok(watcher)
    }

    /// A watcher with no thread: scopes fill its slots, nothing scans them.
    fn unstarted(sink: HangSink, threads: usize, ring: usize) -> Self {
        let slots = (0..threads).map(|_| Slot::new()).collect();
        let shared = Arc::new(Shared {
            epoch: Instant::now(),
            slots,
            claimed: AtomicUsize::new(0),
            owners: Mutex::new(Vec::new()),
            armed: AtomicUsize::new(0),
            touched: AtomicBool::new(false),
            parked: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            min_deadline_us: AtomicU64::new(u64::MAX),
            state: Mutex::new(State::default()),
            wake: Condvar::new(),
            ring: Mutex::new(Ring::default()),
            ring_capacity: ring,
            sink,
            unwatched: AtomicU64::new(0),
            wakeups: AtomicU64::new(0),
            sink_panics: AtomicU64::new(0),
            unblamed: AtomicU64::new(0),
        });
        Self { shared }
    }

    /// Watches the calling thread until the scope drops: past
    /// `site.deadline()` it is recorded once.
    // perf-hot: <50ns hang-scope
    pub fn scope(&self, site: &'static HangSite) -> HangScope<'_> {
        let Some((index, seq)) = self.claim_current() else {
            self.shared.unwatched.fetch_add(1, Ordering::Relaxed);
            return HangScope { open: None, _thread: PhantomData };
        };
        let shared = &*self.shared;
        let site_us = site.deadline_us();
        if site_us < shared.min_deadline_us.load(Ordering::Relaxed) {
            shared.lower_min_deadline(site_us);
        }
        let deadline = shared.now_us().saturating_add(site_us);
        let word = (deadline.saturating_add(1) << SEQ_BITS) | u64::from(seq & SEQ_MASK);
        let slot = shared.slot(index);
        let generation = slot.begin_write();
        let previous_site = slot.site.load(Ordering::Relaxed);
        // The swap keeps a flag the watcher set on the outer word just now.
        let previous_word = slot.word.swap(word, Ordering::Acquire);
        slot.site.store(std::ptr::from_ref(site).cast_mut(), Ordering::Relaxed);
        slot.end_write(generation);
        if !shared.touched.load(Ordering::Relaxed) {
            shared.touched.store(true, Ordering::Relaxed);
        }
        shared.arm();
        HangScope {
            open: Some(OpenScope { shared, index, previous_word, previous_site }),
            _thread: PhantomData,
        }
    }

    /// What the watcher has recorded and counted.
    pub fn snapshot(&self) -> HangSnapshot {
        let shared = &*self.shared;
        let ring = lock(&shared.ring);
        HangSnapshot {
            recent: ring.recent.iter().cloned().collect(),
            total: ring.total,
            unwatched: shared.unwatched.load(Ordering::Relaxed),
            wakeups: shared.wakeups.load(Ordering::Relaxed),
            sink_panics: shared.sink_panics.load(Ordering::Relaxed),
            unblamed: shared.unblamed.load(Ordering::Relaxed),
        }
    }

    /// The calling thread's slot in this watcher and its next sequence.
    fn claim_current(&self) -> Option<(usize, u16)> {
        CLAIMS
            .try_with(|claims| {
                let mut claims = claims.borrow_mut();
                let position = claims.iter().position(|c| Arc::ptr_eq(&c.shared, &self.shared));
                let claim = match position {
                    Some(position) => &mut claims[position],
                    None => {
                        claims.retain(|c| !c.shared.stopped.load(Ordering::Relaxed));
                        let index = self.shared.claim()?;
                        claims.push(Claim { shared: Arc::clone(&self.shared), index, seq: 0 });
                        claims.last_mut()?
                    }
                };
                claim.seq = claim.seq.wrapping_add(1);
                Some((claim.index, claim.seq))
            })
            .ok()
            .flatten()
    }
}

impl Drop for HangWatcher {
    fn drop(&mut self) {
        self.shared.stopped.store(true, Ordering::Relaxed);
        lock(&self.shared.state).stop = true;
        self.shared.wake.notify_all();
    }
}

/// A thread's slot in one watcher, released when the thread exits.
struct Claim {
    shared: Arc<Shared>,
    index: usize,
    seq: u16,
}

impl Drop for Claim {
    fn drop(&mut self) {
        self.shared.release(self.index);
    }
}

thread_local! {
    static CLAIMS: RefCell<Vec<Claim>> = const { RefCell::new(Vec::new()) };
}

struct OpenScope<'a> {
    shared: &'a Shared,
    index: usize,
    previous_word: u64,
    previous_site: *mut HangSite,
}

/// An open hang scope; it stays on the thread that opened it.
#[must_use = "the scope is watched until it drops"]
pub struct HangScope<'a> {
    open: Option<OpenScope<'a>>,
    _thread: PhantomData<*const ()>,
}

impl Drop for HangScope<'_> {
    // perf-hot: <50ns hang-scope
    fn drop(&mut self) {
        let Some(open) = self.open.take() else { return };
        let slot = open.shared.slot(open.index);
        let generation = slot.begin_write();
        slot.site.store(open.previous_site, Ordering::Relaxed);
        slot.word.store(open.previous_word, Ordering::Relaxed);
        slot.end_write(generation);
        open.shared.armed.fetch_sub(1, Ordering::SeqCst);
    }
}

#[cfg(test)]
#[path = "hang_tests.rs"]
mod tests;
