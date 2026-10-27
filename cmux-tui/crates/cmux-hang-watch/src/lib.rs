//! Release hang watch for cmux's Rust processes (plans/cmux-next/chrome-parity/p09-observability.md,
//! section 3E). This is Chrome's `base::HangWatcher` (base/threading/hang_watcher.h): a thread
//! registers once ([`register_thread`] returns a [`Guard`]), opens a nesting [`Scope`] around each
//! unit of work ([`watch`], Chrome's `WatchHangsInScope`), and one watcher thread per process reports
//! a scope still open past its deadline. [`invalidate_active`] is Chrome's
//! `InvalidateActiveExpectations()`, for a wait the thread is allowed to make.
//!
//! - **Slots.** A chunked table of 64-byte slots. A slot's deadline, budget and flags are one
//!   `AtomicU64` (Chrome's `HangWatchDeadline`), so opening a scope is one atomic swap and a fence,
//!   and closing one a compare-exchange (and a fence when an enclosing scope comes back): no lock,
//!   allocation or system call. Scopes close innermost first, as Chrome's `~WatchHangsInScope`
//!   DCHECKs; a scope that closes out of order clears the slot (a debug build panics), so a stale
//!   scope never comes back.
//! - **Watcher rule.** While scopes open, the watcher wakes once per minimum deadline
//!   ([`Config::min_deadline`]) and reports overdue scopes, so detection takes at most the scope's
//!   deadline plus the minimum deadline. After one full period in which no scope opened and none is
//!   left to watch (every open one is reported or invalidated), it parks with no timer: an idle process gets 0 hang-watch wakes. The first open after
//!   that unparks it. Chrome's watcher instead wakes every 10 s forever; cmux's idle target forbids
//!   that.
//! - **Drift.** A watcher that wakes more than [`Config::drift_tolerance`] late (the machine slept,
//!   or the watcher was starved) blames nobody: every deadline up to now is ignored from then on
//!   (Chrome's `kWaitDriftTolerance` and `deadline_ignore_threshold_`).
//! - **Running scopes.** A scope opened with [`Guard::watch_running`] (a tokio worker between its
//!   unpark and its park, `tokio.rs`) is one whose thread runs many short items the watch cannot
//!   see. Each pass reads that thread's CPU time ([`Clock::thread_cpu_ns`]); while it grows, the
//!   deadline moves to a full budget past the pass, so only a thread that got no CPU time since
//!   the watcher last looked (blocked in one call) is reported.
//! - **Report.** One [`Hang`] per overdue scope goes to the [`HangSink`]; the process sink
//!   ([`JsonlSink`]) appends one line to `hangs-<pid>.jsonl`. On macOS the record carries a stack
//!   of the hung thread (`sample_macos`: nothing between suspend and resume but register reads and
//!   a frame-pointer walk); Linux and Windows record the thread name and the deadline.
//!
//! The watcher parks with `std::thread::park`, the parker std builds on a futex (Linux), a
//! `ulock` (macOS) or a keyed event (Windows): the Condvar-style park of section 3E without a mutex.
//!
//! std and libc only: the holder links it. The optional `tokio` feature adds `tokio::instrument`
//! and `tokio::block_in_place` for the crates that run tokio runtimes.

use std::cell::Cell;
use std::io;
use std::marker::PhantomData;
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU8, AtomicU64, AtomicUsize, Ordering, fence};
use std::sync::{Arc, OnceLock};
use std::thread::{self, JoinHandle, Thread};
use std::time::Duration;

#[cfg(any(target_os = "macos", test))]
mod frame_walk;
mod platform;
mod record;
#[cfg(target_os = "macos")]
pub mod sample_macos;
mod slot;
mod stack;
pub mod tokio;

use platform::{native_thread_id, run_at_utility_qos, thread_cpu_ns};
pub(crate) use record::push_json_string;
pub use record::{Hang, HangSink, JsonlSink, file_name};
use slot::{FLAGS, IGNORED, REPORTED, RUNNING, Slot, armed, budget_of, deadline_of, duration_ns};
pub use stack::{Stack, StackFrame, StackImage};

