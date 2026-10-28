//! Connection-lock waits over the contention budget, named by their holder.
//!
//! Chromium: base/synchronization/lock_impl.h (`LockImpl::Lock` tries the
//! lock first and only a failed try takes the tracked slow path,
//! `LockInternalWithTracking`) and base/synchronization/lock.h (a DCHECK
//! build keeps the owning thread, `owning_thread_ref_`). A [`LockHolder`]
//! does both for one lock: the uncontended acquisition is one try, plus the
//! holder's name published under the lock while holder tracking is on (debug
//! builds, or [`set_holder_tracking`]); a failed try is the slow path. It is
//! a [`BlockingKind::LockWait`] violation on a thread that disallows
//! blocking ([`crate::blocking`]), checked before the wait as Chrome's
//! `ScopedBlockingCall` checks on entry. The wait is timed, and a wait of
//! [`LOCK_WAIT_BUDGET`] or more is recorded with the name of the thread that
//! took the lock last before the waiter got it.
//!
//! Records go to a fixed ring of the [`RECENT_CAPACITY`] newest waits (read
//! with [`lock_waits`]; the daemon's `server-stats` `request_path_io`
//! section shows it) plus a process-wide count. Nothing here takes a lock or
//! allocates after a thread's first acquisition: names are copied into
//! atomics under a sequence counter (a seqlock, Boehm, "Can Seqlocks Get
//! Along with Programming Language Memory Models?").

use std::cell::Cell;
use std::panic::Location;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, AtomicU64, Ordering, fence};
use std::sync::{LockResult, Mutex, MutexGuard, TryLockError};
use std::time::{Duration, Instant};

use crate::blocking::{BlockingKind, assert_blocking_allowed_at};

/// A lock wait this long or longer is recorded (the contention budget the
/// app's `Mutex` and the daemon's std lock wrappers share).
pub const LOCK_WAIT_BUDGET: Duration = Duration::from_millis(2);

/// The newest long waits [`lock_waits`] keeps.
pub const RECENT_CAPACITY: usize = 64;

/// Bytes kept of a thread or lock name; longer names are cut at a character
/// boundary.
pub const NAME_CAPACITY: usize = NAME_WORDS * 8;

const NAME_WORDS: usize = 4;

/// Read attempts before a reader gives up on a slot a writer keeps changing.
const READ_ATTEMPTS: usize = 8;

/// A name copied by value, so it can live in atomics.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct NameBytes {
    words: [u64; NAME_WORDS],
    len: u8,
}

impl NameBytes {
    fn of(name: &str) -> Self {
        let mut len = name.len().min(NAME_CAPACITY);
        while !name.is_char_boundary(len) {
            len -= 1;
        }
        let mut bytes = [0u8; NAME_CAPACITY];
        bytes[..len].copy_from_slice(&name.as_bytes()[..len]);
        let mut words = [0u64; NAME_WORDS];
        for (word, chunk) in words.iter_mut().zip(bytes.chunks_exact(8)) {
            let mut le = [0u8; 8];
            le.copy_from_slice(chunk);
            *word = u64::from_le_bytes(le);
        }
        // `len` <= NAME_CAPACITY (32), so it fits.
        Self { words, len: len as u8 }
    }

    fn to_text(self) -> String {
        let mut bytes = [0u8; NAME_CAPACITY];
        for (chunk, word) in bytes.chunks_exact_mut(8).zip(self.words) {
            chunk.copy_from_slice(&word.to_le_bytes());
        }
        let len = usize::from(self.len).min(NAME_CAPACITY);
        String::from_utf8_lossy(&bytes[..len]).into_owned()
    }
}

/// A [`NameBytes`] in atomics. Readers and writers order it with the
/// sequence counter of the record that holds it.
#[derive(Default)]
struct AtomicName {
    words: [AtomicU64; NAME_WORDS],
    len: AtomicU64,
}

impl AtomicName {
    fn store(&self, name: NameBytes) {
        for (slot, word) in self.words.iter().zip(name.words) {
            slot.store(word, Ordering::Relaxed);
        }
        self.len.store(u64::from(name.len), Ordering::Relaxed);
    }

