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
//!   not read its input, a credit acknowledgement or a snapshot to a holder
//!   that is slow to read, a publication the full terminal work pool hands
//!   back) calls [`will_block`]: the shard's queue moves to its parked spare
//!   thread for the call, as Chrome's `ScopedBlockingCall`
//!   (`BlockingType::WILL_BLOCK`, base/threading/scoped_blocking_call.h)
//!   raises its group's capacity and wakes an idle worker, which
//!   base/task/thread_pool/thread_group_impl.cc keeps on a stack rather
//!   than starting one per blocking call. A thread starts only when the
//!   shard has no spare. The blocked thread then hands its terminal back
//!   and parks as the shard's spare, so a shard keeps at most one idle
//!   thread and a query answer starts none.
//! - **Starting.** A shard whose thread could not start is tried again at
//!   the next terminal; meanwhile its terminals go to a shard that runs.
//! - **Lifetime.** A shard starts with its first terminal and waits on its
//!   queue with no timeout (no idle wakeup). A dropped owner's shards end
//!   once their last terminal finished.

use std::any::Any;
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

/// One terminal's output on the pool. `Any`: a caller takes its own source
/// back when no shard can run it ([`VtPool::register`]).
pub(crate) trait VtSource: Any + Send {
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
    /// A thread a run blocked on parks as the shard's spare: it runs the
    /// shard when the shard's next run blocks.
    Spare(Sender<Box<ShardLoop>>),
    OwnerGone,
}

/// Starts a named thread that runs the body: the seam a test counts or
/// fails thread starts through.
pub(crate) type StartThread =
    Arc<dyn Fn(String, Box<dyn FnOnce() + Send>) -> std::io::Result<()> + Send + Sync>;

/// Starts echo-path threads (`crate::echo_thread`).
fn echo_path_threads() -> StartThread {
    Arc::new(|name, body| crate::echo_thread::spawn(name, body).map(drop))
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
    /// Empty until the shard's thread started (tried again at each
    /// terminal while it cannot).
    queues: Box<[OnceLock<Sender<Msg>>]>,
}

/// An owner's VT pool (the mux's, through its terminal work pool).
pub(crate) struct VtPool {
    /// `None`: [`VtPoolConfig::for_machine`], read at the first terminal.
    config: Option<VtPoolConfig>,
    shards: OnceLock<Shards>,
    next_token: AtomicU64,
    sources: Arc<AtomicUsize>,
    start: StartThread,
}

impl VtPool {
    /// A pool sized for this machine.
    pub(crate) fn for_machine() -> Self {
        Self::with_config(None)
    }

    /// A pool of `config`'s shards and slice.
    #[cfg(test)]
    pub(crate) fn new(config: VtPoolConfig) -> Self {
        Self::with_thread_start(Some(config), echo_path_threads())
    }

    fn with_config(config: Option<VtPoolConfig>) -> Self {
        Self::with_thread_start(config, echo_path_threads())
    }

    /// A pool whose threads start through `start` (a test counts or fails
    /// them there).
    pub(crate) fn with_thread_start(config: Option<VtPoolConfig>, start: StartThread) -> Self {
        Self {
            config,
            shards: OnceLock::new(),
            next_token: AtomicU64::new(0),
            sources: Arc::default(),
            start,
        }
    }

    /// Puts `source` on a shard (round robin; the next running one when
    /// its own cannot start) and returns the wake that queues its runs; no
    /// run happens before the first wake. Returns `source` when no shard's
    /// thread can start.
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
        self.shards
            .get()
            .map_or(0, |shards| shards.queues.iter().filter(|queue| queue.get().is_some()).count())
    }

    /// The queue of `token`'s shard, or of the next shard that runs when
    /// that one's thread cannot start now.
    fn shard_queue(&self, token: u64) -> Option<&Sender<Msg>> {
        let shards = self.shards.get_or_init(|| {
            let config = self.config.unwrap_or_else(VtPoolConfig::for_machine);
            let count = config.shards.max(1);
            Shards { config, queues: (0..count).map(|_| OnceLock::new()).collect() }
        });
        let count = shards.queues.len();
        let first = usize::try_from(token % count as u64).unwrap_or(0);
        (0..count).find_map(|step| self.started_shard(shards, (first + step) % count))
    }

    /// Shard `index`'s queue, its thread started now if it was not yet. A
    /// start that fails leaves the slot empty for the next terminal.
    fn started_shard<'a>(&self, shards: &'a Shards, index: usize) -> Option<&'a Sender<Msg>> {
        let slot = shards.queues.get(index)?;
        if let Some(queue) = slot.get() {
            return Some(queue);
        }
        let queue = start_shard(index, shards.config.slice, &self.sources, &self.start)?;
        if let Err(raced) = slot.set(queue) {
            // Another terminal started this shard first: this one ends.
            let _ = raced.send(Msg::OwnerGone);
        }
        slot.get()
    }
}