/// A scope's deadline when the caller has no better one (Chrome's `kDefaultHangWatchTime`).
pub const DEFAULT_DEADLINE: Duration = Duration::from_secs(10);
/// Slots in one chunk of the slot table (one allocation: 4 KiB of slots and the watcher's notes).
pub const SLOTS_PER_CHUNK: usize = 64;
/// Chunks the slot table can grow to.
pub const MAX_CHUNKS: usize = 64;
/// Threads one process can register at once; a registration past this is inert and counted in
/// [`Stats::overflow`].
pub const MAX_SLOTS: usize = SLOTS_PER_CHUNK * MAX_CHUNKS;
/// The watcher thread's name (plans/cmux-next/threading-model.md, "Hang watch" and the Rust thread
/// names of p09-observability). It runs at utility QoS on macOS.
pub const THREAD_NAME: &str = "mux-hang-watch";
/// Bytes of a thread name a slot keeps (a longer name is cut at a character boundary).
pub const NAME_BYTES: usize = 40;

/// What a registered thread runs. The raw values are shared with the Swift `HangWatch.ThreadKind`.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ThreadKind {
    /// A process's main thread.
    Main = 1,
    /// A socket or PTY reader or writer (bounded I/O only; the wait itself stays outside the scope).
    Io = 2,
    /// A serial work lane.
    Lane = 3,
    /// A renderer thread.
    Renderer = 4,
    /// A thread-pool worker (a tokio worker, a `spawn_blocking` thread).
    Pool = 5,
    /// A control-socket handler (mux-control-dispatch).
    Control = 6,
}

impl ThreadKind {
    pub const ALL: [ThreadKind; 6] = [
        ThreadKind::Main,
        ThreadKind::Io,
        ThreadKind::Lane,
        ThreadKind::Renderer,
        ThreadKind::Pool,
        ThreadKind::Control,
    ];

    pub fn from_raw(raw: u8) -> Option<ThreadKind> {
        ThreadKind::ALL.into_iter().find(|kind| *kind as u8 == raw)
    }

    /// The kind's name in a hang record.
    pub fn as_str(self) -> &'static str {
        match self {
            ThreadKind::Main => "main",
            ThreadKind::Io => "io",
            ThreadKind::Lane => "lane",
            ThreadKind::Renderer => "renderer",
            ThreadKind::Pool => "pool",
            ThreadKind::Control => "control",
        }
    }
}

/// The clock deadlines are measured on. It must not count system sleep, so a sleep never looks
/// like a hang (the drift rule covers the wake-up).
pub trait Clock: Send + Sync {
    /// Now, in ns, monotonic.
    fn now_ns(&self) -> u64;

    /// The CPU time the thread `native_thread_id` (a [`Hang::native_thread_id`] of this process)
    /// has run, in ns; None where the platform has no per-thread CPU clock or the read failed.
    fn thread_cpu_ns(&self, native_thread_id: u64) -> Option<u64> {
        thread_cpu_ns(native_thread_id)
    }
}

/// The trace clock ([`cmux_trace::clock::now_ns`]): `CLOCK_UPTIME_RAW` on macOS, `CLOCK_MONOTONIC`
/// on Linux, QPC on Windows. A hang's `t_ns` joins the process's trace ring on it.
#[derive(Clone, Copy, Debug, Default)]
pub struct TraceClock;

impl Clock for TraceClock {
    #[inline]
    fn now_ns(&self) -> u64 {
        cmux_trace::clock::now_ns()
    }
}

/// The watcher's timing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Config {
    /// The watcher's period while scopes open: detection takes at most a scope's deadline plus this,
    /// and an active process gets one wake per period.
    pub min_deadline: Duration,
    /// How late the watcher may wake before it blames nobody (Chrome's `kWaitDriftTolerance`).
    pub drift_tolerance: Duration,
}

impl Default for Config {
    fn default() -> Config {
        Config { min_deadline: Duration::from_secs(1), drift_tolerance: Duration::from_millis(100) }
    }
}

/// What one watcher pass saw ([`HangWatch::check`]).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Pass {
    /// Slots with a scope open at the pass.
    pub open: u32,
    /// Open scopes the watcher still has to watch: not reported, not invalidated and not ignored
    /// by a late pass. The watcher parks only when this is 0.
    pub armed: u32,
    /// Hangs it reported.
    pub hangs: u32,
    /// It ran past the drift tolerance, so it blamed nobody.
    pub late: bool,
}

/// Counters of one watch.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Times the watcher thread woke (a timer, an unpark or a spurious return).
    pub wakes: u64,
    pub passes: u64,
    pub hangs: u64,
    /// Passes that were late and blamed nobody.
    pub late_passes: u64,
    /// Threads registered now.
    pub registered: u64,
    /// Registrations refused because the table was full.
    pub overflow: u64,
    /// Hangs the sink failed to record.
    pub sink_errors: u64,
    /// Hangs whose stack sample failed (macOS; the record goes out without a stack).
    pub sample_errors: u64,
    /// `runtime.busy_ms`: time the watched tokio workers ran between an unpark and the next park,
    /// summed over every instrumented runtime ([`tokio::WorkerHooks`]). The daemons' stats
    /// (`server-stats` `runtime`, acpmux `daemon status`) report it.
    pub runtime_busy_ms: u64,
    /// The busy periods summed in `runtime_busy_ms`.
    pub runtime_busy_periods: u64,
    /// The watcher is parked with no timer.
    pub parked: bool,
}