    fn load(&self) -> NameBytes {
        let mut words = [0u64; NAME_WORDS];
        for (word, slot) in words.iter_mut().zip(&self.words) {
            *word = slot.load(Ordering::Relaxed);
        }
        let len = self.len.load(Ordering::Relaxed).min(NAME_CAPACITY as u64) as u8;
        NameBytes { words, len }
    }
}

thread_local! {
    static CURRENT_NAME: Cell<Option<NameBytes>> = const { Cell::new(None) };
    /// Nanoseconds this thread has waited for locks, every wait counted.
    static THREAD_WAITED_NANOS: Cell<u64> = const { Cell::new(0) };
}

/// Adds `waited` to the calling thread's lock wait total
/// ([`thread_lock_wait_nanos`]). [`LockHolder`] counts its contended waits
/// here; a lock with its own wait timing (the daemon's registry mutex) adds
/// its waits too, so one request's lock wait is the change of the total over
/// its handler (Chrome's per-task `ThreadTicks` delta in
/// base/task/common/task_annotator.cc, with lock waits as the counter).
#[inline]
pub fn note_thread_lock_wait(waited: Duration) {
    let nanos = u64::try_from(waited.as_nanos()).unwrap_or(u64::MAX);
    let _ = THREAD_WAITED_NANOS.try_with(|total| total.set(total.get().saturating_add(nanos)));
}

/// Nanoseconds the calling thread has waited for locks since it started
/// ([`note_thread_lock_wait`]). Only differences of two reads on one thread
/// mean anything.
#[inline]
pub fn thread_lock_wait_nanos() -> u64 {
    THREAD_WAITED_NANOS.try_with(Cell::get).unwrap_or(0)
}

/// A contended wait of a lock without a [`LockHolder`] (the daemon's ranked
/// locks), timed by the lock after its failed try: a wait of
/// [`LOCK_WAIT_BUDGET`] or more on a thread that disallows blocking records
/// a [`BlockingKind::LockWait`] site at `site`, and never panics.
#[inline]
pub fn note_timed_lock_wait(waited: Duration, site: &'static Location<'static>) {
    if waited >= LOCK_WAIT_BUDGET {
        crate::blocking::note_long_lock_wait(site);
    }
}

/// The calling thread's name, read from std once per thread. An unnamed
/// thread is named by its `ThreadId`.
fn current_name() -> NameBytes {
    fn read() -> NameBytes {
        let thread = std::thread::current();
        match thread.name() {
            Some(name) => NameBytes::of(name),
            None => NameBytes::of(&format!("{:?}", thread.id())),
        }
    }
    CURRENT_NAME
        .try_with(|cached| {
            cached.get().unwrap_or_else(|| {
                let name = read();
                cached.set(Some(name));
                name
            })
        })
        .unwrap_or_else(|_| read())
}

/// Starts a seqlock write: the counter goes odd before any field changes.
fn begin_write(seq: &AtomicU64, from: u64) {
    seq.store(from.wrapping_add(1), Ordering::Relaxed);
    fence(Ordering::Release);
}

/// Reads a seqlock-guarded record: `None` when no write ever finished or a
/// writer kept it changing for every attempt.
fn read_consistent<T>(seq: &AtomicU64, read: impl Fn() -> T) -> Option<T> {
    for _ in 0..READ_ATTEMPTS {
        let before = seq.load(Ordering::Acquire);
        if before & 1 == 1 {
            std::hint::spin_loop();
            continue;
        }
        let value = read();
        fence(Ordering::Acquire);
        if seq.load(Ordering::Relaxed) == before {
            return (before != 0).then_some(value);
        }
    }
    None
}

/// Whether holders publish their names. On in debug builds (Chrome keeps the
/// owner only in DCHECK builds, `Lock::owning_thread_ref_`); a release
/// daemon turns it on with [`set_holder_tracking`] while it records.
static TRACK_HOLDERS: AtomicBool = AtomicBool::new(cfg!(debug_assertions));

/// Turns holder publication on or off for the process. Set it once at
/// startup: a waiter names the last thread that published, so a name is
/// reliable only when every holder since the switch published.
pub fn set_holder_tracking(on: bool) {
    TRACK_HOLDERS.store(on, Ordering::Relaxed);
}

/// Whether holders publish their names ([`set_holder_tracking`]).
pub fn tracks_holders() -> bool {
    TRACK_HOLDERS.load(Ordering::Relaxed)
}

