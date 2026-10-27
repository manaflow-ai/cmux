//! The VT pool: a few shard threads parse the output of every holder
//! terminal (p01-process-120), instead of one blocking
//! `surface-<id>-reader` thread per terminal.
//!
//! Chromium's model is a sequence on a thread pool: each sequence's tasks run
//! one at a time and in order on whichever worker takes them, and a long
//! task gives the worker back between slices
//! (base/task/thread_pool/thread_group_impl.cc,
//! base/task/sequence_manager/sequence_manager_impl.cc). Here a terminal is
//! the sequence and its shard is the worker:
//!
//! - **Queues.** The holder-link thread puts a terminal's DATA into its
//!   `HolderSink`, which credit bounds as before (the sink acknowledges what
//!   the parser parsed, the holder sends at most a credit window past it),
//!   and wakes the terminal's shard ([`VtWake`]). A terminal has at most one
//!   run in its shard's queue, so the queue never holds more runs than the
//!   shard has terminals.
//! - **Order.** A terminal stays on one shard and has at most one run queued
//!   or running: a wake during its run queues one more run after it.
//! - **Slices.** A run parses until its [`Slice`] is spent (64 KiB or 1 ms)
//!   and then goes to the back of its shard's queue, so a flood in one
//!   terminal delays a chunk of another terminal of its shard by at most one
//!   slice.
//! - **Blocking.** A run that will wait (a query answer to a child that does
//!   not read its input, a snapshot to a holder that is slow to read, a
//!   publication the full terminal work pool hands back) calls
//!   [`will_block`]: the shard's queue moves to a new thread for the call, as
//!   Chrome's `ScopedBlockingCall` (`BlockingType::WILL_BLOCK`,
//!   base/threading/scoped_blocking_call.h) adds a worker to its group. The
//!   blocked thread then hands its terminal back to the shard and ends.
//! - **Lifetime.** A shard starts with its first terminal and waits on its
//!   queue with no timeout (no idle wakeup). A dropped owner's shards end
//!   once their last terminal finished.

use std::cell::RefCell;
use std::collections::HashMap;
use std::num::NonZeroUsize;
use std::sync::atomic::{AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

/// Output one run parses before its terminal yields to the others.
pub(crate) const SLICE_BYTES: usize = 64 * 1024;

/// Time one run parses before its terminal yields to the others.
pub(crate) const SLICE_TIME: Duration = Duration::from_millis(1);

/// The most shards a pool runs (task 124 sizes them from the P-cores).
pub(crate) const MAX_SHARDS: usize = 4;

/// The shard threads' name; each is `vt-pool-v-<shard>`.
pub(crate) const VT_POOL_THREAD: &str = "vt-pool-v";

/// How much one run may parse.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SliceBudget {
    pub(crate) bytes: usize,
    pub(crate) time: Duration,
}

impl SliceBudget {
    pub(crate) const DEFAULT: Self = Self { bytes: SLICE_BYTES, time: SLICE_TIME };
}

/// One run's budget as it is spent.
pub(crate) struct Slice {
    budget: SliceBudget,
    started: Instant,
    parsed: usize,
}

impl Slice {
    fn start(budget: SliceBudget) -> Self {
        Self { budget, started: Instant::now(), parsed: 0 }
    }

    /// The run parsed `bytes` more.
    pub(crate) fn charge(&mut self, bytes: usize) {
        self.parsed = self.parsed.saturating_add(bytes);
    }

    /// The run should yield now.
    pub(crate) fn spent(&self) -> bool {
        self.parsed >= self.budget.bytes || self.started.elapsed() >= self.budget.time
    }
}

/// What a terminal wants after a run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum VtFlow {
    /// Nothing queued: run again on its next wake.
    Idle,
    /// The slice is spent and output may be left: run again after the
    /// shard's other queued terminals.
    Yield,
    /// The stream ended: [`VtSource::finish`], then the terminal leaves.
    Finished,
}

/// One terminal's output on the pool.
pub(crate) trait VtSource: Send + 'static {
    /// Parses and publishes queued output until there is none or `slice` is
    /// spent; never waits for more.
    fn run(&mut self, slice: &mut Slice) -> VtFlow;

    /// Runs once, on the shard, after the run that returned
    /// [`VtFlow::Finished`]. Work that may wait goes elsewhere (the owner's
    /// terminal work pool) or into [`will_block`].
    fn finish(self: Box<Self>);
}

