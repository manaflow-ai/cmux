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
//! - A run claims a free slot and stores its start and method in one atomic
//!   word ([`RequestWatchdog::begin`]); dropping the [`RequestScope`] clears
//!   it.
//! - Only a run that finds the watchdog disarmed arms it and unparks the
//!   thread; while it is armed, runs touch no shared state but their slot
//!   and the `armed` load.
//! - The armed thread sleeps until the earliest unrecorded run's start plus
//!   the threshold, records every run past it, and disarms after a full
//!   threshold period in which no run started and no unrecorded run is
//!   busy. Idle, it parks with no timer: 0 wakeups. Under a stream of short
//!   requests it wakes at most once per threshold (4/s) plus one arm.
//!
//! The thread starts with the first run, at QoS utility, as
//! `mux-request-watchdog`.
//!
//! Each recorded request carries the stack of the thread that runs it,
//! captured while it is still busy (Chrome's HangWatcher captures a hung
//! thread's stack the same way, through base/profiler's stack sampler):
//! a run also stores its thread's handle in its slot, and the watchdog stops
//! that thread for a frame-pointer walk (cmux-tui-platform
//! `thread_backtrace`) in well under a millisecond. The image and offset of
//! each frame symbolicate offline (`atos`, `addr2line`). Nothing is captured
//! for a run that ends under the threshold.

use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering, fence};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::Thread;
use std::time::{Duration, Instant};

use super::command_names::COMMANDS;
use cmux_tui_platform::thread_backtrace::{self, ThreadHandle};

use crate::diagnostics::{SlowRequest, SlowRequestFrame, SlowRequestsSnapshot};
use crate::panic_free::RecoverPoison;

/// How long a request runs before the watchdog records it.
pub(crate) const REQUEST_WATCHDOG_THRESHOLD: Duration = Duration::from_millis(250);

/// Runs watched at once: every connection's control sequence
/// (`MAX_SERVER_CONNECTIONS`), the clear-history workers
/// (`SERVER_SURFACE_WORKER_CAPACITY`) and terminal-create commits. A run
/// that finds every slot taken goes unwatched and is counted.
const SLOT_COUNT: usize = 128;

/// Recorded requests kept for `server-stats`.
const SLOW_REQUEST_RING: usize = 128;

const THREAD_NAME: &str = "mux-request-watchdog";

/// A slot's word while its claimer writes the client: start field 0, so the
/// watcher skips it, but not 0, so no other run claims the slot.
const CLAIMING: u64 = 1;

/// Bits of a busy word that hold the method index; the rest hold the start
/// in microseconds since the watchdog's epoch plus one (48 bits: 8.9 years).
const METHOD_BITS: u32 = 16;
const START_MASK: u64 = (1 << (64 - METHOD_BITS)) - 1;
const UNKNOWN_METHOD: u16 = u16::MAX;

/// One watched run: free (0), being claimed ([`CLAIMING`]) or busy (its
/// start and method, see [`busy_word`]).
#[derive(Default)]
#[repr(align(64))]
struct Slot {
    busy: AtomicU64,
    /// The client of the run in `busy`; written before `busy` is published.
    client: AtomicU64,
    /// The [`ThreadHandle`] of the thread that runs it (0: none), written
    /// with `client`.
    thread: AtomicU64,
    /// The busy word last recorded; written only by the watchdog thread.
    recorded: AtomicU64,
    /// Start (µs since the epoch) of the newest run in this slot.
    last_start_us: AtomicU64,
}

fn busy_word(start_us: u64, method: u16) -> u64 {
    ((start_us.wrapping_add(1) & START_MASK) << METHOD_BITS) | u64::from(method)
}

/// The start of a busy word, `None` for a free or claiming slot.
fn word_start_us(word: u64) -> Option<u64> {
    (word >> METHOD_BITS).checked_sub(1)
}

fn word_method(word: u64) -> &'static str {
    let index = (word & ((1 << METHOD_BITS) - 1)) as usize;
    COMMANDS.get(index).map_or("unknown", |command| command.wire)
}

fn method_index(method: &str) -> u16 {
    static INDEX: OnceLock<HashMap<&'static str, u16>> = OnceLock::new();
    let index = INDEX.get_or_init(|| {
        COMMANDS
            .iter()
            .enumerate()
            .filter_map(|(index, command)| Some((command.wire, u16::try_from(index).ok()?)))
            .collect()
    });
    index.get(method).copied().unwrap_or(UNKNOWN_METHOD)
}

