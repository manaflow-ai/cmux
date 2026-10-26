//! The hang log of cmux's background processes: a watched scope that runs
//! past its hang deadline is written once as one JSON line, with the stack
//! of the thread that runs it, next to the panic log.
//!
//! Chrome's HangWatcher (base/threading/hang_watcher.cc,
//! `HangWatchScopeEnabled`, `HangWatchState`, `HangWatchDeadline`): a watched
//! scope stores its deadline in atomics the watched thread owns, and one
//! watcher thread compares them with the clock; the watched thread takes no
//! lock and makes no system call for it. Chrome then hands the hung thread
//! to base/profiler's stack sampler; here the [`StackSampler`] seam does
//! (cmux-tui-platform `thread_backtrace`: `thread_suspend` and a
//! frame-pointer walk on macOS, `pthread_kill` to a handler that fills a
//! preallocated buffer on Linux).
//!
//! Unlike Chrome's fixed monitoring period, this watcher has no periodic
//! timer. It sleeps until the earliest deadline of an open scope (the
//! `target`), and with no scope open it parks with no timeout: an idle
//! process has 0 watcher wakeups. A scope that opens with a deadline before
//! the target lowers it and wakes the watcher; any other scope touches only
//! its own slot and one load of the target.
//!
//! Each [`HangKind`] has two tiers: past `jank` a scope is counted
//! ([`HangStats::janks`]); past `hang` it is written to the log with its
//! method and its thread's stack, once. A scope that ends past a tier the
//! watcher had not reached yet (the watcher was late) is counted as missed.
//!
//! The process's watcher is installed like the panic hook ([`install`]);
//! [`watch_scope`] is inert until then, as Chrome's scopes are without a
//! `HangWatcher` instance.

use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering, fence};
use std::sync::{Arc, OnceLock};
use std::thread::Thread;
use std::time::{Duration, Instant};

/// Scopes open at once, process-wide: a request and a dispatched command for
/// every daemon connection, the journal writer, the holder links. A scope
/// that finds every slot taken goes unwatched and is counted.
pub const SLOT_COUNT: usize = 256;

/// The watcher thread's name.
pub const THREAD_NAME: &str = "hang-watcher";

/// Kinds of scope a process may watch; a scope of a kind past them goes
/// unwatched and is counted.
pub const MAX_KINDS: usize = 32;

/// One kind of watched scope, a `static` of its owner: its name in the log,
/// its tiers and how its methods are named.
pub struct HangKind {
    /// The scope's name in each record (`"mux-conn"`).
    pub name: &'static str,
    /// Past this a scope is counted as jank; `None`: no jank tier.
    pub jank: Option<Duration>,
    /// Past this a scope is written to the log with its stack.
    pub hang: Duration,
    /// The name of a scope's `method`, read only when a record is written.
    pub method_name: fn(u32) -> &'static str,
    /// Its row in [`KINDS`] plus one, 0 until its first scope; a slot
    /// stores the row, so the watcher reads the kind with no pointer.
    row: AtomicU32,
}

/// Every kind a scope opened with, in first-use order.
static KINDS: [OnceLock<&'static HangKind>; MAX_KINDS] = [const { OnceLock::new() }; MAX_KINDS];

impl HangKind {
    pub const fn new(
        name: &'static str,
        jank: Option<Duration>,
        hang: Duration,
        method_name: fn(u32) -> &'static str,
    ) -> Self {
        Self { name, jank, hang, method_name, row: AtomicU32::new(0) }
    }

    /// This kind's row in [`KINDS`] plus one, taking a row on first use;
    /// `None` when every row is taken by another kind.
    fn row(&'static self) -> Option<u32> {
        let row = self.row.load(Ordering::Relaxed);
        if row != 0 {
            return Some(row);
        }
        for (index, cell) in KINDS.iter().enumerate() {
            let held = *cell.get_or_init(|| self);
            if std::ptr::eq(held, self) {
                let row = u32::try_from(index + 1).ok()?;
                self.row.store(row, Ordering::Relaxed);
                return Some(row);
            }
        }
        None
    }

    /// The kind in `row` (from [`Self::row`]).
    fn at(row: u32) -> Option<&'static HangKind> {
        KINDS.get(usize::try_from(row.checked_sub(1)?).ok()?)?.get().copied()
    }

    fn jank_us(&self) -> Option<u64> {
        self.jank.map(duration_us)
    }

    fn hang_us(&self) -> u64 {
        duration_us(self.hang)
    }
}