/// The shard count and slice of a pool.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct VtPoolConfig {
    pub(crate) shards: usize,
    pub(crate) slice: SliceBudget,
}

impl VtPoolConfig {
    /// Half the cores, at most [`MAX_SHARDS`], at least one.
    fn for_machine() -> Self {
        let cores = std::thread::available_parallelism().map_or(2, NonZeroUsize::get);
        Self { shards: (cores / 2).clamp(1, MAX_SHARDS), slice: SliceBudget::DEFAULT }
    }
}

// A terminal's phase. Every change of it is a read-modify-write, the wakes'
// included: a wake's RMW is ordered before the RMW that starts the next run,
// so that run sees the output the wake was for.
const IDLE: u8 = 0;
const QUEUED: u8 = 1;
const RUNNING: u8 = 2;
/// Running, and woken during the run: one more run follows.
const AGAIN: u8 = 3;
const DONE: u8 = 4;

/// How a run ended.
enum Ran {
    Flow(VtFlow),
    Panicked,
}

enum Msg {
    Add(u64, Arc<AtomicU8>, Box<dyn VtSource>),
    Run(u64),
    /// A run that went on on a thread inside [`will_block`] ended there.
    Return(u64, Box<dyn VtSource>, Ran),
    OwnerGone,
}

/// Queues a run of one terminal: the holder-link thread calls it after it
/// put the terminal's DATA (or its end) into the sink.
#[derive(Clone)]
pub(crate) struct VtWake {
    token: u64,
    phase: Arc<AtomicU8>,
    queue: Sender<Msg>,
}

impl VtWake {
    /// One atomic read-modify-write; one queue send only from idle.
    // perf-hot: <1us vt-pool-dispatch
    pub(crate) fn wake(&self) {
        let woken = self.phase.fetch_update(Ordering::AcqRel, Ordering::Acquire, |phase| {
            match phase {
                IDLE => Some(QUEUED),
                RUNNING => Some(AGAIN),
                // Already queued or woken: the same value, still an RMW.
                QUEUED | AGAIN => Some(phase),
                _ => None,
            }
        });
        if woken == Ok(IDLE) {
            // A shard that ended took the terminal with it.
            let _ = self.queue.send(Msg::Run(self.token));
        }
    }
}

/// The started shards' queues, made at the first terminal.
struct Shards {
    config: VtPoolConfig,
    /// `None`: the shard's thread could not start.
    queues: Box<[OnceLock<Option<Sender<Msg>>>]>,
}

/// An owner's VT pool (the mux's, through its terminal work pool).
pub(crate) struct VtPool {
    /// `None`: [`VtPoolConfig::for_machine`], read at the first terminal.
    config: Option<VtPoolConfig>,
    shards: OnceLock<Shards>,
    next_token: AtomicU64,
    sources: Arc<AtomicUsize>,
}

impl VtPool {
    /// A pool sized for this machine.
    pub(crate) fn for_machine() -> Self {
        Self::with_config(None)
    }

    /// A pool of `config`'s shards and slice.
    #[cfg(test)]
    pub(crate) fn new(config: VtPoolConfig) -> Self {
        Self::with_config(Some(config))
    }

    fn with_config(config: Option<VtPoolConfig>) -> Self {
        Self {
            config,
            shards: OnceLock::new(),
            next_token: AtomicU64::new(0),
            sources: Arc::default(),
        }
    }

    /// Puts `source` on a shard (round robin) and returns the wake that
    /// queues its runs; no run happens before the first wake. Returns
    /// `source` when the shard's thread cannot start.
    pub(crate) fn register(&self, source: Box<dyn VtSource>) -> Result<VtWake, Box<dyn VtSource>> {
        let token = self.next_token.fetch_add(1, Ordering::Relaxed);
        let Some(queue) = self.shard_queue(token) else { return Err(source) };
        let phase = Arc::new(AtomicU8::new(IDLE));
        self.sources.fetch_add(1, Ordering::AcqRel);
        if let Err(mpsc::SendError(message)) = queue.send(Msg::Add(token, phase.clone(), source)) {
            self.sources.fetch_sub(1, Ordering::AcqRel);
            if let Msg::Add(_, _, source) = message {
                return Err(source);
            }
        }
        Ok(VtWake { token, phase, queue: queue.clone() })
    }