/// The holder record of one lock. Embed it next to the lock and take the lock
/// only through [`LockHolder::acquire`], [`LockHolder::acquire_until`] or
/// [`LockHolder::lock_mutex`], so every holder publishes its name.
#[derive(Default)]
pub struct LockHolder {
    /// Odd while the holder's name is being written. Only a thread that holds
    /// the lock writes it, so writers never race each other.
    seq: AtomicU64,
    name: AtomicName,
    /// Threads past a failed try that have not got the lock or given up yet.
    waiting: AtomicU32,
}

impl std::fmt::Debug for LockHolder {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LockHolder")
            .field("holder", &self.holder())
            .field("waiting", &self.waiting())
            .finish()
    }
}

impl LockHolder {
    /// Takes the lock named `lock` for `site`: `try_lock` first, then `wait`,
    /// timed. A failed try on a thread that disallows blocking is a
    /// [`BlockingKind::LockWait`] violation at `site`, raised before the
    /// wait, so a panic-mode report never unwinds through a held guard. A
    /// wait of [`LOCK_WAIT_BUDGET`] or more is recorded with the name of the
    /// thread that took the lock last before this one got it.
    #[inline]
    pub fn acquire<G>(
        &self,
        lock: &'static str,
        site: &'static Location<'static>,
        try_lock: impl FnOnce() -> Option<G>,
        wait: impl FnOnce() -> G,
    ) -> G {
        if let Some(guard) = try_lock() {
            self.publish();
            return guard;
        }
        let contended = Contended::begin(self, site);
        let guard = wait();
        contended.end(lock, site);
        self.publish();
        guard
    }

    /// [`Self::acquire`] for a wait that can give up (a deadline): `None`
    /// when `wait` did. A long wait is recorded either way.
    #[inline]
    pub fn acquire_until<G>(
        &self,
        lock: &'static str,
        site: &'static Location<'static>,
        try_lock: impl FnOnce() -> Option<G>,
        wait: impl FnOnce() -> Option<G>,
    ) -> Option<G> {
        if let Some(guard) = try_lock() {
            self.publish();
            return Some(guard);
        }
        let contended = Contended::begin(self, site);
        let guard = wait();
        contended.end(lock, site);
        if guard.is_some() {
            self.publish();
        }
        guard
    }

    /// [`Self::acquire`] for a std `Mutex`, poisoning passed through as
    /// `Mutex::lock` returns it.
    #[inline]
    pub fn lock_mutex<'a, T>(
        &self,
        lock: &'static str,
        site: &'static Location<'static>,
        mutex: &'a Mutex<T>,
    ) -> LockResult<MutexGuard<'a, T>> {
        self.acquire(
            lock,
            site,
            || match mutex.try_lock() {
                Ok(guard) => Some(Ok(guard)),
                Err(TryLockError::Poisoned(poisoned)) => Some(Err(poisoned)),
                Err(TryLockError::WouldBlock) => None,
            },
            || mutex.lock(),
        )
    }

    /// The name of the thread that last took the lock: `None` before any
    /// did, or when none published (holder tracking off).
    pub fn holder(&self) -> Option<String> {
        self.holder_bytes().map(NameBytes::to_text)
    }

    /// The threads waiting for the lock now: past a failed try, and not yet
    /// holding it or given up.
    pub fn waiting(&self) -> u32 {
        self.waiting.load(Ordering::Acquire)
    }

    fn holder_bytes(&self) -> Option<NameBytes> {
        read_consistent(&self.seq, || self.name.load())
    }

    /// Publishes the calling thread as the holder. Called with the lock held;
    /// only a relaxed load of a global while holder tracking is off.
    #[inline]
    fn publish(&self) {
        if !tracks_holders() {
            return;
        }
        let name = current_name();
        let seq = self.seq.load(Ordering::Relaxed);
        begin_write(&self.seq, seq);
        self.name.store(name);
        self.seq.store(seq.wrapping_add(2), Ordering::Release);
    }
}

/// A wait that began after a failed try, counted in [`LockHolder::waiting`]
/// until it drops.
struct Contended<'a> {
    lock: &'a LockHolder,
    since: Instant,
}