fn duration_us(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX).max(1)
}

/// One frame of a hung thread's stack.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HangFrame {
    /// The file name of the image that holds the address.
    pub image: Option<String>,
    /// That image's build id (Mach-O `LC_UUID`, ELF `NT_GNU_BUILD_ID`).
    pub image_id: Option<String>,
    /// The address minus the image's load address.
    pub offset: u64,
    /// The nearest exported symbol, mangled.
    pub symbol: Option<String>,
}

/// The frames of one capture, the interrupted pc first.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HangStack {
    pub frames: Vec<HangFrame>,
    /// The callers past the interrupted pc are unknown (no frame pointers).
    pub truncated: bool,
}

/// Captures the stack of a thread of this process, as Chrome's HangWatcher
/// uses base/profiler's stack sampler.
pub struct StackSampler {
    /// The calling thread as one word for [`Self::capture`]; 0 where
    /// captures are unsupported. Called on every scope open: a
    /// thread-local read.
    pub current_thread: fn() -> u64,
    /// Stop the thread, walk its stack, let it run, then symbolicate. The
    /// error is a stable name for the record's `stack_error`.
    pub capture: Box<dyn Fn(u64) -> Result<HangStack, &'static str> + Send + Sync>,
}

impl StackSampler {
    /// No captures: every record says `"stack_error": "unsupported"`.
    pub fn none() -> Self {
        Self { current_thread: || 0, capture: Box::new(|_| Err(UNSUPPORTED)) }
    }
}

/// Where records go: the watcher thread calls it once per hang.
pub type HangSink = Box<dyn Fn(serde_json::Value) + Send + Sync>;

/// A sink that appends each record, with `fields`, to the JSONL at `path`
/// (owner-only, never through a link, at most [`crate::MAX_LOG_BYTES`]).
pub fn file_sink(path: std::path::PathBuf, fields: crate::Fields) -> HangSink {
    Box::new(move |record| {
        let serde_json::Value::Object(record) = record else { return };
        let mut line = fields.clone();
        line.extend(record);
        crate::append(&path, &serde_json::Value::Object(line));
    })
}

/// `stack_error` of a scope with no thread to capture.
const UNSUPPORTED: &str = "unsupported";
/// `stack_error` of a scope that ended while its thread was captured: the
/// frames would be the thread's next work.
const SCOPE_ENDED: &str = "scope-ended";

/// A busy word: the start in microseconds since the watcher's epoch plus
/// one, above two tier flags. A free slot is 0.
const JANKED: u64 = 1;
const HUNG: u64 = 1 << 1;
const START_SHIFT: u32 = 2;
/// A slot's word while its opener writes the kind, method and thread: start
/// field 0, so the watcher skips it, but not 0, so no other scope claims it.
const CLAIMING: u64 = JANKED;

fn busy_word(start_us: u64) -> u64 {
    start_us.wrapping_add(1) << START_SHIFT
}

fn word_start_us(word: u64) -> Option<u64> {
    (word >> START_SHIFT).checked_sub(1)
}

/// The target while no scope is open: park with no timeout.
const IDLE: u64 = u64::MAX;