struct Shared {
    epoch: Instant,
    threshold: Duration,
    slots: Box<[Slot]>,
    /// Set by the first run that finds it clear; cleared by the watchdog
    /// thread when nothing is left to watch.
    armed: AtomicBool,
    stopping: AtomicBool,
    /// The watchdog thread, started by the first arm; `None` when its spawn
    /// failed.
    thread: OnceLock<Option<Thread>>,
    wakeups: AtomicU64,
    unwatched: AtomicU64,
    total: AtomicU64,
    /// Stack captures attempted; only a recorded request is captured.
    stack_captures: AtomicU64,
    /// Lock carve-out: a short copy, taken by the watchdog thread when it
    /// records and by `server-stats`; never by a watched run.
    recent: Mutex<VecDeque<SlowRequest>>,
}

impl Shared {
    fn now_us(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
    }

    fn threshold_us(&self) -> u64 {
        u64::try_from(self.threshold.as_micros()).unwrap_or(u64::MAX)
    }

    /// Wake the watchdog thread, starting it the first time (a new thread
    /// scans first, so it needs no unpark).
    fn wake(self: &Arc<Self>) {
        let mut started = false;
        let thread = self.thread.get_or_init(|| {
            started = true;
            let shared = self.clone();
            cmux_threads::spawn(THREAD_NAME, cmux_threads::ThreadQos::Utility, move || {
                shared.run();
            })
            .ok()
            .map(|handle| handle.thread().clone())
        });
        if !started && let Some(thread) = thread {
            thread.unpark();
        }
    }