impl Drop for VtPool {
    fn drop(&mut self) {
        let Some(shards) = self.shards.get() else { return };
        for queue in shards.queues.iter().filter_map(OnceLock::get) {
            let _ = queue.send(Msg::OwnerGone);
        }
    }
}

fn start_shard(
    index: usize,
    slice: SliceBudget,
    sources: &Arc<AtomicUsize>,
    start: &StartThread,
) -> Option<Sender<Msg>> {
    let (queue, receiver) = mpsc::channel();
    let shard = Box::new(ShardLoop {
        index,
        slice,
        receiver,
        queue: queue.clone(),
        entries: HashMap::new(),
        owner_gone: false,
        sources: sources.clone(),
        start: start.clone(),
        spare: None,
    });
    match on_new_thread(shard) {
        Ok(()) => Some(queue),
        Err(_) => {
            eprintln!("cmux-tui: VT pool shard {index} could not start (tried again later)");
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
    start: StartThread,
    /// A parked thread that takes the shard when a run blocks.
    spare: Option<Sender<Box<ShardLoop>>>,
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
                // One spare at most: the thread of a second one ends.
                Msg::Spare(spare) => {
                    if self.spare.is_none() {
                        self.spare = Some(spare);
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
    let body = Box::new(move || {
        if let Ok(shard) = take.recv() {
            run_shard(shard);
        }
    });
    match (shard.start)(name, body) {
        Ok(()) => give.send(shard).map_err(|error| error.0),
        Err(_) => Err(shard),
    }
}

/// A terminal whose run blocked, for its shard to take back.
type Returned = (u64, Box<dyn VtSource>, Ran);

/// Why a thread stopped running its shard.
enum Left {
    /// The shard ended.
    Ended,
    /// A [`will_block`] moved the shard to another thread, with the
    /// terminal of the run that blocked (none when a finish blocked).
    Moved(Option<Returned>),
}

/// A shard thread's body: runs the shard, and parks as the shard's spare
/// once a [`will_block`] moved the shard to another thread. It ends with
/// its shard, or when the shard has a spare already.
fn run_shard(shard: Box<ShardLoop>) {
    let mut next = Some(shard);
    while let Some(shard) = next.take() {
        let queue = shard.queue.clone();
        match serve(shard) {
            Left::Ended => return,
            Left::Moved(returned) => next = park_as_spare(&queue, returned),
        }
    }
}

/// Offers this thread as the shard's spare, hands back the terminal whose
/// run blocked, and waits for the shard with no timeout. `None`: the shard
/// ended or has a spare already, and this thread ends.
fn park_as_spare(queue: &Sender<Msg>, returned: Option<Returned>) -> Option<Box<ShardLoop>> {
    let (give, take) = mpsc::channel();
    // The spare first: the returned terminal's next run, the one most
    // likely to block again, then finds it.
    let offered = queue.send(Msg::Spare(give)).is_ok();
    if let Some((token, source, ran)) = returned {
        let _ = queue.send(Msg::Return(token, source, ran));
    }
    if !offered {
        return None;
    }
    take.recv().ok()
}

/// Runs `shard` on this thread until it ends or moves to another thread.
fn serve(shard: Box<ShardLoop>) -> Left {
    let budget = shard.slice;
    SHARD.with(|slot| *slot.borrow_mut() = Some(shard));
    loop {
        let Some(work) = SHARD.with(|slot| slot.borrow_mut().as_mut().map(|shard| shard.next()))
        else {
            // A finish blocked and the shard went on on another thread.
            return Left::Moved(None);
        };
        match work {
            Work::End => {
                SHARD.with(|slot| slot.borrow_mut().take());
                return Left::Ended;
            }
            Work::Run(token, mut source) => {
                let mut slice = Slice::start(budget);
                let ran = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    source.run(&mut slice)
                }))
                .map_or(Ran::Panicked, Ran::Flow);
                let settled = SHARD.with(|slot| match slot.borrow_mut().as_mut() {
                    Some(shard) => Ok(shard.settle(token, source, ran)),
                    None => Err((token, source, ran)),
                });
                match settled {
                    Ok(Some(source)) => finish_source(source),
                    Ok(None) => {}
                    // The run blocked and the shard went on on another
                    // thread: the terminal goes back to it.
                    Err(returned) => return Left::Moved(Some(returned)),
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
/// its spare thread meanwhile (a new thread only when it has none), so a
/// terminal that blocks here holds only this thread, as its reader thread
/// did. Anywhere else it only runs `f`.
pub(crate) fn will_block<R>(f: impl FnOnce() -> R) -> R {
    let Some(mut shard) = SHARD.with(|slot| slot.borrow_mut().take()) else { return f() };
    let moved = match shard.spare.take() {
        Some(spare) => spare.send(shard).map_err(|error| error.0),
        None => Err(shard),
    }
    .or_else(on_new_thread);
    if let Err(shard) = moved {
        // No thread to move to: the shard waits for this call.
        SHARD.with(|slot| *slot.borrow_mut() = Some(shard));
    }
    f()
}

#[cfg(test)]
#[path = "vt_pool_tests.rs"]
mod tests;