// The watcher's word: an opener moves QUIET or PARKED to SEEN, and unparks the watcher when it was
// PARKED; each pass moves SEEN back to QUIET; a quiet pass with no open scope moves QUIET to PARKED.
const QUIET: u8 = 0;
const SEEN: u8 = 1;
const PARKED: u8 = 2;

/// The watcher's note on a slot's running scope ([`Guard::watch_running`]). Only passes touch it.
struct RunMark {
    /// The running word it last saw on the slot, without flags.
    word: AtomicU64,
    /// The thread's CPU time at that pass.
    cpu_ns: AtomicU64,
    /// The scope's deadline (ms since the epoch), a budget past the last pass that saw CPU time.
    deadline_ms: AtomicU64,
}

impl RunMark {
    const fn new() -> RunMark {
        RunMark {
            word: AtomicU64::new(0),
            cpu_ns: AtomicU64::new(0),
            deadline_ms: AtomicU64::new(0),
        }
    }
}

struct Chunk {
    slots: [Slot; SLOTS_PER_CHUNK],
    marks: [RunMark; SLOTS_PER_CHUNK],
}

struct Shared {
    config: Config,
    clock: Arc<dyn Clock>,
    sink: Box<dyn HangSink>,
    epoch_ns: u64,
    chunks: [AtomicPtr<Chunk>; MAX_CHUNKS],
    chunk_count: AtomicUsize,
    watcher: AtomicU8,
    stop: AtomicBool,
    thread: OnceLock<Thread>,
    /// Deadlines at or before this (ms since the epoch) are never blamed: a late pass moves it to
    /// its now.
    ignore_through_ms: AtomicU64,
    wakes: AtomicU64,
    passes: AtomicU64,
    hangs: AtomicU64,
    late_passes: AtomicU64,
    registered: AtomicU64,
    overflow: AtomicU64,
    sink_errors: AtomicU64,
    sample_errors: AtomicU64,
    runtime_busy_ns: AtomicU64,
    runtime_busy_periods: AtomicU64,
}

impl Shared {
    #[inline]
    fn now_ms(&self) -> u64 {
        self.ms_since_epoch(self.clock.now_ns())
    }

    fn ms_since_epoch(&self, now_ns: u64) -> u64 {
        now_ns.saturating_sub(self.epoch_ns) / 1_000_000
    }

    /// After an open's store: the fence pairs with [`Shared::try_park`]'s, so either this open sees
    /// the watcher parked and unparks it, or the watcher's re-scan sees this scope open.
    #[inline]
    fn note_open(&self) {
        fence(Ordering::SeqCst);
        if self.watcher.load(Ordering::Relaxed) != SEEN {
            self.mark_seen();
        }
    }

    #[cold]
    fn mark_seen(&self) {
        if self.watcher.swap(SEEN, Ordering::SeqCst) == PARKED
            && let Some(thread) = self.thread.get()
        {
            thread.unpark();
        }
    }

    /// The word a scope that closes from `closing` puts back, `previous` being its enclosing word.
    /// The ignore stays until the outermost scope closes (Chrome keeps
    /// `kIgnoreCurrentWatchHangsInScope` through `SetDeadline(previous_deadline_)`, hang_watcher.cc).
    /// A reported scope that closes into an overdue `previous` is the same hang, so `previous`
    /// keeps the report instead of making a second record.
    #[inline]
    fn restored(&self, closing: u64, previous: u64) -> u64 {
        if previous == 0 {
            return 0;
        }
        let mut restored = previous | (closing & IGNORED);
        if closing & REPORTED != 0 && deadline_of(previous) <= self.now_ms() {
            restored |= REPORTED;
        }
        restored
    }

    fn chunk(&self, index: usize) -> Option<&Chunk> {
        // SAFETY: a non-null chunk pointer came from `Box::into_raw` in `claim` and is freed only
        // in `Drop for Shared`, which no `&self` outlives.
        unsafe { self.chunks[index].load(Ordering::Acquire).as_ref() }
    }