impl<'a> Contended<'a> {
    #[cold]
    #[inline(never)]
    fn begin(lock: &'a LockHolder, site: &'static Location<'static>) -> Self {
        assert_blocking_allowed_at(BlockingKind::LockWait, site);
        let since = Instant::now();
        // Counted after the clock read: a holder that sees this waiter and
        // then keeps the lock for a time makes the timed wait at least as long.
        lock.waiting.fetch_add(1, Ordering::AcqRel);
        Self { lock, since }
    }

    /// Ends the wait, before the waiter publishes itself: the name read is
    /// the thread that took the lock last before the waiter got it (or gave
    /// up), so a thread that held it during the wait.
    fn end(self, lock: &'static str, site: &'static Location<'static>) {
        let waited = self.since.elapsed();
        note_thread_lock_wait(waited);
        if waited >= LOCK_WAIT_BUDGET {
            record(lock, self.lock.holder_bytes(), waited, site);
        }
    }
}

impl Drop for Contended<'_> {
    fn drop(&mut self) {
        self.lock.waiting.fetch_sub(1, Ordering::AcqRel);
    }
}

/// One recorded lock wait.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LockWait {
    /// The lock's name, as its owner passed it.
    pub lock: String,
    /// The thread that took the lock last before the waiter got it or gave
    /// up: a thread that held it during the wait. `None` when no holder
    /// published (holder tracking off, [`set_holder_tracking`]).
    pub holder: Option<String>,
    /// The thread that waited.
    pub waiter: String,
    pub waited: Duration,
    /// The code that asked for the lock.
    pub file: &'static str,
    pub line: u32,
    pub column: u32,
}

/// The process's long lock waits: the total, the newest records (newest
/// first), and the records a concurrent write to the same slot dropped.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LockWaitSnapshot {
    pub long_waits: u64,
    pub recent: Vec<LockWait>,
    pub dropped: u64,
}

impl LockWaitSnapshot {
    /// The newest recorded wait for the lock named `lock`.
    pub fn newest(&self, lock: &str) -> Option<&LockWait> {
        self.recent.iter().find(|wait| wait.lock == lock)
    }
}

/// The long lock waits recorded so far.
pub fn lock_waits() -> LockWaitSnapshot {
    let mut recent: Vec<(u64, LockWait)> = RECENT.iter().filter_map(|slot| slot.read()).collect();
    recent.sort_by_key(|(order, _)| std::cmp::Reverse(*order));
    LockWaitSnapshot {
        long_waits: LONG_WAITS.load(Ordering::Relaxed),
        recent: recent.into_iter().map(|(_, wait)| wait).collect(),
        dropped: DROPPED.load(Ordering::Relaxed),
    }
}

static LONG_WAITS: AtomicU64 = AtomicU64::new(0);
static DROPPED: AtomicU64 = AtomicU64::new(0);
static NEXT: AtomicU64 = AtomicU64::new(0);
static RECENT: [WaitSlot; RECENT_CAPACITY] = [const { WaitSlot::new() }; RECENT_CAPACITY];

#[cold]
#[inline(never)]
fn record(
    lock: &'static str,
    holder: Option<NameBytes>,
    waited: Duration,
    site: &'static Location<'static>,
) {
    LONG_WAITS.fetch_add(1, Ordering::Relaxed);
    let order = NEXT.fetch_add(1, Ordering::Relaxed);
    let slot = &RECENT[(order % RECENT_CAPACITY as u64) as usize];
    if !slot.write(order, lock, holder, waited, site) {
        DROPPED.fetch_add(1, Ordering::Relaxed);
    }
}

/// One ring entry. Several waiters can land on one slot, so a writer claims
/// it by moving the counter from even to odd; a writer that loses skips.
struct WaitSlot {
    seq: AtomicU64,
    order: AtomicU64,
    lock: AtomicName,
    holder: AtomicName,
    has_holder: AtomicU64,
    waiter: AtomicName,
    waited_ns: AtomicU64,
    site: AtomicPtr<Location<'static>>,
}

impl WaitSlot {
    const fn new() -> Self {
        const fn name() -> AtomicName {
            AtomicName { words: [const { AtomicU64::new(0) }; NAME_WORDS], len: AtomicU64::new(0) }
        }
        Self {
            seq: AtomicU64::new(0),
            order: AtomicU64::new(0),
            lock: name(),
            holder: name(),
            has_holder: AtomicU64::new(0),
            waiter: name(),
            waited_ns: AtomicU64::new(0),
            site: AtomicPtr::new(std::ptr::null_mut()),
        }
    }

