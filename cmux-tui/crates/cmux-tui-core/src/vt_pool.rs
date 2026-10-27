//! The VT pool: a few threads parse every holder terminal's output in place
//! of one `surface-<id>-reader` per terminal (p01-process-120), in two
//! thread groups by visibility (p01-process-124).
//!
//! - Visible group: min(4, P-cores / 2) threads `vt-pool-v-<n>` at
//!   USER_INITIATED (`ThreadType::Interactive`).
//! - Hidden group: 1 or 2 threads `vt-pool-h-<n>` at UTILITY
//!   (`ThreadType::Utility`).
//!
//! This is Chrome's thread pool shape: a foreground and a background thread
//! group (base/task/thread_pool/thread_pool_impl.cc, `GetThreadGroupForTraits`),
//! each terminal one sequence that at most one thread runs at a time
//! (base/task/thread_pool/sequence.h), and a sequence whose priority changes
//! leaves the old group's queue for the new one's
//! (`ThreadPoolImpl::UpdatePriority`). A running sequence finishes its slice
//! and is re-enqueued by its priority at that time, so a terminal's bytes
//! are parsed in offset order whichever group it is in.
//!
//! A thread takes its group's next runnable terminal, parses one slice of
//! [`SLICE_BYTES`] or [`SLICE_TIME`], confirms the parsed offset (the
//! holder's credit, today's ACK), publishes a frame if the terminal is
//! visible, and puts it at the back of its group's queue while bytes are
//! left. A flood therefore delays another terminal of its group by at most
//! one slice per thread, and never a terminal of the other group. A hidden
//! terminal parses and confirms (its holder keeps sending) but does no frame
//! work: the first slice after it is shown publishes its final state once.
//!
//! The pool lock is a leaf: no terminal call runs while it is held.

#![cfg_attr(
    not(test),
    expect(dead_code, reason = "p01-process-120 binds the holder link to the pool")
)]
#![deny(clippy::disallowed_types, clippy::disallowed_methods)]

use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::io;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_threads::sync::{Condvar, Mutex, MutexGuard};

use crate::thread_qos::ThreadType;

/// Most bytes one slice parses before its terminal goes to the back.
pub(crate) const SLICE_BYTES: usize = 64 * 1024;
/// Longest a slice parses before its terminal goes to the back.
pub(crate) const SLICE_TIME: Duration = Duration::from_millis(1);
/// Unparsed bytes one terminal may hold: the holder link queue, which the
/// holder's 512 KiB credit window keeps it under.
pub(crate) const MAX_PENDING_BYTES: usize = 1024 * 1024;
/// The bytes one [`VtTerminal::parse`] call takes; the slice clock is read
/// between calls.
const STEP_BYTES: usize = 16 * 1024;
const MAX_VISIBLE_THREADS: usize = 4;
const MAX_HIDDEN_THREADS: usize = 2;

/// A terminal's key in the pool (the surface id).
pub(crate) type VtTerminalId = u64;

/// One holder terminal as the pool drives it. The pool calls it from one
/// thread at a time, in offset order, and never while it holds its own lock.
pub(crate) trait VtTerminal: Send + Sync + 'static {
    /// Parses `bytes`, which start at stream offset `offset`, under the
    /// terminal lock.
    fn parse(&self, offset: u64, bytes: &[u8]);
    /// Everything before `end` is parsed: the holder gets its credit back.
    fn confirm_parsed(&self, end: u64);
    /// Publishes the parsed screen to the terminal's views.
    fn publish(&self);
}

/// The clock a slice is timed with (a seam for tests).
pub(crate) trait SliceClock: Send + Sync + 'static {
    fn now(&self) -> Instant;
}

/// [`SliceClock`] on the monotonic clock.
pub(crate) struct MonotonicClock;

impl SliceClock for MonotonicClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// The thread group a terminal is parsed on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum VtGroup {
    Visible,
    Hidden,
}

impl VtGroup {
    pub(crate) const ALL: [Self; 2] = [Self::Visible, Self::Hidden];