    fn slots(&self) -> impl Iterator<Item = (u32, &Slot, &RunMark)> {
        let count = self.chunk_count.load(Ordering::Acquire).min(MAX_CHUNKS);
        (0..count).filter_map(|index| self.chunk(index).map(|chunk| (index, chunk))).flat_map(
            |(index, chunk)| {
                chunk.slots.iter().zip(&chunk.marks).enumerate().map(
                    move |(offset, (slot, mark))| {
                        ((index * SLOTS_PER_CHUNK + offset) as u32, slot, mark)
                    },
                )
            },
        )
    }

    /// A free slot, growing the table by one chunk when every slot is taken.
    fn claim(&self) -> Option<&Slot> {
        for index in 0..MAX_CHUNKS {
            let chunk = match self.chunk(index) {
                Some(chunk) => chunk,
                None => self.grow(index),
            };
            let free = chunk.slots.iter().find(|slot| {
                !slot.in_use.load(Ordering::Relaxed)
                    && slot
                        .in_use
                        .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
                        .is_ok()
            });
            if free.is_some() {
                return free;
            }
        }
        None
    }

    #[cold]
    fn grow(&self, index: usize) -> &Chunk {
        let fresh = Box::into_raw(Box::new(Chunk {
            slots: [const { Slot::new() }; SLOTS_PER_CHUNK],
            marks: [const { RunMark::new() }; SLOTS_PER_CHUNK],
        }));
        let installed = match self.chunks[index].compare_exchange(
            ptr::null_mut(),
            fresh,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => fresh,
            Err(existing) => {
                // SAFETY: `fresh` came from `Box::into_raw` above and was never shared.
                drop(unsafe { Box::from_raw(fresh) });
                existing
            }
        };
        self.chunk_count.fetch_max(index + 1, Ordering::AcqRel);
        // SAFETY: `installed` is a live chunk, freed only in `Drop for Shared`.
        unsafe { &*installed }
    }

    /// One watcher pass at the watch clock's now, for a pass the watcher scheduled at `scheduled_ns`.
    fn check(&self, scheduled_ns: u64) -> Pass {
        let now_ns = self.clock.now_ns();
        let now_ms = self.ms_since_epoch(now_ns);
        let late = now_ns.saturating_sub(scheduled_ns) > duration_ns(self.config.drift_tolerance);
        if late {
            self.ignore_through_ms.fetch_max(now_ms, Ordering::Relaxed);
            self.late_passes.fetch_add(1, Ordering::Relaxed);
        }
        let ignore_through = self.ignore_through_ms.load(Ordering::Relaxed);
        let mut pass = Pass { late, ..Pass::default() };
        for (index, slot, mark) in self.slots() {
            let state = slot.state.load(Ordering::Acquire);
            if state == 0 {
                continue;
            }
            pass.open += 1;
            if !armed(state, ignore_through) {
                continue;
            }
            let deadline_ms = if state & RUNNING == 0 {
                deadline_of(state)
            } else {
                self.running_deadline(slot, mark, state, now_ms)
            };
            if deadline_ms > now_ms {
                pass.armed += 1;
                continue;
            }
            let reported =
                self.read_hang(index, slot, state, deadline_ms, now_ns, now_ms).filter(|_| {
                    slot.state
                        .compare_exchange(
                            state,
                            state | REPORTED,
                            Ordering::AcqRel,
                            Ordering::Relaxed,
                        )
                        .is_ok()
                });
            let Some((mut hang, generation)) = reported else {
                // The scope closed, nested or changed owner meanwhile; the next pass sees it.
                pass.armed += 1;
                continue;
            };
            pass.hangs += 1;
            self.hangs.fetch_add(1, Ordering::Relaxed);
            hang.stack = self.sample(slot, &hang, generation);
            if self.sink.record(&hang).is_err() {
                self.sink_errors.fetch_add(1, Ordering::Relaxed);
            }
        }
        self.passes.fetch_add(1, Ordering::Relaxed);
        pass
    }

    /// A running scope's deadline: its own until a pass sees its thread's CPU time grow, then a
    /// full budget past the last pass that saw it grow. A thread with no CPU clock always runs.
    fn running_deadline(&self, slot: &Slot, mark: &RunMark, state: u64, now_ms: u64) -> u64 {
        let word = state & !FLAGS;
        let cpu_ns = self.clock.thread_cpu_ns(slot.native.load(Ordering::Relaxed));
        if mark.word.swap(word, Ordering::Relaxed) != word {
            mark.cpu_ns.store(cpu_ns.unwrap_or(0), Ordering::Relaxed);
            mark.deadline_ms.store(deadline_of(state), Ordering::Relaxed);
        } else if cpu_ns.is_none_or(|cpu_ns| mark.cpu_ns.swap(cpu_ns, Ordering::Relaxed) != cpu_ns)
        {
            mark.deadline_ms.store(now_ms.saturating_add(budget_of(state)), Ordering::Relaxed);
        }
        mark.deadline_ms.load(Ordering::Relaxed)
    }