    /// Terminals on the pool now (registered, not finished).
    #[cfg(test)]
    pub(crate) fn sources(&self) -> usize {
        self.sources.load(Ordering::Acquire)
    }

    /// The shards whose thread started.
    #[cfg(test)]
    pub(crate) fn started_shards(&self) -> usize {
        self.shards.get().map_or(0, |shards| {
            shards.queues.iter().filter(|queue| queue.get().is_some_and(Option::is_some)).count()
        })
    }

    fn shard_queue(&self, token: u64) -> Option<&Sender<Msg>> {
        let shards = self.shards.get_or_init(|| {
            let config = self.config.unwrap_or_else(VtPoolConfig::for_machine);
            let count = config.shards.max(1);
            Shards { config, queues: (0..count).map(|_| OnceLock::new()).collect() }
        });
        let index = usize::try_from(token % shards.queues.len() as u64).unwrap_or(0);
        let slot = shards.queues.get(index)?;
        slot.get_or_init(|| start_shard(index, shards.config.slice, self.sources.clone())).as_ref()
    }
}

impl Drop for VtPool {
    fn drop(&mut self) {
        let Some(shards) = self.shards.get() else { return };
        for queue in shards.queues.iter().filter_map(|queue| queue.get().and_then(Option::as_ref)) {
            let _ = queue.send(Msg::OwnerGone);
        }
    }
}

fn start_shard(index: usize, slice: SliceBudget, sources: Arc<AtomicUsize>) -> Option<Sender<Msg>> {
    let (queue, receiver) = mpsc::channel();
    let shard = Box::new(ShardLoop {
        index,
        slice,
        receiver,
        queue: queue.clone(),
        entries: HashMap::new(),
        owner_gone: false,
        sources,
    });
    match on_new_thread(shard) {
        Ok(()) => Some(queue),
        Err(_) => {
            eprintln!("cmux-tui: VT pool shard {index} could not start");
            None
        }
    }
}

/// One terminal on its shard.
struct Entry {
    phase: Arc<AtomicU8>,
    /// `None` while a run has it.
    source: Option<Box<dyn VtSource>>,
}

/// A shard's queue and terminals: owned by the one thread that runs them,
/// so no lock guards them.
struct ShardLoop {
    index: usize,
    slice: SliceBudget,
    receiver: Receiver<Msg>,
    /// Its own queue, for runs that go to the back of it.
    queue: Sender<Msg>,
    entries: HashMap<u64, Entry>,
    owner_gone: bool,
    sources: Arc<AtomicUsize>,
}

/// What the shard's thread does next.
enum Work {
    Run(u64, Box<dyn VtSource>),
    Finish(Box<dyn VtSource>),
    /// The owner is gone and its last terminal finished.
    End,
}

thread_local! {
    /// The shard this thread runs, for [`will_block`]; empty once the shard
    /// moved to another thread for a blocking call.
    static SHARD: RefCell<Option<Box<ShardLoop>>> = const { RefCell::new(None) };
}

impl ShardLoop {
    /// Waits for the next run or finish (with no timeout).
    fn next(&mut self) -> Work {
        loop {
            if self.owner_gone && self.entries.is_empty() {
                return Work::End;
            }
            let Ok(message) = self.receiver.recv() else { return Work::End };
            match message {
                Msg::Add(token, phase, source) => {
                    self.entries.insert(token, Entry { phase, source: Some(source) });
                }
                Msg::Run(token) => {
                    let Some(entry) = self.entries.get_mut(&token) else { continue };
                    let Some(source) = entry.source.take() else { continue };
                    entry.phase.swap(RUNNING, Ordering::AcqRel);
                    return Work::Run(token, source);
                }
                Msg::Return(token, source, ran) => {
                    if let Some(source) = self.settle(token, source, ran) {
                        return Work::Finish(source);
                    }
                }
                Msg::OwnerGone => self.owner_gone = true,
            }
        }
    }