#[derive(Default)]
#[repr(align(64))]
struct Slot {
    busy: AtomicU64,
    /// The [`HangKind`] row of the scope in `busy`; written before `busy`
    /// is published.
    kind: AtomicU32,
    method: AtomicU32,
    /// The [`StackSampler::current_thread`] of the scope's thread.
    thread: AtomicU64,
}

impl Slot {
    /// The kind of the scope in this slot; `None` before the first claim.
    fn kind(&self) -> Option<&'static HangKind> {
        HangKind::at(self.kind.load(Ordering::Relaxed))
    }
}

/// The watcher's counters.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HangStats {
    /// Times the watcher thread woke (its start, every timed or unparked
    /// return). 0 more for an idle process.
    pub wakeups: u64,
    /// Scopes that ran past their kind's jank tier.
    pub janks: u64,
    /// Scopes written to the log as hangs.
    pub hangs: u64,
    /// Scopes that ended past their hang tier before the watcher saw them.
    pub missed_hangs: u64,
    /// Scopes not watched because every slot was taken.
    pub unwatched: u64,
    /// Stack captures attempted.
    pub stack_captures: u64,
}

struct Shared {
    epoch: Instant,
    epoch_ms: u64,
    slots: Box<[Slot]>,
    /// The earliest deadline the watcher will wake for (µs since the
    /// epoch), [`IDLE`] while it parks with no timeout.
    target: AtomicU64,
    stopping: AtomicBool,
    sampler: StackSampler,
    sink: HangSink,
    wakeups: AtomicU64,
    janks: AtomicU64,
    hangs: AtomicU64,
    missed_hangs: AtomicU64,
    unwatched: AtomicU64,
    stack_captures: AtomicU64,
}

/// The watcher: its slots and its thread, which stops when this drops.
pub struct HangWatcher {
    shared: Arc<Shared>,
    thread: Thread,
}

impl HangWatcher {
    /// Start the watcher thread (parked until the first scope opens).
    pub fn start(sink: HangSink, sampler: StackSampler) -> std::io::Result<Self> {
        let epoch_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
            .unwrap_or_default();
        let shared = Arc::new(Shared {
            epoch: Instant::now(),
            epoch_ms,
            slots: (0..SLOT_COUNT).map(|_| Slot::default()).collect(),
            target: AtomicU64::new(IDLE),
            stopping: AtomicBool::new(false),
            sampler,
            sink,
            wakeups: AtomicU64::new(0),
            janks: AtomicU64::new(0),
            hangs: AtomicU64::new(0),
            missed_hangs: AtomicU64::new(0),
            unwatched: AtomicU64::new(0),
            stack_captures: AtomicU64::new(0),
        });
        let watcher = shared.clone();
        let handle =
            cmux_threads::spawn(THREAD_NAME, cmux_threads::ThreadQos::Utility, move || {
                watcher.run();
            })?;
        Ok(Self { shared, thread: handle.thread().clone() })
    }