    /// The hung thread's stack, while its slot still belongs to it (same generation).
    #[cfg(target_os = "macos")]
    fn sample(&self, slot: &Slot, hang: &Hang, generation: u32) -> Option<Stack> {
        let port = u32::try_from(hang.native_thread_id).ok()?;
        let still_registered = || slot.generation.load(Ordering::Acquire) == generation;
        match sample_macos::sample_checked(port, still_registered) {
            Ok(stack) => Some(stack),
            Err(_) => {
                self.sample_errors.fetch_add(1, Ordering::Relaxed);
                None
            }
        }
    }

    #[cfg(not(target_os = "macos"))]
    fn sample(&self, _slot: &Slot, _hang: &Hang, _generation: u32) -> Option<Stack> {
        None
    }

    /// The slot's record and generation, or None when it was unregistered or reused while the
    /// watcher read it.
    fn read_hang(
        &self,
        index: u32,
        slot: &Slot,
        state: u64,
        deadline_ms: u64,
        now_ns: u64,
        now_ms: u64,
    ) -> Option<(Hang, u32)> {
        let generation = slot.generation.load(Ordering::Acquire);
        let kind = ThreadKind::from_raw(slot.kind.load(Ordering::Relaxed));
        let native_thread_id = slot.native.load(Ordering::Relaxed);
        let thread = slot.read_name();
        fence(Ordering::Acquire);
        if slot.generation.load(Ordering::Relaxed) != generation {
            return None;
        }
        let hang = Hang {
            pid: std::process::id(),
            t_ns: now_ns,
            thread,
            kind: kind?,
            native_thread_id,
            slot: index,
            deadline_ms: budget_of(state),
            overdue_ms: now_ms - deadline_ms,
            stack: None,
        };
        Some((hang, generation))
    }

    fn any_armed(&self) -> bool {
        let ignore_through = self.ignore_through_ms.load(Ordering::Relaxed);
        self.slots().any(|(_, slot, _)| armed(slot.state.load(Ordering::Relaxed), ignore_through))
    }

    /// Parks when nothing opened during the last period. False when a scope opened meanwhile.
    fn try_park(&self) -> bool {
        if self
            .watcher
            .compare_exchange(QUIET, PARKED, Ordering::SeqCst, Ordering::Relaxed)
            .is_err()
        {
            return false;
        }
        fence(Ordering::SeqCst);
        if self.any_armed() {
            // An open raced the park. If its opener already moved the word to SEEN, its unpark
            // token makes the next timed wait return early once; nothing else changes.
            let _ =
                self.watcher.compare_exchange(PARKED, SEEN, Ordering::SeqCst, Ordering::Relaxed);
            return false;
        }
        true
    }