    fn run(&self) {
        self.wakeups.fetch_add(1, Ordering::Relaxed);
        // A run that started after the previous scan keeps the watchdog
        // armed for one more threshold period.
        let mut previous_scan = 0;
        while !self.stopping.load(Ordering::Acquire) {
            let now = self.now_us();
            let scan = self.scan(now, previous_scan);
            previous_scan = now;
            let deadline = scan
                .next_deadline_us
                .or_else(|| scan.started_since.then(|| now.saturating_add(self.threshold_us())));
            if let Some(deadline) = deadline {
                let wait = deadline.saturating_sub(self.now_us());
                std::thread::park_timeout(Duration::from_micros(wait));
                self.wakeups.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            // Disarm, then look again: a run that started after the scan saw
            // `armed` set and did not wake this thread.
            self.armed.store(false, Ordering::SeqCst);
            if self.any_unrecorded_busy() {
                self.armed.store(true, Ordering::SeqCst);
                continue;
            }
            while !self.armed.load(Ordering::SeqCst) && !self.stopping.load(Ordering::Acquire) {
                std::thread::park();
                self.wakeups.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    fn any_unrecorded_busy(&self) -> bool {
        self.slots.iter().any(|slot| {
            let word = slot.busy.load(Ordering::SeqCst);
            word_start_us(word).is_some() && slot.recorded.load(Ordering::Relaxed) != word
        })
    }

    /// Record every run past the threshold; return the earliest deadline of
    /// the others and whether any run started after `since`.
    fn scan(&self, now: u64, since: u64) -> Scan {
        let threshold = self.threshold_us();
        let mut scan = Scan { next_deadline_us: None, started_since: false };
        for slot in self.slots.iter() {
            if slot.last_start_us.load(Ordering::Relaxed) > since {
                scan.started_since = true;
            }
            let word = slot.busy.load(Ordering::SeqCst);
            let Some(start) = word_start_us(word) else { continue };
            if slot.recorded.load(Ordering::Relaxed) == word {
                continue;
            }
            let deadline = start.saturating_add(threshold);
            if now < deadline {
                scan.next_deadline_us =
                    Some(scan.next_deadline_us.map_or(deadline, |next: u64| next.min(deadline)));
                continue;
            }
            // Seqlock read of the client: keep it only if the slot still
            // holds the same run after the read.
            let client = slot.client.load(Ordering::Relaxed);
            let thread = slot.thread.load(Ordering::Relaxed);
            fence(Ordering::Acquire);
            if slot.busy.load(Ordering::Relaxed) != word {
                continue;
            }
            slot.recorded.store(word, Ordering::Relaxed);
            let (stack, stack_error) = match self.capture_stack(slot, word, thread) {
                Ok(stack) => (stack, None),
                Err(error) => (Vec::new(), Some(error)),
            };
            self.record(SlowRequest {
                method: word_method(word),
                client,
                started_ms: start / 1000,
                busy_ms: now.saturating_sub(start) / 1000,
                stack,
                stack_error,
            });
        }
        scan
    }

    /// The stack of the thread running the busy `word` in `slot`, kept only
    /// if the slot still holds that run once the thread runs again.
    fn capture_stack(
        &self,
        slot: &Slot,
        word: u64,
        thread: u64,
    ) -> Result<Vec<SlowRequestFrame>, &'static str> {
        let thread = ThreadHandle::from_raw(thread)
            .ok_or(thread_backtrace::BacktraceError::Unsupported.as_str())?;
        self.stack_captures.fetch_add(1, Ordering::Relaxed);
        let backtrace = thread_backtrace::capture(thread).map_err(|error| error.as_str())?;
        if slot.busy.load(Ordering::SeqCst) != word {
            return Err(RUN_ENDED);
        }
        Ok(backtrace
            .symbolicate()
            .into_iter()
            .map(|frame| SlowRequestFrame {
                image: frame.image,
                offset: frame.offset as u64,
                symbol: frame.symbol,
            })
            .collect())
    }

    fn record(&self, request: SlowRequest) {
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
        recent.push_back(request);
    }
}

/// `stack_error` of a request that ended while its stack was captured: the
/// frames may be another run's.
const RUN_ENDED: &str = "run-ended";

struct Scan {
    next_deadline_us: Option<u64>,
    started_since: bool,
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
        Self {
            shared: Arc::new(Shared {
                epoch: Instant::now(),
                threshold,
                slots: (0..SLOT_COUNT).map(|_| Slot::default()).collect(),
                armed: AtomicBool::new(false),
                stopping: AtomicBool::new(false),
                thread: OnceLock::new(),
                wakeups: AtomicU64::new(0),
                unwatched: AtomicU64::new(0),
                total: AtomicU64::new(0),
                stack_captures: AtomicU64::new(0),
                recent: Mutex::new(VecDeque::with_capacity(SLOW_REQUEST_RING)),
            }),
        }
    }

    /// Watch one run of `method` for `client` until the scope drops. `None`
    /// when every slot is taken (counted as unwatched).
    pub(crate) fn begin(&self, client: u64, method: &str) -> Option<RequestScope<'_>> {
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
        // Seqlock write: the client is published with the busy word below.
        fence(Ordering::Release);
        slot.client.store(client, Ordering::Relaxed);
        slot.thread.store(ThreadHandle::current().map_or(0, ThreadHandle::raw), Ordering::Relaxed);
        let start = shared.now_us();
        slot.last_start_us.store(start.max(1), Ordering::Relaxed);
        slot.busy.store(busy_word(start, method_index(method)), Ordering::SeqCst);
        // SeqCst pairs with the thread's disarm-then-rescan: either it sees
        // this run, or this load sees it disarmed.
        if !shared.armed.load(Ordering::SeqCst) && !shared.armed.swap(true, Ordering::SeqCst) {
            shared.wake();
        }
        Some(RequestScope { slot })
    }

    /// The `slow_requests` section of `server-stats`.
    pub(crate) fn snapshot(&self) -> SlowRequestsSnapshot {
        let shared = &self.shared;
        SlowRequestsSnapshot {
            threshold_ms: u64::try_from(shared.threshold.as_millis()).unwrap_or(u64::MAX),
            total: shared.total.load(Ordering::Relaxed),
            unwatched: shared.unwatched.load(Ordering::Relaxed),
            watchdog_wakeups: shared.wakeups.load(Ordering::Relaxed),
            recent: shared.recent.lock().recover_poison().iter().cloned().collect(),
        }
    }
}

impl Drop for RequestWatchdog {
    fn drop(&mut self) {
        self.shared.stopping.store(true, Ordering::Release);
        if let Some(Some(thread)) = self.shared.thread.get() {
            thread.unpark();
        }
    }
}

/// One watched run; dropping it frees the slot.
pub(crate) struct RequestScope<'a> {
    slot: &'a Slot,
}

impl Drop for RequestScope<'_> {
    fn drop(&mut self) {
        self.slot.busy.store(0, Ordering::Release);
    }
}

#[cfg(test)]
#[path = "request_watchdog_tests.rs"]
mod tests;