    fn index(self) -> usize {
        match self {
            Self::Visible => 0,
            Self::Hidden => 1,
        }
    }

    pub(crate) fn thread_type(self) -> ThreadType {
        match self {
            Self::Visible => ThreadType::Interactive,
            Self::Hidden => ThreadType::Utility,
        }
    }

    pub(crate) fn thread_name(self, n: usize) -> String {
        match self {
            Self::Visible => format!("vt-pool-v-{n}"),
            Self::Hidden => format!("vt-pool-h-{n}"),
        }
    }
}

/// How many threads and how large a slice.
#[derive(Clone)]
pub(crate) struct VtPoolConfig {
    pub(crate) visible_threads: usize,
    pub(crate) hidden_threads: usize,
    pub(crate) slice_bytes: usize,
    pub(crate) slice_time: Duration,
    pub(crate) max_pending_bytes: usize,
    pub(crate) clock: Arc<dyn SliceClock>,
}

impl VtPoolConfig {
    /// The groups for a Mac with `performance_cores` P-cores: visible
    /// min(4, P / 2), hidden half of that, 1 or 2; each at least one.
    pub(crate) fn for_performance_cores(performance_cores: usize) -> Self {
        let visible_threads = (performance_cores / 2).clamp(1, MAX_VISIBLE_THREADS);
        Self {
            visible_threads,
            hidden_threads: (visible_threads / 2).clamp(1, MAX_HIDDEN_THREADS),
            slice_bytes: SLICE_BYTES,
            slice_time: SLICE_TIME,
            max_pending_bytes: MAX_PENDING_BYTES,
            clock: Arc::new(MonotonicClock),
        }
    }

    /// [`Self::for_performance_cores`] of this host.
    pub(crate) fn host() -> Self {
        Self::for_performance_cores(cmux_threads::work::performance_cores())
    }

    fn threads(&self, group: VtGroup) -> usize {
        match group {
            VtGroup::Visible => self.visible_threads,
            VtGroup::Hidden => self.hidden_threads,
        }
        .max(1)
    }
}

/// Why the pool refused a call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum VtPoolError {
    UnknownTerminal(VtTerminalId),
    AlreadyRegistered(VtTerminalId),
    /// The bytes do not start where the terminal's last bytes ended.
    Gap {
        id: VtTerminalId,
        expected: u64,
        offset: u64,
    },
    /// The terminal would hold more than `limit` unparsed bytes: its holder
    /// sent past its credit.
    Full {
        id: VtTerminalId,
        pending: usize,
        limit: usize,
    },
    ShutDown,
}

impl fmt::Display for VtPoolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownTerminal(id) => write!(f, "vt pool: terminal {id} is not registered"),
            Self::AlreadyRegistered(id) => {
                write!(f, "vt pool: terminal {id} is already registered")
            }
            Self::Gap { id, expected, offset } => {
                write!(f, "vt pool: terminal {id} bytes start at {offset}, expected {expected}")
            }
            Self::Full { id, pending, limit } => {
                write!(f, "vt pool: terminal {id} holds {pending} unparsed bytes (limit {limit})")
            }
            Self::ShutDown => f.write_str("vt pool: shut down"),
        }
    }
}

impl std::error::Error for VtPoolError {}

/// What the pool holds, read by diagnostics and tests.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct VtPoolStats {
    /// Threads per group, [`VtGroup::ALL`] order.
    pub(crate) threads: [usize; 2],
    /// Terminals waiting in each group's queue.
    pub(crate) runnable: [usize; 2],
    pub(crate) terminals: usize,
    pub(crate) pending_bytes: usize,
    /// Terminals dropped because a terminal call panicked.
    pub(crate) panicked: u64,
}

/// Unparsed bytes: `bytes[start..]`, the first of them at stream `offset`.
struct Chunk {
    offset: u64,
    bytes: Vec<u8>,
    start: usize,
}

impl Chunk {
    fn len(&self) -> usize {
        self.bytes.len() - self.start
    }
}