    fn write(
        &self,
        order: u64,
        lock: &'static str,
        holder: Option<NameBytes>,
        waited: Duration,
        site: &'static Location<'static>,
    ) -> bool {
        let seq = self.seq.load(Ordering::Relaxed);
        if seq & 1 == 1
            || self
                .seq
                .compare_exchange(seq, seq.wrapping_add(1), Ordering::Relaxed, Ordering::Relaxed)
                .is_err()
        {
            return false;
        }
        fence(Ordering::Release);
        self.order.store(order, Ordering::Relaxed);
        self.lock.store(NameBytes::of(lock));
        self.holder.store(holder.unwrap_or(NameBytes { words: [0; NAME_WORDS], len: 0 }));
        self.has_holder.store(u64::from(holder.is_some()), Ordering::Relaxed);
        self.waiter.store(current_name());
        self.waited_ns
            .store(u64::try_from(waited.as_nanos()).unwrap_or(u64::MAX), Ordering::Relaxed);
        self.site.store(std::ptr::from_ref(site).cast_mut(), Ordering::Relaxed);
        self.seq.store(seq.wrapping_add(2), Ordering::Release);
        true
    }

    fn read(&self) -> Option<(u64, LockWait)> {
        let (order, lock, holder, has_holder, waiter, waited_ns, site) =
            read_consistent(&self.seq, || {
                (
                    self.order.load(Ordering::Relaxed),
                    self.lock.load(),
                    self.holder.load(),
                    self.has_holder.load(Ordering::Relaxed) != 0,
                    self.waiter.load(),
                    self.waited_ns.load(Ordering::Relaxed),
                    self.site.load(Ordering::Relaxed),
                )
            })?;
        if site.is_null() {
            return None;
        }
        // SAFETY: a finished write stores a `&'static Location`, and the
        // sequence check above saw that write finished.
        let site = unsafe { &*site };
        Some((
            order,
            LockWait {
                lock: lock.to_text(),
                holder: has_holder.then(|| holder.to_text()),
                waiter: waiter.to_text(),
                waited: Duration::from_nanos(waited_ns),
                file: site.file(),
                line: site.line(),
                column: site.column(),
            },
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blocking::{BlockingMode, disallow_blocking, set_mode, snapshot};
    use std::sync::Arc;
    use std::sync::mpsc::channel;

    /// How long a holder keeps the lock after it saw the waiter wait.
    const HOLD: Duration = Duration::from_millis(20);

    #[track_caller]
    fn here() -> &'static Location<'static> {
        Location::caller()
    }

    /// Holds `mutex` on a thread named `holder_name` and runs `wait` on a
    /// thread named `waiter_name`. The holder keeps the lock until the waiter
    /// failed its try ([`LockHolder::waiting`]), then [`HOLD`] longer, so
    /// the wait happens and lasts at least that long under any load.
    fn contend<R: Send + 'static>(
        holder_name: &str,
        waiter_name: &str,
        wait: impl FnOnce(&(Mutex<()>, LockHolder)) -> R + Send + 'static,
    ) -> R {
        set_holder_tracking(true);
        let mutex = Arc::new((Mutex::new(()), LockHolder::default()));
        let (held_tx, held_rx) = channel();
        let holder = {
            let mutex = Arc::clone(&mutex);
            std::thread::Builder::new()
                .name(holder_name.into())
                .spawn(move || {
                    let (lock, holder) = &*mutex;
                    let _guard = holder.lock_mutex("test.holder", here(), lock).expect("lock");
                    held_tx.send(()).expect("held");
                    while holder.waiting() == 0 {
                        std::thread::yield_now();
                    }
                    std::thread::sleep(HOLD);
                })
                .expect("spawn holder")
        };
        held_rx.recv().expect("holder took the lock");
        let result = std::thread::Builder::new()
            .name(waiter_name.into())
            .spawn(move || wait(&mutex))
            .expect("spawn waiter")
            .join()
            .expect("waiter");
        holder.join().expect("holder");
        result
    }

    /// A timed wait at the budget on a disallowed thread is one `lock-wait`
    /// site, even in panic mode; a shorter wait, or the same wait on a
    /// thread that may block, records nothing.
    #[test]
    fn a_timed_wait_past_the_budget_records_only_on_a_disallowed_thread() {
        let (long, short) = std::thread::Builder::new()
            .name("timed-lock-wait".into())
            .spawn(|| {
                let allowed = here();
                note_timed_lock_wait(LOCK_WAIT_BUDGET, allowed);
                disallow_blocking();
                crate::blocking::with_mode(BlockingMode::Panic, || {
                    let long = here();
                    note_timed_lock_wait(LOCK_WAIT_BUDGET, long);
                    let short = here();
                    note_timed_lock_wait(LOCK_WAIT_BUDGET - Duration::from_micros(1), short);
                    assert!(snapshot().site(allowed.file(), allowed.line()).is_none());
                    (long, short)
                })
            })
            .expect("spawn")
            .join()
            .expect("no panic");
        let sites = snapshot();
        let site = sites.site(long.file(), long.line()).expect("long wait site");
        assert!(site.kinds.contains(BlockingKind::LockWait));
        assert_eq!(site.count, 1);
        assert!(sites.site(short.file(), short.line()).is_none());
    }

    /// A contended wait adds to the waiter's own lock wait total, an
    /// uncontended acquisition adds nothing, and another thread's total
    /// does not move.
    #[test]
    fn a_contended_wait_adds_to_the_waiting_threads_total() {
        let before_here = thread_lock_wait_nanos();
        let (waited, uncontended) =
            contend("lock-wait-total-holder", "lock-wait-total-waiter", |(lock, holder)| {
                let start = thread_lock_wait_nanos();
                drop(holder.lock_mutex("test.total", here(), lock).expect("lock"));
                let after_wait = thread_lock_wait_nanos();
                drop(holder.lock_mutex("test.total", here(), lock).expect("lock"));
                (after_wait - start, thread_lock_wait_nanos() - after_wait)
            });
        assert!(waited >= u64::try_from(HOLD.as_nanos()).unwrap(), "{waited} ns");
        assert_eq!(uncontended, 0, "a try that succeeds is not a wait");
        assert_eq!(thread_lock_wait_nanos(), before_here, "the total is per thread");
        note_thread_lock_wait(Duration::from_micros(3));
        assert_eq!(thread_lock_wait_nanos() - before_here, 3_000);
    }

    #[test]
    fn a_long_wait_is_recorded_with_the_holder_name() {
        set_mode(BlockingMode::Record);
        let line = contend("lock-wait-holder", "lock-wait-waiter", |(lock, holder)| {
            let site = here();
            drop(holder.lock_mutex("test.long-wait", site, lock).expect("lock"));
            site.line()
        });
        let waits = lock_waits();
        let wait = waits.newest("test.long-wait").expect("the long wait is recorded");
        assert_eq!(wait.holder.as_deref(), Some("lock-wait-holder"));
        assert_eq!(wait.waiter, "lock-wait-waiter");
        assert!(wait.waited >= HOLD, "{wait:?}");
        assert_eq!((wait.file, wait.line), (file!(), line));
        assert!(waits.long_waits >= 1);
        assert!(
            snapshot().site(file!(), line).is_none(),
            "a thread that may block records no violation"
        );
    }

    #[test]
    fn a_contended_wait_on_a_disallowed_thread_is_a_lock_wait_violation() {
        set_mode(BlockingMode::Record);
        let line = contend("lock-wait-holder-2", "lock-wait-request", |(lock, holder)| {
            disallow_blocking();
            let site = here();
            drop(holder.lock_mutex("test.disallowed-wait", site, lock).expect("lock"));
            site.line()
        });
        let site = snapshot().site(file!(), line).copied().expect("violation recorded");
        assert_eq!(site.kinds.iter().collect::<Vec<_>>(), vec![BlockingKind::LockWait]);
        assert_eq!(site.count, 1);
        let waits = lock_waits();
        let wait = waits.newest("test.disallowed-wait").expect("recorded");
        assert_eq!(wait.holder.as_deref(), Some("lock-wait-holder-2"));
    }

    #[test]
    fn an_uncontended_acquisition_records_nothing_and_publishes_its_holder() {
        set_mode(BlockingMode::Record);
        set_holder_tracking(true);
        let lock = Mutex::new(());
        let holder = LockHolder::default();
        assert_eq!(holder.holder(), None, "no holder before the first acquisition");
        let (name, line) = std::thread::Builder::new()
            .name("lock-wait-uncontended".into())
            .spawn(move || {
                disallow_blocking();
                let site = here();
                drop(holder.lock_mutex("test.uncontended", site, &lock).expect("lock"));
                (holder.holder(), site.line())
            })
            .expect("spawn")
            .join()
            .expect("thread");
        assert_eq!(name.as_deref(), Some("lock-wait-uncontended"));
        assert!(lock_waits().newest("test.uncontended").is_none());
        assert_eq!(snapshot().site(file!(), line), None, "a won try is no wait");
    }

    #[test]
    fn a_wait_that_gives_up_is_still_recorded() {
        set_mode(BlockingMode::Record);
        let got = contend("lock-wait-holder-3", "lock-wait-deadline", |(_, holder)| {
            holder.acquire_until(
                "test.deadline",
                here(),
                || None::<()>,
                || {
                    std::thread::sleep(LOCK_WAIT_BUDGET * 2);
                    None
                },
            )
        });
        assert_eq!(got, None);
        let waits = lock_waits();
        let wait = waits.newest("test.deadline").expect("recorded");
        assert_eq!(wait.holder.as_deref(), Some("lock-wait-holder-3"));
    }

    /// A waiter whose try failed between a new holder's won try and its
    /// publish names that holder, not the thread that held the lock before.
    #[test]
    fn a_holder_that_publishes_after_the_failed_try_is_the_one_named() {
        set_mode(BlockingMode::Record);
        set_holder_tracking(true);
        let shared = Arc::new((Mutex::new(()), LockHolder::default()));
        let earlier = Arc::clone(&shared);
        std::thread::Builder::new()
            .name("lock-wait-earlier".into())
            .spawn(move || drop(earlier.1.lock_mutex("test.earlier", here(), &earlier.0)))
            .expect("spawn")
            .join()
            .expect("earlier");
        let (held_tx, held_rx) = channel();
        let late = {
            let shared = Arc::clone(&shared);
            std::thread::Builder::new()
                .name("lock-wait-late-publisher".into())
                .spawn(move || {
                    let (lock, holder) = &*shared;
                    // Won its try, not published yet: the record still names
                    // "lock-wait-earlier" when the waiter's try fails.
                    let guard = lock.lock().expect("lock");
                    held_tx.send(()).expect("held");
                    while holder.waiting() == 0 {
                        std::thread::yield_now();
                    }
                    holder.publish();
                    std::thread::sleep(HOLD);
                    drop(guard);
                })
                .expect("spawn late publisher")
        };
        held_rx.recv().expect("the late publisher took the lock");
        std::thread::Builder::new()
            .name("lock-wait-order-waiter".into())
            .spawn(move || drop(shared.1.lock_mutex("test.late-publish", here(), &shared.0)))
            .expect("spawn waiter")
            .join()
            .expect("waiter");
        late.join().expect("late publisher");
        let waits = lock_waits();
        let wait = waits.newest("test.late-publish").expect("recorded");
        assert_eq!(wait.holder.as_deref(), Some("lock-wait-late-publisher"));
    }

    #[test]
    fn poisoning_passes_through() {
        let lock = Arc::new(Mutex::new(1));
        let poisoner = Arc::clone(&lock);
        let _ = std::thread::spawn(move || {
            let _guard = poisoner.lock().expect("lock");
            panic!("poison the lock");
        })
        .join();
        let holder = LockHolder::default();
        let poisoned = holder.lock_mutex("test.poison", here(), &lock).expect_err("poisoned");
        assert_eq!(*poisoned.into_inner(), 1);
    }

    #[test]
    fn names_are_cut_at_a_character_boundary() {
        let long = format!("{}é", "a".repeat(NAME_CAPACITY - 1));
        assert_eq!(NameBytes::of(&long).to_text(), "a".repeat(NAME_CAPACITY - 1));
        assert_eq!(NameBytes::of("registry.connection").to_text(), "registry.connection");
        assert_eq!(NameBytes::of("").to_text(), "");
    }
}