    /// Watch one run of `method` of `kind` until the scope drops.
    // perf-hot: <100ns hang-scope
    pub fn watch(&self, kind: &'static HangKind, method: u32) -> HangScope<'_> {
        HangScope { watcher: Some(self), token: self.enter(kind, method), ended: Cell::new(false) }
    }

    /// [`Self::watch`] for a caller that cannot hold the scope (a seam of a
    /// crate that does not link this one): end it with [`Self::exit`].
    // perf-hot: <100ns hang-scope
    pub fn enter(&self, kind: &'static HangKind, method: u32) -> HangToken {
        let shared = &*self.shared;
        let Some(row) = kind.row() else {
            shared.unwatched.fetch_add(1, Ordering::Relaxed);
            return HangToken(0);
        };
        let hint = SLOT_HINT.get() % SLOT_COUNT;
        let claimed = (0..SLOT_COUNT).map(|offset| (hint + offset) % SLOT_COUNT).find(|index| {
            shared.slots[*index]
                .busy
                .compare_exchange(0, CLAIMING, Ordering::Acquire, Ordering::Relaxed)
                .is_ok()
        });
        let Some(index) = claimed else {
            shared.unwatched.fetch_add(1, Ordering::Relaxed);
            return HangToken(0);
        };
        SLOT_HINT.set(index);
        let slot = &shared.slots[index];
        // Seqlock write: the kind, method and thread are published with the
        // busy word below.
        fence(Ordering::Release);
        slot.kind.store(row, Ordering::Relaxed);
        slot.method.store(method, Ordering::Relaxed);
        slot.thread.store((shared.sampler.current_thread)(), Ordering::Relaxed);
        let start = shared.now_us();
        slot.busy.store(busy_word(start), Ordering::SeqCst);
        // SeqCst pairs with the watcher's store-then-rescan: either it sees
        // this slot, or this load sees its new target.
        let deadline = start.saturating_add(kind.jank_us().unwrap_or(kind.hang_us()));
        if shared.target.load(Ordering::SeqCst) > deadline
            && shared.target.fetch_min(deadline, Ordering::SeqCst) > deadline
        {
            self.thread.unpark();
        }
        HangToken(u32::try_from(index + 1).unwrap_or(0))
    }

    /// End the scope `token` opened. Each token is ended once.
    // perf-hot: <100ns hang-scope
    pub fn exit(&self, token: HangToken) {
        let Some(index) = token.0.checked_sub(1) else { return };
        let Some(slot) = self.shared.slots.get(index as usize) else { return };
        // The kind is this scope's until the swap frees the slot.
        let kind = slot.kind();
        let end = self.shared.now_us();
        let word = slot.busy.swap(0, Ordering::SeqCst);
        let (Some(start), Some(kind)) = (word_start_us(word), kind) else { return };
        let ran = end.saturating_sub(start);
        if word & JANKED == 0 && kind.jank_us().is_some_and(|jank| ran >= jank) {
            self.shared.janks.fetch_add(1, Ordering::Relaxed);
        }
        if word & HUNG == 0 && ran >= kind.hang_us() {
            self.shared.missed_hangs.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// The watcher's counters.
    pub fn stats(&self) -> HangStats {
        let shared = &self.shared;
        HangStats {
            wakeups: shared.wakeups.load(Ordering::Relaxed),
            janks: shared.janks.load(Ordering::Relaxed),
            hangs: shared.hangs.load(Ordering::Relaxed),
            missed_hangs: shared.missed_hangs.load(Ordering::Relaxed),
            unwatched: shared.unwatched.load(Ordering::Relaxed),
            stack_captures: shared.stack_captures.load(Ordering::Relaxed),
        }
    }

    /// Whether the watcher sleeps with no timeout (no scope left to watch).
    pub fn is_idle(&self) -> bool {
        self.shared.target.load(Ordering::SeqCst) == IDLE
    }
}

impl Drop for HangWatcher {
    fn drop(&mut self) {
        self.shared.stopping.store(true, Ordering::Release);
        self.thread.unpark();
    }
}

thread_local! {
    /// The slot this thread used last: free again in the common case, so
    /// its claim succeeds at the first try.
    static SLOT_HINT: Cell<usize> = const { Cell::new(0) };
}

/// A scope opened by [`HangWatcher::enter`]; 0 when none was (no watcher,
/// or every slot taken).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HangToken(u32);

impl HangToken {
    /// No scope.
    pub const NONE: Self = Self(0);

    /// The token as one word for a seam, 0 for none.
    pub fn raw(self) -> u32 {
        self.0
    }

    /// The token [`Self::raw`] returned.
    pub fn from_raw(raw: u32) -> Self {
        Self(raw)
    }
}

/// One watched scope; dropping it ends the watch.
pub struct HangScope<'a> {
    watcher: Option<&'a HangWatcher>,
    token: HangToken,
    ended: Cell<bool>,
}

impl HangScope<'_> {
    /// A scope that watches nothing.
    pub const fn inert() -> HangScope<'static> {
        HangScope { watcher: None, token: HangToken::NONE, ended: Cell::new(false) }
    }