/// The part of a terminal its running thread reads without the pool lock.
struct Slot {
    terminal: Arc<dyn VtTerminal>,
    /// Mirrors [`Entry::group`]; written under the pool lock.
    visible: AtomicBool,
}

struct Entry {
    slot: Arc<Slot>,
    group: VtGroup,
    chunks: VecDeque<Chunk>,
    /// Unparsed bytes, the running slice's included.
    pending: usize,
    /// Where the next pushed bytes must start.
    queued_end: u64,
    running: bool,
    queued: bool,
    /// Parsed bytes no frame has shown yet.
    frame_due: bool,
    /// Unregistered while a thread ran it: dropped when the slice ends.
    removed: bool,
}

impl Entry {
    fn runnable(&self) -> bool {
        !self.chunks.is_empty() || (self.frame_due && self.group == VtGroup::Visible)
    }
}

/// One slice's work, taken under the lock and run outside it.
struct Job {
    id: VtTerminalId,
    slot: Arc<Slot>,
    chunks: VecDeque<Chunk>,
    frame_due: bool,
}

/// What a slice did, handed back under the lock.
struct Outcome {
    id: VtTerminalId,
    leftovers: VecDeque<Chunk>,
    parsed: usize,
    frame_due: bool,
    panicked: bool,
}

#[derive(Default)]
struct PoolState {
    entries: HashMap<VtTerminalId, Entry>,
    queues: [VecDeque<VtTerminalId>; 2],
    shutdown: bool,
    panicked: u64,
}

impl PoolState {
    /// Puts `id` at the back of its group's queue if it has work and no
    /// thread runs it.
    fn schedule(&mut self, id: VtTerminalId, wake: &[Condvar; 2]) {
        let Some(entry) = self.entries.get_mut(&id) else { return };
        if entry.running || entry.queued || entry.removed || !entry.runnable() {
            return;
        }
        entry.queued = true;
        let group = entry.group.index();
        self.queues[group].push_back(id);
        wake[group].notify_one();
    }

    fn unqueue(&mut self, id: VtTerminalId, group: VtGroup) {
        let queue = &mut self.queues[group.index()];
        if let Some(at) = queue.iter().position(|queued| *queued == id) {
            queue.remove(at);
        }
    }

    fn take_job(&mut self, group: VtGroup, slice_bytes: usize) -> Option<Job> {
        while let Some(id) = self.queues[group.index()].pop_front() {
            let Some(entry) = self.entries.get_mut(&id) else { continue };
            entry.queued = false;
            if !entry.runnable() {
                continue;
            }
            entry.running = true;
            let mut chunks = VecDeque::new();
            let mut taken = 0;
            while taken < slice_bytes {
                let Some(chunk) = entry.chunks.pop_front() else { break };
                taken += chunk.len();
                chunks.push_back(chunk);
            }
            let frame_due = std::mem::take(&mut entry.frame_due);
            return Some(Job { id, slot: Arc::clone(&entry.slot), chunks, frame_due });
        }
        None
    }

    /// Ends a slice; returns an entry unregistered meanwhile, to drop after
    /// the lock.
    fn finish(&mut self, outcome: Outcome, wake: &[Condvar; 2]) -> Option<Entry> {
        let id = outcome.id;
        let entry = self.entries.get_mut(&id)?;
        entry.running = false;
        if entry.removed || outcome.panicked {
            self.panicked += u64::from(outcome.panicked);
            return self.entries.remove(&id);
        }
        for chunk in outcome.leftovers.into_iter().rev() {
            entry.chunks.push_front(chunk);
        }
        entry.pending -= outcome.parsed;
        entry.frame_due |= outcome.frame_due;
        self.schedule(id, wake);
        None
    }
}