    /// Waits with no timer while parked. False when the watch stops.
    fn park(&self) -> bool {
        loop {
            if self.stop.load(Ordering::Acquire) {
                return false;
            }
            if self.watcher.load(Ordering::SeqCst) != PARKED {
                return true;
            }
            thread::park();
            self.wakes.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn run(&self) {
        run_at_utility_qos();
        let period = self.config.min_deadline.max(Duration::from_millis(1));
        let period_ns = duration_ns(period);
        while self.park() {
            loop {
                let scheduled_ns = self.clock.now_ns().saturating_add(period_ns);
                thread::park_timeout(period);
                if self.stop.load(Ordering::Acquire) {
                    return;
                }
                self.wakes.fetch_add(1, Ordering::Relaxed);
                let pass = self.check(scheduled_ns);
                let opened = self.watcher.swap(QUIET, Ordering::SeqCst) == SEEN;
                if pass.armed == 0 && !opened && self.try_park() {
                    break;
                }
            }
        }
    }

    fn stats(&self) -> Stats {
        Stats {
            wakes: self.wakes.load(Ordering::Relaxed),
            passes: self.passes.load(Ordering::Relaxed),
            hangs: self.hangs.load(Ordering::Relaxed),
            late_passes: self.late_passes.load(Ordering::Relaxed),
            registered: self.registered.load(Ordering::Relaxed),
            overflow: self.overflow.load(Ordering::Relaxed),
            sink_errors: self.sink_errors.load(Ordering::Relaxed),
            sample_errors: self.sample_errors.load(Ordering::Relaxed),
            runtime_busy_ms: self.runtime_busy_ns.load(Ordering::Relaxed) / 1_000_000,
            runtime_busy_periods: self.runtime_busy_periods.load(Ordering::Relaxed),
            parked: self.watcher.load(Ordering::Relaxed) == PARKED,
        }
    }
}

impl Drop for Shared {
    fn drop(&mut self) {
        for chunk in &mut self.chunks {
            let pointer = *chunk.get_mut();
            if !pointer.is_null() {
                // SAFETY: the pointer came from `Box::into_raw` in `grow`; this is its only free.
                drop(unsafe { Box::from_raw(pointer) });
            }
        }
    }
}

/// A slot table and its watcher. A process uses the one [`init`] makes; tests and tools make their
/// own with an injected [`Clock`] and [`HangSink`].
pub struct HangWatch {
    shared: Arc<Shared>,
    watcher: Option<JoinHandle<()>>,
}

impl HangWatch {
    /// A watch with no watcher thread: [`HangWatch::check`] runs its passes.
    pub fn new(config: Config, clock: Arc<dyn Clock>, sink: Box<dyn HangSink>) -> HangWatch {
        let epoch_ns = clock.now_ns();
        HangWatch {
            shared: Arc::new(Shared {
                config,
                clock,
                sink,
                epoch_ns,
                chunks: [const { AtomicPtr::new(ptr::null_mut()) }; MAX_CHUNKS],
                chunk_count: AtomicUsize::new(0),
                watcher: AtomicU8::new(PARKED),
                stop: AtomicBool::new(false),
                thread: OnceLock::new(),
                ignore_through_ms: AtomicU64::new(0),
                wakes: AtomicU64::new(0),
                passes: AtomicU64::new(0),
                hangs: AtomicU64::new(0),
                late_passes: AtomicU64::new(0),
                registered: AtomicU64::new(0),
                overflow: AtomicU64::new(0),
                sink_errors: AtomicU64::new(0),
                sample_errors: AtomicU64::new(0),
                runtime_busy_ns: AtomicU64::new(0),
                runtime_busy_periods: AtomicU64::new(0),
            }),
            watcher: None,
        }
    }

    /// A watch with its watcher thread ([`THREAD_NAME`]), parked until the first scope opens.
    pub fn spawn(
        config: Config,
        clock: Arc<dyn Clock>,
        sink: Box<dyn HangSink>,
    ) -> io::Result<HangWatch> {
        let mut watch = HangWatch::new(config, clock, sink);
        // The image table fills now, so a hang's stack maps without a call into dyld.
        #[cfg(target_os = "macos")]
        sample_macos::install_image_table();
        let shared = Arc::clone(&watch.shared);
        let handle = thread::Builder::new().name(THREAD_NAME.into()).spawn(move || shared.run())?;
        let _ = watch.shared.thread.set(handle.thread().clone());
        watch.watcher = Some(handle);
        Ok(watch)
    }

    /// Registers the calling thread under `name`. The slot is freed when the guard drops.
    pub fn register_thread(&self, kind: ThreadKind, name: &str) -> Guard<'_> {
        self.register(kind, name, false)
    }

    fn register(&self, kind: ThreadKind, name: &str, process: bool) -> Guard<'_> {
        // One process registration per thread (Chrome's `HangWatcher::RegisterThread` DCHECKs it):
        // a second one would leave CURRENT on a slot that frees while the thread still uses it.
        let registered_already =
            process && CURRENT.try_with(|cell| !cell.get().is_null()).unwrap_or(false);
        debug_assert!(!registered_already, "a thread registers with the process hang watch once");
        if registered_already {
            return Guard::inert();
        }
        let shared: &Shared = &self.shared;
        let Some(slot) = shared.claim() else {
            shared.overflow.fetch_add(1, Ordering::Relaxed);
            return Guard::inert();
        };
        slot.kind.store(kind as u8, Ordering::Relaxed);
        slot.native.store(native_thread_id(), Ordering::Relaxed);
        slot.set_name(name);
        let generation = slot.generation.fetch_add(1, Ordering::Release).wrapping_add(1);
        shared.registered.fetch_add(1, Ordering::Relaxed);
        if process {
            let _ = CURRENT.try_with(|cell| cell.set(slot));
        }
        Guard {
            registered: Some(Registered { shared, slot, generation, process }),
            _thread_bound: PhantomData,
        }
    }

