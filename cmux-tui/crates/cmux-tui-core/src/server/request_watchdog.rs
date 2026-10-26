//! The daemon's request watchdog: a request that runs past the threshold
//! (250 ms) is recorded once in the `slow_requests` ring of `server-stats`
//! and as a `slow-request` debug-spans line.
//!
//! Chrome's HangWatcher (base/threading/hang_watcher.cc,
//! `HangWatchScopeEnabled` and `HangWatchState`): each watched scope stores
//! its start in an atomic and the watcher thread compares the stored times
//! with the clock; the watched thread never takes a lock or makes a system
//! call for it. Unlike Chrome's fixed 10 s monitoring period, this watcher
//! has no periodic timer:
//!
//! - Every frame a connection reads is watched from its first routing step
//!   (connection_frame.rs), and every `Command` the connection's scheduler
//!   runs on another thread is watched there (connection_scheduler.rs). A
//!   run claims a free slot and stores its start in one atomic word
//!   ([`RequestWatchdog::begin`]); its method names where it is.
//! - A run that ends past the threshold before the watchdog saw it hands
//!   its end to the watchdog, so a slow run is recorded however late the
//!   watchdog thread wakes, and every entry gets its final duration.
//! - A command that blocks by design (`wait-for`) is not watched, as
//!   Chrome's `ScopedBlockingCall` with `WILL_BLOCK` invalidates the watch.
//! - Only a run that finds the watchdog disarmed arms it and unparks the
//!   thread; while it is armed, runs touch no shared state but their slot
//!   and the `armed` load.
//! - The armed thread wakes only on ticks of one grid (multiples of the
//!   threshold since the watchdog started): it records every run past the
//!   threshold and disarms on a tick when no run is left to watch and none
//!   started since its last wake. An arm moves its first tick one period
//!   on, so it replaces the tick it skips. Idle, it parks with no timer:
//!   0 wakeups. Under any request pattern it wakes at most once per
//!   threshold (4/s), plus one.
//!
//! The thread starts with the first arm, at QoS utility, as
//! `mux-request-watchdog`.
//!
//! A run recorded while it is still busy carries the stack of the thread
//! running it, as Chrome's HangWatcher hands a hung thread to base/profiler's
//! stack sampler: each run stores its thread's handle in its slot, and the
//! watchdog stops that thread for a frame-pointer walk (cmux-tui-platform
//! `thread_backtrace`, well under a millisecond). The stack is kept only if
//! the run was still busy once the thread ran again; a run first seen after
//! it ended has no stack (`run-ended`): its thread has moved on to other
//! work. Nothing is captured for a run that ends under the threshold.

use std::borrow::Cow;
use std::cell::Cell;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering, fence};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::Thread;
use std::time::{Duration, Instant};

use cmux_tui_platform::thread_backtrace::{self, Backtrace, BacktraceError, ThreadHandle};

use super::Command;
use super::command_names::COMMANDS;
use crate::diagnostics::{SlowRequest, SlowRequestFrame, SlowRequestsSnapshot};
use crate::panic_free::RecoverPoison;
use crate::resource::ResourceOperation;

/// How long a request runs before the watchdog records it.
pub(crate) const REQUEST_WATCHDOG_THRESHOLD: Duration = Duration::from_millis(250);

/// Runs watched at once: a frame and a dispatched command for every
/// connection (`MAX_SERVER_CONNECTIONS`), the clear-history workers
/// (`SERVER_SURFACE_WORKER_CAPACITY`) and terminal-create commits. A run
/// that finds every slot taken goes unwatched and is counted.
const SLOT_COUNT: usize = 256;

/// Recorded requests kept for `server-stats`.
const SLOW_REQUEST_RING: usize = 128;

const THREAD_NAME: &str = "mux-request-watchdog";

/// A busy word: the start in microseconds since the watchdog's epoch plus
/// one, above two flags. A free slot is 0.
const FINISHED: u64 = 1;
const RECORDED: u64 = 1 << 1;
const FLAGS: u64 = FINISHED | RECORDED;
const START_SHIFT: u32 = 2;

/// A slot's word while its claimer writes the client: start field 0, so the
/// watcher skips it, but not 0, so no other run claims the slot.
const CLAIMING: u64 = FINISHED;

fn busy_word(start_us: u64) -> u64 {
    start_us.wrapping_add(1) << START_SHIFT
}