struct Shared {
    state: Mutex<PoolState>,
    /// One per group, [`VtGroup::ALL`] order.
    wake: [Condvar; 2],
    config: VtPoolConfig,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, PoolState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The pool's threads and its terminals.
pub(crate) struct VtPool {
    shared: Arc<Shared>,
    threads: Vec<JoinHandle<()>>,
}

impl VtPool {
    /// Starts both groups' threads.
    pub(crate) fn start(config: VtPoolConfig) -> io::Result<Self> {
        let shared = Arc::new(Shared {
            state: Mutex::new(PoolState::default()),
            wake: [Condvar::new(), Condvar::new()],
            config,
        });
        let mut pool = Self { shared, threads: Vec::new() };
        for group in VtGroup::ALL {
            for n in 0..pool.shared.config.threads(group) {
                let shared = Arc::clone(&pool.shared);
                let handle = cmux_threads::spawn(
                    group.thread_name(n),
                    group.thread_type().qos(),
                    move || run_worker(&shared, group),
                )?;
                pool.threads.push(handle);
            }
        }
        Ok(pool)
    }

    /// Adds a terminal whose next bytes start at `offset`.
    pub(crate) fn register(
        &self,
        id: VtTerminalId,
        terminal: Arc<dyn VtTerminal>,
        group: VtGroup,
        offset: u64,
    ) -> Result<(), VtPoolError> {
        let mut state = self.shared.lock();
        if state.shutdown {
            return Err(VtPoolError::ShutDown);
        }
        if state.entries.contains_key(&id) {
            return Err(VtPoolError::AlreadyRegistered(id));
        }
        let slot = Arc::new(Slot { terminal, visible: AtomicBool::new(group == VtGroup::Visible) });
        state.entries.insert(
            id,
            Entry {
                slot,
                group,
                chunks: VecDeque::new(),
                pending: 0,
                queued_end: offset,
                running: false,
                queued: false,
                frame_due: false,
                removed: false,
            },
        );
        Ok(())
    }

    /// Queues `bytes`, which start at stream `offset`, for `id`'s group.
    // perf-hot: <2us terminal-feed
    pub(crate) fn push(
        &self,
        id: VtTerminalId,
        offset: u64,
        bytes: Vec<u8>,
    ) -> Result<(), VtPoolError> {
        let shared = &*self.shared;
        let mut state = shared.lock();
        if state.shutdown {
            return Err(VtPoolError::ShutDown);
        }
        let limit = shared.config.max_pending_bytes;
        let entry = match state.entries.get_mut(&id) {
            Some(entry) if !entry.removed => entry,
            _ => return Err(VtPoolError::UnknownTerminal(id)),
        };
        if offset != entry.queued_end {
            return Err(VtPoolError::Gap { id, expected: entry.queued_end, offset });
        }
        if bytes.is_empty() {
            return Ok(());
        }
        let pending = entry.pending + bytes.len();
        if pending > limit {
            return Err(VtPoolError::Full { id, pending, limit });
        }
        entry.pending = pending;
        entry.queued_end += bytes.len() as u64;
        entry.chunks.push_back(Chunk { offset, bytes, start: 0 });
        state.schedule(id, &shared.wake);
        Ok(())
    }

    /// Moves `id` to `group`. Its unparsed bytes follow it in order; a slice
    /// running on the old group finishes there first.
    pub(crate) fn set_group(&self, id: VtTerminalId, group: VtGroup) -> Result<(), VtPoolError> {
        let shared = &*self.shared;
        let mut state = shared.lock();
        let entry = match state.entries.get_mut(&id) {
            Some(entry) if !entry.removed => entry,
            _ => return Err(VtPoolError::UnknownTerminal(id)),
        };
        if entry.group == group {
            return Ok(());
        }
        let old = std::mem::replace(&mut entry.group, group);
        entry.slot.visible.store(group == VtGroup::Visible, Ordering::Release);
        if std::mem::take(&mut entry.queued) {
            state.unqueue(id, old);
        }
        state.schedule(id, &shared.wake);
        Ok(())
    }