    /// One watcher pass now, for a pass scheduled at `scheduled_ns` on the watch's clock: it reports
    /// each overdue scope once, or blames nobody when it runs past the drift tolerance. The watcher
    /// thread runs it once per period; a watch made with [`HangWatch::new`] is driven by calling it.
    pub fn check(&self, scheduled_ns: u64) -> Pass {
        self.shared.check(scheduled_ns)
    }

    pub fn stats(&self) -> Stats {
        self.shared.stats()
    }
}

impl Drop for HangWatch {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        if let Some(handle) = self.watcher.take() {
            handle.thread().unpark();
            let _ = handle.join();
        }
    }
}

struct Registered<'a> {
    shared: &'a Shared,
    slot: &'a Slot,
    generation: u32,
    /// This guard is the thread's process registration, the slot CURRENT points to.
    process: bool,
}

/// A thread's registration. It belongs to the thread that registered (not `Send`) and frees the
/// slot when it drops. An inert guard (no watch, or a full table) watches nothing.
#[must_use = "the thread is unregistered when the guard drops"]
pub struct Guard<'a> {
    registered: Option<Registered<'a>>,
    _thread_bound: PhantomData<*const ()>,
}

impl<'a> Guard<'a> {
    fn inert() -> Guard<'a> {
        Guard { registered: None, _thread_bound: PhantomData }
    }

    pub fn is_registered(&self) -> bool {
        self.registered.is_some()
    }

    /// Opens a scope on this thread's slot: it hangs if still open after `deadline`.
    #[inline]
    pub fn watch(&self, deadline: Duration) -> Scope<'a> {
        self.open(deadline, 0)
    }

    /// Opens a scope over many short items the watch cannot see one by one (a tokio worker between
    /// its unpark and its park): it hangs only when the thread got no CPU time for `deadline`
    /// since the watcher last looked, so a busy thread is not blamed and a blocked one is.
    #[inline]
    pub fn watch_running(&self, deadline: Duration) -> Scope<'a> {
        self.open(deadline, RUNNING)
    }

    #[inline]
    fn open(&self, deadline: Duration, running: u64) -> Scope<'a> {
        match &self.registered {
            Some(registered) => Scope::open(registered.shared, registered.slot, deadline, running),
            None => Scope::inert(),
        }
    }

    /// Stops blaming the open scopes of this thread, through the outermost one's close
    /// ([`invalidate_active`]).
    pub fn invalidate_active(&self) {
        if let Some(registered) = &self.registered {
            registered.slot.invalidate();
        }
    }

    /// Now on the watch's clock; None on an inert guard.
    pub(crate) fn now_ns(&self) -> Option<u64> {
        self.registered.as_ref().map(|registered| registered.shared.clock.now_ns())
    }

    /// Adds one busy period of `ns` to the watch's [`Stats::runtime_busy_ms`].
    pub(crate) fn add_runtime_busy(&self, ns: u64) {
        if let Some(registered) = &self.registered {
            registered.shared.runtime_busy_ns.fetch_add(ns, Ordering::Relaxed);
            registered.shared.runtime_busy_periods.fetch_add(1, Ordering::Relaxed);
        }
    }
}

impl Drop for Guard<'_> {
    fn drop(&mut self) {
        let Some(registered) = self.registered.take() else { return };
        let slot = registered.slot;
        if registered.process {
            let _ = CURRENT.try_with(|cell| {
                if ptr::eq(cell.get(), slot) {
                    cell.set(ptr::null());
                }
            });
        }
        slot.state.store(0, Ordering::Release);
        slot.generation.fetch_add(1, Ordering::Release);
        slot.in_use.store(false, Ordering::Release);
        registered.shared.registered.fetch_sub(1, Ordering::Relaxed);
        debug_assert_ne!(registered.generation, slot.generation.load(Ordering::Relaxed));
    }
}

struct Open<'a> {
    shared: &'a Shared,
    slot: &'a Slot,
    generation: u32,
    /// The word this scope wrote, with no flags.
    opened: u64,
    previous: u64,
}

/// One open scope (Chrome's `WatchHangsInScope`). Scopes nest: the innermost deadline applies
/// until it closes, then the enclosing one is back. It closes when it drops, on the thread that
/// opened it (not `Send`).
#[must_use = "a scope stops watching when it drops"]
pub struct Scope<'a> {
    open: Option<Open<'a>>,
    _thread_bound: PhantomData<*const ()>,
}