/// The start of a busy word, `None` for a free or claiming slot.
fn word_start_us(word: u64) -> Option<u64> {
    (word >> START_SHIFT).checked_sub(1)
}

/// What a watched run is doing: a `Command`, a v2 resource operation, or a
/// step of a connection frame's routing. One `u32`, so the slot stores it in
/// one atomic.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct WatchedMethod(u32);

const INDEX_MASK: u32 = 0xffff;
const COMMAND_TAG: u32 = 0;
const RESOURCE_TAG: u32 = 1 << 16;
const FRAME_TAG: u32 = 2 << 16;

impl WatchedMethod {
    pub(super) fn command(command: &Command) -> Self {
        Self(COMMAND_TAG | u32::from(command.wire_index()))
    }

    pub(crate) fn resource(operation: ResourceOperation) -> Self {
        Self(RESOURCE_TAG | operation as u32)
    }

    pub(crate) const fn frame(stage: FrameStage) -> Self {
        Self(FRAME_TAG | stage as u32)
    }

    /// The method's name in `slow_requests`; read only when recording.
    fn name(self) -> &'static str {
        let index = (self.0 & INDEX_MASK) as usize;
        let name = match self.0 & !INDEX_MASK {
            COMMAND_TAG => COMMANDS.get(index).map(|command| command.wire),
            RESOURCE_TAG => ResourceOperation::ALL
                .iter()
                .find(|operation| **operation as usize == index)
                .map(|operation| operation.wire_name()),
            FRAME_TAG => FrameStage::ALL.get(index).map(|stage| stage.name()),
            _ => None,
        };
        name.unwrap_or("unknown")
    }
}

/// The handler a connection frame is in, for a frame that is not a
/// `Command` or a v2 resource line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FrameStage {
    /// Before the frame reaches a handler: the API revision upgrade, the
    /// parse and the hand-off to the scheduler.
    Route,
    PageRouter,
    LoopbackForward,
    BrowserRuntime,
    AgentSession,
    AgentTransfer,
    AgentInventory,
    AgentCliJob,
    AgentCliIntents,
    AgentInventoryWatch,
    MachineCatalog,
    Apps,
    Scripts,
    Fs,
    RemoteRelay,
}

impl FrameStage {
    /// Every stage, in declaration order (`stage as usize` is its index).
    const ALL: [Self; 15] = [
        Self::Route,
        Self::PageRouter,
        Self::LoopbackForward,
        Self::BrowserRuntime,
        Self::AgentSession,
        Self::AgentTransfer,
        Self::AgentInventory,
        Self::AgentCliJob,
        Self::AgentCliIntents,
        Self::AgentInventoryWatch,
        Self::MachineCatalog,
        Self::Apps,
        Self::Scripts,
        Self::Fs,
        Self::RemoteRelay,
    ];

    const fn name(self) -> &'static str {
        match self {
            Self::Route => "frame",
            Self::PageRouter => "frame:page-router",
            Self::LoopbackForward => "frame:loopback-forward",
            Self::BrowserRuntime => "frame:browser-runtime",
            Self::AgentSession => "frame:agent-session",
            Self::AgentTransfer => "frame:agent-transfer",
            Self::AgentInventory => "frame:agent-inventory",
            Self::AgentCliJob => "frame:agent-cli-job",
            Self::AgentCliIntents => "frame:agent-cli-intents",
            Self::AgentInventoryWatch => "frame:agent-inventory-watch",
            Self::MachineCatalog => "frame:machine-catalog",
            Self::Apps => "frame:apps",
            Self::Scripts => "frame:scripts",
            Self::Fs => "frame:fs",
            Self::RemoteRelay => "frame:remote-relay",
        }
    }
}

/// One watched run: free (0), being claimed ([`CLAIMING`]) or busy (its
/// start and flags, see [`busy_word`]).
#[derive(Default)]
#[repr(align(64))]
struct Slot {
    busy: AtomicU64,
    /// The [`WatchedMethod`] of the run in `busy`; the run may change it.
    method: AtomicU32,
    /// The client of the run in `busy`; written before `busy` is published.
    client: AtomicU64,
    /// The [`ThreadHandle`] of the thread running it (0: none), written
    /// with `client`.
    thread: AtomicU64,
    /// Start (µs since the epoch) of the newest run in this slot.
    last_start_us: AtomicU64,
    /// End (µs since the epoch) of a run that finished slow; published by
    /// the [`FINISHED`] flag.
    end_us: AtomicU64,
}