    /// Removes `id`; its unparsed bytes are dropped. A running slice
    /// finishes first.
    pub(crate) fn unregister(&self, id: VtTerminalId) -> Result<(), VtPoolError> {
        let removed = {
            let mut state = self.shared.lock();
            let entry = match state.entries.get_mut(&id) {
                Some(entry) if !entry.removed => entry,
                _ => return Err(VtPoolError::UnknownTerminal(id)),
            };
            let group = entry.group;
            if std::mem::take(&mut entry.queued) {
                state.unqueue(id, group);
            }
            match state.entries.get_mut(&id) {
                Some(entry) if entry.running => {
                    entry.removed = true;
                    entry.chunks.clear();
                    None
                }
                _ => state.entries.remove(&id),
            }
        };
        drop(removed);
        Ok(())
    }

    pub(crate) fn stats(&self) -> VtPoolStats {
        let state = self.shared.lock();
        let mut threads = [0; 2];
        for group in VtGroup::ALL {
            threads[group.index()] = self.shared.config.threads(group);
        }
        VtPoolStats {
            threads,
            runnable: [state.queues[0].len(), state.queues[1].len()],
            terminals: state.entries.values().filter(|entry| !entry.removed).count(),
            pending_bytes: state.entries.values().map(|entry| entry.pending).sum(),
            panicked: state.panicked,
        }
    }

    /// Stops the threads after their running slices and joins them; queued
    /// bytes are dropped.
    pub(crate) fn shutdown(&mut self) {
        let entries = {
            let mut state = self.shared.lock();
            state.shutdown = true;
            std::mem::take(&mut state.entries)
        };
        drop(entries);
        for wake in &self.shared.wake {
            wake.notify_all();
        }
        for handle in self.threads.drain(..) {
            // A worker that panicked outside a slice has nothing left to stop.
            let _ = cmux_threads::checked::sync::join(handle);
        }
    }
}

impl Drop for VtPool {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn run_worker(shared: &Shared, group: VtGroup) {
    let mut state = shared.lock();
    loop {
        if state.shutdown {
            return;
        }
        let Some(job) = state.take_job(group, shared.config.slice_bytes) else {
            state = shared.wake[group.index()]
                .idle()
                .wait(state)
                .unwrap_or_else(PoisonError::into_inner);
            continue;
        };
        drop(state);
        let outcome = run_slice(&shared.config, job);
        state = shared.lock();
        let removed = state.finish(outcome, &shared.wake);
        if removed.is_some() {
            drop(state);
            drop(removed);
            state = shared.lock();
        }
    }
}

/// Parses one slice, confirms it and publishes it if the terminal is
/// visible; the terminal stays this thread's until [`PoolState::finish`].
fn run_slice(config: &VtPoolConfig, job: Job) -> Outcome {
    let Job { id, slot, mut chunks, frame_due } = job;
    let mut parsed = 0;
    let mut published = false;
    let body = catch_unwind(AssertUnwindSafe(|| {
        let terminal = &*slot.terminal;
        let started = config.clock.now();
        let mut end = None;
        while let Some(chunk) = chunks.front_mut() {
            if parsed >= config.slice_bytes
                || (parsed > 0 && config.clock.now().duration_since(started) >= config.slice_time)
            {
                break;
            }
            let step = chunk.len().min(STEP_BYTES).min(config.slice_bytes - parsed);
            terminal.parse(chunk.offset, &chunk.bytes[chunk.start..chunk.start + step]);
            chunk.start += step;
            chunk.offset += step as u64;
            parsed += step;
            end = Some(chunk.offset);
            if chunk.len() == 0 {
                chunks.pop_front();
            }
        }
        if let Some(end) = end {
            terminal.confirm_parsed(end);
        }
        if (parsed > 0 || frame_due) && slot.visible.load(Ordering::Acquire) {
            terminal.publish();
            published = true;
        }
    }));
    Outcome {
        id,
        leftovers: chunks,
        parsed,
        frame_due: (parsed > 0 || frame_due) && !published,
        panicked: body.is_err(),
    }
}

#[cfg(test)]
#[path = "vt_pool_tests.rs"]
mod tests;