    /// Applies a run's outcome. Returns the source to finish when its
    /// stream ended: the caller finishes it outside the shard's borrow.
    fn settle(
        &mut self,
        token: u64,
        source: Box<dyn VtSource>,
        ran: Ran,
    ) -> Option<Box<dyn VtSource>> {
        let entry = self.entries.get_mut(&token)?;
        match ran {
            Ran::Flow(VtFlow::Idle) => {
                entry.source = Some(source);
                // Woken during the run: it goes again.
                if entry
                    .phase
                    .compare_exchange(RUNNING, IDLE, Ordering::AcqRel, Ordering::Acquire)
                    .is_err()
                {
                    self.requeue(token);
                }
                None
            }
            Ran::Flow(VtFlow::Yield) => {
                entry.source = Some(source);
                self.requeue(token);
                None
            }
            Ran::Flow(VtFlow::Finished) => {
                self.remove(token);
                Some(source)
            }
            Ran::Panicked => {
                eprintln!("cmux-tui: a VT pool run panicked");
                self.remove(token);
                // Dropped without `finish`, as a panicking reader thread ended.
                None
            }
        }
    }

    fn requeue(&self, token: u64) {
        if let Some(entry) = self.entries.get(&token) {
            entry.phase.swap(QUEUED, Ordering::AcqRel);
        }
        let _ = self.queue.send(Msg::Run(token));
    }

    fn remove(&mut self, token: u64) {
        if let Some(entry) = self.entries.remove(&token) {
            entry.phase.swap(DONE, Ordering::AcqRel);
            self.sources.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

/// Starts a thread that runs `shard`; gives it back when none can start.
fn on_new_thread(shard: Box<ShardLoop>) -> Result<(), Box<ShardLoop>> {
    let (give, take) = mpsc::channel::<Box<ShardLoop>>();
    let name = format!("{VT_POOL_THREAD}-{}", shard.index);
    match crate::echo_thread::spawn(name, move || {
        if let Ok(shard) = take.recv() {
            run_shard(shard);
        }
    }) {
        Ok(_) => give.send(shard).map_err(|error| error.0),
        Err(_) => Err(shard),
    }
}

/// A shard thread's body. It ends when its shard ends, or after a run or
/// finish whose [`will_block`] moved the shard to another thread.
fn run_shard(shard: Box<ShardLoop>) {
    let (queue, budget) = (shard.queue.clone(), shard.slice);
    SHARD.with(|slot| *slot.borrow_mut() = Some(shard));
    loop {
        let Some(work) = SHARD.with(|slot| slot.borrow_mut().as_mut().map(|shard| shard.next()))
        else {
            return;
        };
        match work {
            Work::End => {
                SHARD.with(|slot| slot.borrow_mut().take());
                return;
            }
            Work::Run(token, mut source) => {
                let mut slice = Slice::start(budget);
                let ran = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    source.run(&mut slice)
                }))
                .map_or(Ran::Panicked, Ran::Flow);
                let settled = SHARD.with(|slot| match slot.borrow_mut().as_mut() {
                    Some(shard) => Ok(shard.settle(token, source, ran)),
                    None => Err((source, ran)),
                });
                match settled {
                    Ok(Some(source)) => finish_source(source),
                    Ok(None) => {}
                    // The run blocked and the shard went on on another
                    // thread: hand the terminal back to it, and end.
                    Err((source, ran)) => {
                        let _ = queue.send(Msg::Return(token, source, ran));
                        return;
                    }
                }
            }
            Work::Finish(source) => finish_source(source),
        }
    }
}

fn finish_source(source: Box<dyn VtSource>) {
    let finished = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| source.finish()));
    if finished.is_err() {
        eprintln!("cmux-tui: a VT pool terminal's finish panicked");
    }
}

/// Runs `f`, which may wait on others (a PTY write, a holder socket, a
/// contended lock). On a VT pool shard, the shard's other terminals run on
/// a new thread meanwhile, so a terminal that blocks here holds only this
/// thread, as its reader thread did. Anywhere else it only runs `f`.
pub(crate) fn will_block<R>(f: impl FnOnce() -> R) -> R {
    let Some(shard) = SHARD.with(|slot| slot.borrow_mut().take()) else { return f() };
    if let Err(shard) = on_new_thread(shard) {
        // No thread to move to: the shard waits for this call.
        SHARD.with(|slot| *slot.borrow_mut() = Some(shard));
    }
    f()
}

#[cfg(test)]
#[path = "vt_pool_tests.rs"]
mod tests;