/// Starts the watchdog thread with `body`; a seam so tests can fail it.
type SpawnWatchdog = fn(Box<dyn FnOnce() + Send>) -> std::io::Result<Thread>;

fn spawn_watchdog_thread(body: Box<dyn FnOnce() + Send>) -> std::io::Result<Thread> {
    cmux_threads::spawn(THREAD_NAME, cmux_threads::ThreadQos::Utility, body)
        .map(|handle| handle.thread().clone())
}

/// Stops a thread and walks its stack; a seam so tests can end the run
/// mid-capture.
type CaptureStack = Box<dyn Fn(ThreadHandle) -> Result<Backtrace, BacktraceError> + Send + Sync>;

/// `stack_error` of a run that ended before its thread was stopped: any
/// frames would be the thread's next work.
const RUN_ENDED: &str = "run-ended";

/// A recorded request in the ring, with the run it came from so its final
/// duration can be filled in.
struct RecentEntry {
    slot: usize,
    word: u64,
    request: SlowRequest,
}

struct Shared {
    epoch: Instant,
    threshold: Duration,
    slots: Box<[Slot]>,
    /// Set by the first run that finds it clear; cleared by the watchdog
    /// thread when nothing is left to watch.
    armed: AtomicBool,
    stopping: AtomicBool,
    spawn: SpawnWatchdog,
    capture: CaptureStack,
    /// Stack captures attempted; only a run recorded while busy is captured.
    stack_captures: AtomicU64,
    /// The watchdog thread, set by the first arm whose start succeeds. Only
    /// the run that flipped `armed` starts it, so no two starts race.
    thread: OnceLock<Thread>,
    wakeups: AtomicU64,
    unwatched: AtomicU64,
    expected_waits: AtomicU64,
    spawn_failures: AtomicU64,
    total: AtomicU64,
    /// Lock carve-out: a short copy, taken by the watchdog thread when it
    /// records and by `server-stats`; never by a watched run.
    recent: Mutex<VecDeque<RecentEntry>>,
    /// Tests: held to keep the watchdog thread from scanning.
    #[cfg(test)]
    scan_hold: Mutex<()>,
}