    /// The scope is now doing `method` (a request reaching its handler).
    pub fn set_method(&self, method: u32) {
        if let (Some(watcher), Some(index)) = (self.watcher, self.token.0.checked_sub(1))
            && !self.ended.get()
            && let Some(slot) = watcher.shared.slots.get(index as usize)
        {
            slot.method.store(method, Ordering::Relaxed);
        }
    }

    /// End the watch before the scope drops (the rest blocks by design,
    /// Chrome's `ScopedBlockingCall` `WILL_BLOCK`).
    pub fn end(&self) {
        if self.ended.replace(true) {
            return;
        }
        if let Some(watcher) = self.watcher {
            watcher.exit(self.token);
        }
    }
}

impl Drop for HangScope<'_> {
    fn drop(&mut self) {
        self.end();
    }
}

impl Shared {
    fn now_us(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn run(&self) {
        self.wakeups.fetch_add(1, Ordering::Relaxed);
        while !self.stopping.load(Ordering::Acquire) {
            let next = self.scan(self.now_us());
            self.target.store(next, Ordering::SeqCst);
            // A scope that opened during the scan read the old target: it
            // woke this thread only if its deadline was before that one.
            // Look again after publishing the new target.
            let next = self.earliest_deadline().min(next);
            self.target.fetch_min(next, Ordering::SeqCst);
            self.sleep();
        }
    }

    /// Park until the target, with no timeout while it is [`IDLE`]; every
    /// return is a wake.
    fn sleep(&self) {
        let target = self.target.load(Ordering::SeqCst);
        if target == IDLE {
            std::thread::park();
        } else {
            let now = self.now_us();
            if target <= now {
                return;
            }
            std::thread::park_timeout(Duration::from_micros(target - now));
        }
        self.wakeups.fetch_add(1, Ordering::Relaxed);
    }

    /// The earliest tier deadline of an open scope that has not reached it.
    fn earliest_deadline(&self) -> u64 {
        self.slots
            .iter()
            .filter_map(|slot| {
                let word = slot.busy.load(Ordering::SeqCst);
                Some(next_deadline(word, word_start_us(word)?, slot.kind()?))
            })
            .min()
            .unwrap_or(IDLE)
    }

    /// Count every scope past its jank tier and write every scope past its
    /// hang tier; return the earliest deadline still ahead.
    fn scan(&self, now: u64) -> u64 {
        let mut next = IDLE;
        for slot in &*self.slots {
            let mut word = slot.busy.load(Ordering::SeqCst);
            let (Some(start), Some(kind)) = (word_start_us(word), slot.kind()) else { continue };
            if word & JANKED == 0
                && kind.jank_us().is_some_and(|jank| now >= start.saturating_add(jank))
            {
                if slot
                    .busy
                    .compare_exchange(word, word | JANKED, Ordering::AcqRel, Ordering::Relaxed)
                    .is_err()
                {
                    // It ended (and was counted) or another scope took the slot.
                    next = next.min(self.slot_deadline(slot));
                    continue;
                }
                self.janks.fetch_add(1, Ordering::Relaxed);
                word |= JANKED;
            }
            if word & HUNG == 0 && now >= start.saturating_add(kind.hang_us()) {
                self.report(slot, word, start, now);
                continue;
            }
            next = next.min(next_deadline(word, start, kind));
        }
        next
    }

    fn slot_deadline(&self, slot: &Slot) -> u64 {
        let word = slot.busy.load(Ordering::SeqCst);
        match (word_start_us(word), slot.kind()) {
            (Some(start), Some(kind)) => next_deadline(word, start, kind),
            _ => IDLE,
        }
    }

    /// Write the hung scope `word` of `slot` with its thread's stack.
    fn report(&self, slot: &Slot, word: u64, start: u64, now: u64) {
        // Seqlock read of the kind, method and thread: kept only if the slot
        // still holds the same scope, which the flag CAS proves.
        let Some(kind) = slot.kind() else { return };
        let method = slot.method.load(Ordering::Relaxed);
        let thread = slot.thread.load(Ordering::Relaxed);
        fence(Ordering::Acquire);
        let hung = word | HUNG;
        if slot.busy.compare_exchange(word, hung, Ordering::AcqRel, Ordering::Relaxed).is_err() {
            return;
        }
        self.hangs.fetch_add(1, Ordering::Relaxed);
        let (stack, error) = if thread == 0 {
            (HangStack::default(), Some(UNSUPPORTED))
        } else {
            self.stack_captures.fetch_add(1, Ordering::Relaxed);
            let captured = (self.sampler.capture)(thread);
            // The slot is the scope's until it ends: if it still holds `hung`,
            // the scope was busy the whole time its thread was stopped.
            if slot.busy.load(Ordering::SeqCst) != hung {
                (HangStack::default(), Some(SCOPE_ENDED))
            } else {
                match captured {
                    Ok(stack) => (stack, None),
                    Err(error) => (HangStack::default(), Some(error)),
                }
            }
        };
        let frames: Vec<serde_json::Value> = stack
            .frames
            .iter()
            .map(|frame| {
                serde_json::json!({
                    "image": frame.image,
                    "image_id": frame.image_id,
                    "offset": frame.offset,
                    "symbol": frame.symbol,
                })
            })
            .collect();
        (self.sink)(serde_json::json!({
            "event": "hang",
            "scope": kind.name,
            "method": (kind.method_name)(method),
            "hang_ms": kind.hang_us() / 1000,
            "busy_ms": now.saturating_sub(start) / 1000,
            "started_at_ms": self.epoch_ms.saturating_add(start / 1000),
            "at_ms": self.epoch_ms.saturating_add(now / 1000),
            "stack": frames,
            "stack_truncated": stack.truncated,
            "stack_error": error,
        }));
    }
}

/// The next tier `word` (started at `start`) has not reached; [`IDLE`] once
/// it was written as a hang.
fn next_deadline(word: u64, start: u64, kind: &HangKind) -> u64 {
    if word & HUNG != 0 {
        return IDLE;
    }
    match kind.jank_us() {
        Some(jank) if word & JANKED == 0 => start.saturating_add(jank),
        _ => start.saturating_add(kind.hang_us()),
    }
}

static INSTALLED: OnceLock<HangWatcher> = OnceLock::new();

/// Make `watcher` the process's watcher, as [`crate::install`] makes the
/// panic hook (Chrome's `HangWatcher` is one per process too). A second
/// install is refused and returns its watcher.
pub fn install(watcher: HangWatcher) -> Result<(), HangWatcher> {
    INSTALLED.set(watcher)
}

/// The process's watcher, once installed.
pub fn installed() -> Option<&'static HangWatcher> {
    INSTALLED.get()
}

/// Watch one run of `method` of `kind` on the process's watcher until the
/// scope drops; inert before [`install`].
// perf-hot: <100ns hang-scope
pub fn watch_scope(kind: &'static HangKind, method: u32) -> HangScope<'static> {
    match INSTALLED.get() {
        Some(watcher) => watcher.watch(kind, method),
        None => HangScope::inert(),
    }
}

/// [`HangWatcher::enter`] on the process's watcher; [`HangToken::NONE`]
/// before [`install`].
pub fn enter(kind: &'static HangKind, method: u32) -> HangToken {
    INSTALLED.get().map_or(HangToken::NONE, |watcher| watcher.enter(kind, method))
}

/// [`HangWatcher::exit`] on the process's watcher.
pub fn exit(token: HangToken) {
    if let Some(watcher) = INSTALLED.get() {
        watcher.exit(token);
    }
}