impl<'a> Scope<'a> {
    #[inline]
    fn open(shared: &'a Shared, slot: &'a Slot, deadline: Duration, running: u64) -> Scope<'a> {
        let generation = slot.generation.load(Ordering::Relaxed);
        let (opened, previous) = slot.open(shared, deadline, running);
        Scope {
            open: Some(Open { shared, slot, generation, opened, previous }),
            _thread_bound: PhantomData,
        }
    }

    fn inert() -> Scope<'a> {
        Scope { open: None, _thread_bound: PhantomData }
    }

    /// Whether this scope watches a registered slot.
    pub fn is_watching(&self) -> bool {
        self.open.is_some()
    }

    /// Closes the scope now. Scopes close innermost first: one that closes while a scope it
    /// encloses is open clears the thread's slot (a debug build panics).
    pub fn close(self) {}
}

impl Drop for Scope<'_> {
    #[inline]
    fn drop(&mut self) {
        if let Some(open) = self.open.take() {
            open.slot.close(open.shared, open.generation, open.opened, open.previous);
        }
    }
}

/// The process's watch: the one process-wide hang-watch state, part of arch-ratchet's reviewed
/// `TraceRuntime` exception (like Chrome's one `HangWatcher` per process). It is never dropped, so
/// its slots live as long as the process.
static PROCESS: OnceLock<HangWatch> = OnceLock::new();

thread_local! {
    /// The calling thread's slot in [`PROCESS`], set by [`register_thread`].
    static CURRENT: Cell<*const Slot> = const { Cell::new(ptr::null()) };
}

/// Why [`init`] did not start a watch.
#[derive(Debug)]
pub enum InitError {
    /// This process already has its watch.
    AlreadyStarted,
    /// The watcher thread did not start.
    Spawn(io::Error),
}

impl std::fmt::Display for InitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InitError::AlreadyStarted => f.write_str("the hang watch already runs in this process"),
            InitError::Spawn(error) => write!(f, "the hang-watch thread did not start: {error}"),
        }
    }
}

impl std::error::Error for InitError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            InitError::AlreadyStarted => None,
            InitError::Spawn(error) => Some(error),
        }
    }
}

/// Starts this process's watch: hangs go to `<dir>/hangs-<pid>.jsonl`, on the trace clock, with the
/// default [`Config`]. Call it early in `main`; a thread that registers before it is not watched.
pub fn init(dir: impl AsRef<Path>) -> Result<(), InitError> {
    init_process(Config::default(), Arc::new(TraceClock), Box::new(JsonlSink::in_dir(dir)))
}

/// [`init`] with every input given.
pub fn init_process(
    config: Config,
    clock: Arc<dyn Clock>,
    sink: Box<dyn HangSink>,
) -> Result<(), InitError> {
    if PROCESS.get().is_some() {
        return Err(InitError::AlreadyStarted);
    }
    let watch = HangWatch::spawn(config, clock, sink).map_err(InitError::Spawn)?;
    // A racing init that lost drops its watch here, which stops its thread.
    PROCESS.set(watch).map_err(|_| InitError::AlreadyStarted)
}

/// Registers the calling thread with the process's watch; [`watch`] and [`invalidate_active`] then
/// use its slot. Before [`init`], the guard is inert.
pub fn register_thread(kind: ThreadKind, name: &str) -> Guard<'static> {
    match PROCESS.get() {
        Some(watch) => watch.register(kind, name, true),
        None => Guard::inert(),
    }
}

/// Opens a scope on the calling thread's process slot: it hangs if still open after `deadline`. On
/// a thread that did not [`register_thread`], the scope is inert. No lock, allocation or system call.
#[inline]
pub fn watch(deadline: Duration) -> Scope<'static> {
    let Some(process) = PROCESS.get() else { return Scope::inert() };
    let slot = CURRENT.try_with(Cell::get).unwrap_or(ptr::null());
    // SAFETY: CURRENT holds only slots of PROCESS (set by `register_thread`), whose chunks are
    // freed only when PROCESS drops, which a static never does.
    match unsafe { slot.as_ref() } {
        Some(slot) => Scope::open(&process.shared, slot, deadline, 0),
        None => Scope::inert(),
    }
}

/// Stops blaming the calling thread's open scopes, before a wait it is allowed to make (a network or
/// process wait): the innermost and every scope enclosing it, until the outermost one closes. A
/// scope that opens after this watches again.
pub fn invalidate_active() {
    let slot = CURRENT.try_with(Cell::get).unwrap_or(ptr::null());
    // SAFETY: as in `watch`.
    if let Some(slot) = unsafe { slot.as_ref() } {
        slot.invalidate();
    }
}

/// The process watch's counters; None before [`init`].
pub fn stats() -> Option<Stats> {
    PROCESS.get().map(HangWatch::stats)
}

#[cfg(test)]
#[path = "lib_tests.rs"]
mod tests;