impl Shared {
    fn now_us(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn threshold_us(&self) -> u64 {
        u64::try_from(self.threshold.as_micros()).unwrap_or(u64::MAX).max(1)
    }

    /// Arm the watchdog if it is disarmed, waking (or starting) its thread.
    fn arm(self: &Arc<Self>) {
        // SeqCst pairs with the thread's disarm-then-rescan: either it sees
        // this run's slot, or this load sees it disarmed.
        if !self.armed.load(Ordering::SeqCst) && !self.armed.swap(true, Ordering::SeqCst) {
            self.wake();
        }
    }

    /// Wake the watchdog thread, starting it the first time (a new thread
    /// scans first, so it needs no unpark). A failed start is counted and
    /// disarms, so a later arm tries again.
    fn wake(self: &Arc<Self>) {
        if let Some(thread) = self.thread.get() {
            thread.unpark();
            return;
        }
        let shared = self.clone();
        match (self.spawn)(Box::new(move || shared.run())) {
            Ok(started) => {
                // Only the arming run gets here, and the thread is unset.
                let _ = self.thread.set(started);
            }
            Err(_) => {
                self.spawn_failures.fetch_add(1, Ordering::Relaxed);
                self.armed.store(false, Ordering::SeqCst);
            }
        }
    }

    fn run(&self) {
        self.wakeups.fetch_add(1, Ordering::Relaxed);
        let period = self.threshold_us();
        let mut woke_by_arm = true;
        let mut previous_scan = 0;
        while !self.stopping.load(Ordering::Acquire) {
            #[cfg(test)]
            drop(self.scan_hold.lock().recover_poison());
            let now = self.now_us();
            let scan = self.scan(now, previous_scan);
            previous_scan = now;
            let next_tick = (now / period).saturating_add(1).saturating_mul(period);
            if woke_by_arm {
                // The arming run started after the last tick, so it cannot
                // overrun before the tick one period on: skip the next one.
                woke_by_arm = false;
                self.sleep_until(
                    now.saturating_add(period).div_ceil(period).saturating_mul(period),
                );
                continue;
            }
            if scan.pending || scan.started_since {
                self.sleep_until(next_tick);
                continue;
            }
            // Disarm, then look again: a run that started after the scan saw
            // `armed` set and did not wake this thread.
            self.armed.store(false, Ordering::SeqCst);
            if self.any_pending() {
                self.armed.store(true, Ordering::SeqCst);
                self.sleep_until(next_tick);
                continue;
            }
            while !self.armed.load(Ordering::SeqCst) && !self.stopping.load(Ordering::Acquire) {
                std::thread::park();
                self.wakeups.fetch_add(1, Ordering::Relaxed);
            }
            woke_by_arm = true;
        }
    }

    /// Park until the tick at `target_us`; every return from the park is a
    /// wake.
    fn sleep_until(&self, target_us: u64) {
        loop {
            let now = self.now_us();
            if now >= target_us || self.stopping.load(Ordering::Acquire) {
                return;
            }
            std::thread::park_timeout(Duration::from_micros(target_us - now));
            self.wakeups.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// A run left to watch: one not yet recorded, or one that finished slow.
    fn any_pending(&self) -> bool {
        self.slots.iter().any(|slot| {
            let word = slot.busy.load(Ordering::SeqCst);
            word_start_us(word).is_some() && word & (FINISHED | RECORDED) != RECORDED
        })
    }

    /// Record every run past the threshold and every run that finished
    /// slow; report whether a run is left to watch and whether any run
    /// started after `since`.
    fn scan(&self, now: u64, since: u64) -> Scan {
        let threshold = self.threshold_us();
        let mut scan = Scan { pending: false, started_since: false };
        for (index, slot) in self.slots.iter().enumerate() {
            if slot.last_start_us.load(Ordering::Relaxed) > since {
                scan.started_since = true;
            }
            let word = slot.busy.load(Ordering::SeqCst);
            let Some(start) = word_start_us(word) else { continue };
            if word & FINISHED != 0 {
                self.finish(index, slot, word, start);
                continue;
            }
            if word & RECORDED != 0 {
                continue;
            }
            if now < start.saturating_add(threshold) {
                scan.pending = true;
                continue;
            }
            // Seqlock read of the client, method and thread: keep them only
            // if the slot still holds the same run, which the flag CAS proves.
            let client = slot.client.load(Ordering::Relaxed);
            let method = WatchedMethod(slot.method.load(Ordering::Relaxed));
            let thread = slot.thread.load(Ordering::Relaxed);
            fence(Ordering::Acquire);
            if slot
                .busy
                .compare_exchange(word, word | RECORDED, Ordering::AcqRel, Ordering::Relaxed)
                .is_err()
            {
                // It ended meanwhile: freed fast, or finished for the next scan.
                scan.pending = true;
                continue;
            }
            let stack = self.capture_stack(slot, word | RECORDED, thread);
            self.record(
                index,
                word,
                SlowRequest {
                    method: method.name(),
                    client,
                    started_ms: start / 1000,
                    busy_ms: now.saturating_sub(start) / 1000,
                    duration_ms: None,
                    stack: stack.frames,
                    stack_truncated: stack.truncated,
                    stack_error: stack.error,
                },
            );
        }
        scan
    }

    /// The stack of the thread running the recorded run `word` in `slot`.
    /// The slot holds the run until this thread frees it, so if `busy` is
    /// still `word` after the capture, the run was busy the whole time its
    /// thread was stopped and the frames are its own; once the run ends,
    /// `FINISHED` is set and the frames are dropped.
    fn capture_stack(&self, slot: &Slot, word: u64, thread: u64) -> CapturedStack {
        let Some(thread) = ThreadHandle::from_raw(thread) else {
            return CapturedStack::failed(BacktraceError::Unsupported.as_str());
        };
        self.stack_captures.fetch_add(1, Ordering::Relaxed);
        let captured = (self.capture)(thread);
        if slot.busy.load(Ordering::SeqCst) != word {
            return CapturedStack::failed(RUN_ENDED);
        }
        match captured {
            Ok(backtrace) => CapturedStack {
                frames: backtrace
                    .symbolicate()
                    .into_iter()
                    .map(|frame| SlowRequestFrame {
                        image: frame.image,
                        image_id: frame.image_id,
                        offset: frame.offset as u64,
                        symbol: frame.symbol,
                    })
                    .collect(),
                truncated: backtrace.truncated(),
                error: None,
            },
            Err(error) => CapturedStack::failed(error.as_str()),
        }
    }

    /// A run that finished slow: fill in its entry's duration, or record it
    /// now if no scan saw it running. Then free its slot.
    fn finish(&self, index: usize, slot: &Slot, word: u64, start: u64) {
        let duration_ms = slot.end_us.load(Ordering::Relaxed).saturating_sub(start) / 1000;
        let run = word & !FLAGS;
        if word & RECORDED != 0 {
            let mut recent = self.recent.lock().recover_poison();
            if let Some(entry) =
                recent.iter_mut().rev().find(|entry| entry.slot == index && entry.word == run)
            {
                entry.request.duration_ms = Some(duration_ms);
            }
        } else {
            self.record(
                index,
                run,
                SlowRequest {
                    method: WatchedMethod(slot.method.load(Ordering::Relaxed)).name(),
                    client: slot.client.load(Ordering::Relaxed),
                    started_ms: start / 1000,
                    busy_ms: duration_ms,
                    duration_ms: Some(duration_ms),
                    stack: Vec::new(),
                    stack_truncated: false,
                    // First seen after it ended: its thread runs other work.
                    stack_error: Some(RUN_ENDED),
                },
            );
        }
        slot.busy.store(0, Ordering::Release);
    }

    fn record(&self, slot: usize, word: u64, request: SlowRequest) {
        self.total.fetch_add(1, Ordering::Relaxed);
        let started = self.epoch + Duration::from_millis(request.started_ms);
        if let Some(trace) = crate::debug_spans::Trace::start("slow-request", started) {
            crate::debug_spans::install(Some(trace));
            crate::debug_spans::mark_with(|| Cow::Borrowed(request.method));
            crate::debug_spans::finish(crate::debug_spans::take());
        }
        let mut recent = self.recent.lock().recover_poison();
        if recent.len() == SLOW_REQUEST_RING {
            recent.pop_front();
        }
        recent.push_back(RecentEntry { slot, word, request });
    }
}

struct Scan {
    /// A run not yet recorded is still running under the threshold.
    pending: bool,
    started_since: bool,
}

/// The stack fields of one recorded run.
struct CapturedStack {
    frames: Vec<SlowRequestFrame>,
    truncated: bool,
    error: Option<&'static str>,
}

impl CapturedStack {
    fn failed(error: &'static str) -> Self {
        Self { frames: Vec::new(), truncated: false, error: Some(error) }
    }
}

/// The daemon's request watchdog. One per [`crate::Mux`]; its thread stops
/// when the watchdog is dropped.
pub(crate) struct RequestWatchdog {
    shared: Arc<Shared>,
}

impl Default for RequestWatchdog {
    fn default() -> Self {
        Self::new(REQUEST_WATCHDOG_THRESHOLD)
    }
}

impl RequestWatchdog {
    pub(crate) fn new(threshold: Duration) -> Self {
        Self::with_seams(threshold, spawn_watchdog_thread, Box::new(thread_backtrace::capture))
    }

    fn with_seams(threshold: Duration, spawn: SpawnWatchdog, capture: CaptureStack) -> Self {
        Self {
            shared: Arc::new(Shared {
                epoch: Instant::now(),
                threshold,
                slots: (0..SLOT_COUNT).map(|_| Slot::default()).collect(),
                armed: AtomicBool::new(false),
                stopping: AtomicBool::new(false),
                spawn,
                capture,
                stack_captures: AtomicU64::new(0),
                thread: OnceLock::new(),
                wakeups: AtomicU64::new(0),
                unwatched: AtomicU64::new(0),
                expected_waits: AtomicU64::new(0),
                spawn_failures: AtomicU64::new(0),
                total: AtomicU64::new(0),
                recent: Mutex::new(VecDeque::with_capacity(SLOW_REQUEST_RING)),
                #[cfg(test)]
                scan_hold: Mutex::new(()),
            }),
        }
    }

    /// Watch one run of `method` for `client` until the scope drops. `None`
    /// when every slot is taken (counted as unwatched).
    // perf-hot: <100ns daemon-request
    pub(crate) fn begin(&self, client: u64, method: WatchedMethod) -> Option<RequestScope<'_>> {
        let shared = &self.shared;
        let hint = (client as usize) % SLOT_COUNT;
        let slot = (0..SLOT_COUNT).map(|offset| &shared.slots[(hint + offset) % SLOT_COUNT]).find(
            |slot| {
                slot.busy
                    .compare_exchange(0, CLAIMING, Ordering::Acquire, Ordering::Relaxed)
                    .is_ok()
            },
        );
        let Some(slot) = slot else {
            shared.unwatched.fetch_add(1, Ordering::Relaxed);
            return None;
        };
        // Seqlock write: the client and method are published with the busy
        // word below.
        fence(Ordering::Release);
        slot.client.store(client, Ordering::Relaxed);
        slot.method.store(method.0, Ordering::Relaxed);
        slot.thread.store(ThreadHandle::current().map_or(0, ThreadHandle::raw), Ordering::Relaxed);
        let start = shared.now_us();
        slot.last_start_us.store(start.max(1), Ordering::Relaxed);
        let word = busy_word(start);
        slot.busy.store(word, Ordering::SeqCst);
        shared.arm();
        Some(RequestScope { shared, slot, word, ended: Cell::new(false) })
    }

    /// Watch one run of `command`; a command that waits by design is
    /// counted in `expected_waits` instead.
    // perf-hot: <100ns daemon-request
    pub(super) fn begin_command(&self, client: u64, command: &Command) -> Option<RequestScope<'_>> {
        if command.waits_by_design() {
            self.shared.expected_waits.fetch_add(1, Ordering::Relaxed);
            return None;
        }
        self.begin(client, WatchedMethod::command(command))
    }

    /// The `slow_requests` section of `server-stats`.
    pub(crate) fn snapshot(&self) -> SlowRequestsSnapshot {
        let shared = &self.shared;
        SlowRequestsSnapshot {
            threshold_ms: u64::try_from(shared.threshold.as_millis()).unwrap_or(u64::MAX),
            total: shared.total.load(Ordering::Relaxed),
            unwatched: shared.unwatched.load(Ordering::Relaxed),
            expected_waits: shared.expected_waits.load(Ordering::Relaxed),
            spawn_failures: shared.spawn_failures.load(Ordering::Relaxed),
            watchdog_wakeups: shared.wakeups.load(Ordering::Relaxed),
            recent: shared
                .recent
                .lock()
                .recover_poison()
                .iter()
                .map(|entry| entry.request.clone())
                .collect(),
        }
    }
}

impl Drop for RequestWatchdog {
    fn drop(&mut self) {
        self.shared.stopping.store(true, Ordering::Release);
        if let Some(thread) = self.shared.thread.get() {
            thread.unpark();
        }
    }
}

/// One watched run; dropping it ends the watch.
pub(crate) struct RequestScope<'a> {
    shared: &'a Arc<Shared>,
    slot: &'a Slot,
    word: u64,
    ended: Cell<bool>,
}

impl RequestScope<'_> {
    /// The run is now doing `method` (a frame reaching its handler).
    pub(crate) fn set_method(&self, method: WatchedMethod) {
        self.slot.method.store(method.0, Ordering::Relaxed);
    }

    /// The run is now `command`; a command that waits by design ends the
    /// watch ([`Self::expect_blocking`]).
    pub(super) fn command(&self, command: &Command) {
        self.set_method(WatchedMethod::command(command));
        if command.waits_by_design() {
            self.expect_blocking();
        }
    }

    /// The rest of the run blocks by design: end the watch here and count
    /// the run in `expected_waits` (Chrome's `ScopedBlockingCall`
    /// `WILL_BLOCK`, which calls `HangWatcher::InvalidateActiveExpectations`).
    /// The time before still counts: a run already past the threshold is
    /// recorded with the duration up to now.
    pub(crate) fn expect_blocking(&self) {
        self.shared.expected_waits.fetch_add(1, Ordering::Relaxed);
        self.end();
    }

    // perf-hot: <100ns daemon-request
    fn end(&self) {
        if self.ended.replace(true) {
            return;
        }
        let shared = self.shared;
        let start = word_start_us(self.word).unwrap_or(0);
        let end = shared.now_us();
        // A fast run frees its slot, unless the watchdog recorded it
        // meanwhile (the CAS then fails on its flag).
        if end.saturating_sub(start) < shared.threshold_us()
            && self
                .slot
                .busy
                .compare_exchange(self.word, 0, Ordering::Release, Ordering::Relaxed)
                .is_ok()
        {
            return;
        }
        // A slow run hands its end to the watchdog, which records it and
        // frees the slot.
        self.slot.end_us.store(end, Ordering::Relaxed);
        self.slot.busy.fetch_or(FINISHED, Ordering::SeqCst);
        shared.arm();
    }
}

impl Drop for RequestScope<'_> {
    fn drop(&mut self) {
        self.end();
    }
}

#[cfg(test)]
#[path = "request_watchdog_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "request_watchdog_stack_tests.rs"]
mod stack_tests;
