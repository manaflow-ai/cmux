//! The daemon-wide sequenced pool (plans/cmux-next/chrome-parity/p05-ipc.md
//! section 3.4, task p05-ipc-073).
//!
//! Chrome runs a process's work as tasks on sequences of one ThreadPool
//! ("We prefer sequences to threads", docs/threading_and_tasks.md): a
//! sequence runs its tasks one at a time in post order on whichever worker
//! is free, and the pool's thread count does not follow the number of
//! sequences. cmux does the same for connections: each connection's control
//! sequence and each of its streams is a [`Sequence`] here, so a hundred
//! connections add no thread.
//!
//! - **Priorities.** A sequence has a [`SequencePriority`] for life. Each
//!   priority has its own fixed workers (input 2, control the cores minus
//!   two, utility 2, background 1), started on demand and never more, as
//!   Chrome keeps separate foreground and background thread groups
//!   (base/task/thread_pool/thread_pool_impl.cc). A worker runs only its
//!   priority's sequences, so bulk work never takes a control worker.
//! - **Fairness.** A worker runs one task of a sequence, then puts the
//!   sequence at the back of its priority's ready queue: a long sequence
//!   never starves the others (base/task/thread_pool/thread_group_impl.cc
//!   reenqueues a sequence after each task).
//! - **Blocking compensation.** A task inside [`will_block`] (Chrome's
//!   `ScopedBlockingCall` with `WILL_BLOCK`) stops counting against its
//!   priority's workers until it leaves, so a waiting request starts one
//!   temporary worker when other work is ready, up to
//!   [`MAX_COMPENSATING_WORKERS`] (Chrome's `kMaxNumberOfWorkers`,
//!   base/task/thread_pool/thread_group_impl.h). When the task leaves, a
//!   worker over the count exits as soon as it has nothing to run: no
//!   reclaim timer.
//! - **Fences.** [`SequencedPool::fence`] runs a callback once other
//!   sequences ran every task posted to them before the fence: the stream
//!   barrier (stream_lanes.rs) is built on it.
//! - **No idle wakeups.** An idle worker waits on its priority's condition
//!   variable with no timeout; only a post wakes it.
//!
//! Lock order: a caller may hold its own state lock (a connection
//! scheduler's) while it posts; the pool never calls out while it holds its
//! lock (tasks and fence callbacks run after it is released).

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use cmux_threads::ThreadQos;

use crate::panic_free::RecoverPoison;
use crate::thread_qos::ThreadType;

use super::CONNECTION_SURFACE_QUEUE_CAPACITY;
use super::connection_scheduler::REQUEST_THREAD_QOS;

/// The most temporary workers one priority starts for tasks inside
/// [`will_block`] (Chrome's `kMaxNumberOfWorkers`, 256).
pub(super) const MAX_COMPENSATING_WORKERS: usize = 256;

/// A sequence's priority (the schema `priority`: input, control, bulk,
/// background). It picks the workers that run the sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(
    not(test),
    expect(dead_code, reason = "streams (p05-ipc-074) and bulk (p05-ipc-072) post at the others")
)]
pub(crate) enum SequencePriority {
    /// A focused stream's input and echo.
    Input,
    /// A connection's control sequence: requests, their replies and events.
    Control,
    /// Bulk transfers (snapshots, scrollback).
    Utility,
    /// Work nobody waits for.
    Background,
}

impl SequencePriority {
    /// Every priority, highest first.
    #[cfg(test)]
    pub(crate) const ALL: [Self; 4] = [Self::Input, Self::Control, Self::Utility, Self::Background];

    const fn index(self) -> usize {
        match self {
            Self::Input => 0,
            Self::Control => 1,
            Self::Utility => 2,
            Self::Background => 3,
        }
    }

    /// The worker thread name.
    const fn thread_name(self) -> &'static str {
        match self {
            Self::Input => "mux-seq-input",
            Self::Control => "mux-seq-control",
            Self::Utility => "mux-seq-utility",
            Self::Background => "mux-seq-background",
        }
    }

    /// The workers' QoS class. Input runs at the request class until the
    /// PL-qos exception row raises it (p05-ipc-080).
    const fn qos(self) -> ThreadQos {
        match self {
            Self::Input | Self::Control => REQUEST_THREAD_QOS,
            Self::Utility => ThreadType::Utility.qos(),
            Self::Background => ThreadType::Background.qos(),
        }
    }

    /// Input and control workers are request threads: blocking is
    /// disallowed for their life, as on `spawn_request_thread`'s threads.
    const fn is_request_class(self) -> bool {
        matches!(self, Self::Input | Self::Control)
    }
}

/// How many workers each priority keeps at most, blocked tasks aside.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PoolConfig {
    workers: [usize; 4],
}

impl PoolConfig {
    /// Input 2, control the available cores minus two (at least 2), utility
    /// 2, background 1 (p05-ipc.md, task 073).
    pub(crate) fn for_cores(cores: usize) -> Self {
        Self { workers: [2, cores.saturating_sub(2).max(2), 2, 1] }
    }

    /// [`Self::for_cores`] of this machine.
    pub(crate) fn from_machine() -> Self {
        Self::for_cores(std::thread::available_parallelism().map_or(4, usize::from))
    }

    pub(crate) fn workers(&self, priority: SequencePriority) -> usize {
        self.workers[priority.index()]
    }

    #[cfg(test)]
    pub(crate) fn with_workers(mut self, priority: SequencePriority, workers: usize) -> Self {
        self.workers[priority.index()] = workers.max(1);
        self
    }
}

/// Why a task was not posted. The task did not run and never will.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PostError {
    /// The sequence holds its cap of queued tasks
    /// ([`CONNECTION_SURFACE_QUEUE_CAPACITY`]): known not delivered.
    Full,
    /// The pool shut down.
    ShutDown,
}

impl std::fmt::Display for PostError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Full => "sequence queue is full",
            Self::ShutDown => "sequenced pool shut down",
        })
    }
}

impl std::error::Error for PostError {}

/// What [`SequencedPool::fence`] did with its callback.
pub(crate) enum Fenced<F> {
    /// Some sequence had work queued: the callback runs once all of it ran.
    Waiting,
    /// No sequence had work queued; the callback is handed back unrun.
    Drained(F),
}

type Task = Box<dyn FnOnce() + Send + 'static>;

enum Item {
    Task(Task),
    /// Reached when every item before it ran: one count off the fence.
    Fence(u64),
}

struct SequenceState {
    priority: SequencePriority,
    items: VecDeque<Item>,
    /// Queued tasks (fences not counted), against `cap`.
    tasks: usize,
    cap: usize,
    running: bool,
    /// Its handle dropped: removed once it has nothing left to run.
    released: bool,
}

impl SequenceState {
    fn busy(&self) -> bool {
        self.running || self.tasks > 0
    }
}

struct FenceState {
    remaining: usize,
    then: Task,
}

#[derive(Clone, Copy, Default)]
struct Workers {
    live: usize,
    idle: usize,
    /// Notified idle workers that have not woken yet.
    waking: usize,
    /// Tasks of this priority inside [`will_block`].
    blocked: usize,
}

struct PoolState {
    sequences: HashMap<u64, SequenceState>,
    fences: HashMap<u64, FenceState>,
    next_id: u64,
    ready: [VecDeque<u64>; 4],
    workers: [Workers; 4],
    shut_down: bool,
}

pub(super) struct Shared {
    config: PoolConfig,
    state: Mutex<PoolState>,
    work: [Condvar; 4],
    /// Times an idle worker woke (posts and spurious returns).
    wakeups: AtomicU64,
    /// Workers started over the pool's life.
    started: AtomicU64,
}

/// The pool. Dropping it shuts it down: queued tasks are dropped unrun and
/// each worker exits after its current task.
pub(crate) struct SequencedPool {
    shared: Arc<Shared>,
}

impl Default for SequencedPool {
    fn default() -> Self {
        Self::new(PoolConfig::from_machine())
    }
}

impl std::fmt::Debug for SequencedPool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SequencedPool").field("config", &self.shared.config).finish()
    }
}

impl SequencedPool {
    pub(crate) fn new(config: PoolConfig) -> Self {
        Self {
            shared: Arc::new(Shared {
                config,
                state: Mutex::new(PoolState {
                    sequences: HashMap::new(),
                    fences: HashMap::new(),
                    next_id: 1,
                    ready: Default::default(),
                    workers: [Workers::default(); 4],
                    shut_down: false,
                }),
                work: Default::default(),
                wakeups: AtomicU64::new(0),
                started: AtomicU64::new(0),
            }),
        }
    }

    /// A new sequence at `priority` that queues at most
    /// [`CONNECTION_SURFACE_QUEUE_CAPACITY`] tasks.
    pub(crate) fn sequence(&self, priority: SequencePriority) -> Sequence {
        self.sequence_with_cap(priority, CONNECTION_SURFACE_QUEUE_CAPACITY)
    }

    pub(crate) fn sequence_with_cap(&self, priority: SequencePriority, cap: usize) -> Sequence {
        let mut state = self.shared.lock();
        let id = state.next_id;
        state.next_id += 1;
        state.sequences.insert(
            id,
            SequenceState {
                priority,
                items: VecDeque::new(),
                tasks: 0,
                cap,
                running: false,
                released: false,
            },
        );
        Sequence { shared: self.shared.clone(), id, priority }
    }

    /// Runs `then` once each of `sequences` ran every task posted to it
    /// before this call. When none has a task queued or running, `then` is
    /// handed back unrun ([`Fenced::Drained`]) and the caller goes on at
    /// once. `then` runs on the worker that finished the last such task,
    /// with no pool lock held.
    pub(crate) fn fence<F>(&self, sequences: &[&Sequence], then: F) -> Fenced<F>
    where
        F: FnOnce() + Send + 'static,
    {
        let mut state = self.shared.lock();
        let busy: Vec<u64> = sequences
            .iter()
            .filter(|sequence| Arc::ptr_eq(&sequence.shared, &self.shared))
            .map(|sequence| sequence.id)
            .filter(|id| state.sequences.get(id).is_some_and(SequenceState::busy))
            .collect();
        if busy.is_empty() {
            return Fenced::Drained(then);
        }
        let fence = state.next_id;
        state.next_id += 1;
        state.fences.insert(fence, FenceState { remaining: busy.len(), then: Box::new(then) });
        for id in busy {
            if let Some(sequence) = state.sequences.get_mut(&id) {
                sequence.items.push_back(Item::Fence(fence));
            }
        }
        Fenced::Waiting
    }

    /// Live workers of `priority`.
    #[cfg(test)]
    pub(crate) fn worker_count(&self, priority: SequencePriority) -> usize {
        self.shared.lock().workers[priority.index()].live
    }

    /// Live workers of every priority.
    #[cfg(test)]
    pub(crate) fn total_workers(&self) -> usize {
        self.shared.lock().workers.iter().map(|workers| workers.live).sum()
    }

    /// Times an idle worker woke up, over the pool's life.
    #[cfg(test)]
    pub(crate) fn idle_wakeups(&self) -> u64 {
        self.shared.wakeups.load(Ordering::Relaxed)
    }

    /// Workers started over the pool's life.
    #[cfg(test)]
    pub(crate) fn workers_started(&self) -> u64 {
        self.shared.started.load(Ordering::Relaxed)
    }

    #[cfg(test)]
    pub(crate) fn config(&self) -> PoolConfig {
        self.shared.config
    }
}

impl Drop for SequencedPool {
    fn drop(&mut self) {
        let dropped = {
            let mut state = self.shared.lock();
            state.shut_down = true;
            for ready in &mut state.ready {
                ready.clear();
            }
            state.fences.clear();
            let mut dropped = Vec::new();
            for sequence in state.sequences.values_mut() {
                sequence.tasks = 0;
                dropped.extend(sequence.items.drain(..));
            }
            dropped
        };
        for condvar in &self.shared.work {
            condvar.notify_all();
        }
        // Queued tasks drop here, outside the lock: their captures may
        // take other locks as they go.
        drop(dropped);
    }
}

/// A handle to one sequence. Dropping it lets the sequence run what it
/// holds; it is removed once empty.
pub(crate) struct Sequence {
    shared: Arc<Shared>,
    id: u64,
    priority: SequencePriority,
}

impl std::fmt::Debug for Sequence {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Sequence").field("id", &self.id).field("priority", &self.priority).finish()
    }
}

impl Sequence {
    /// Queues `task` behind every task posted to this sequence before it.
    pub(crate) fn post<F>(&self, task: F) -> Result<(), PostError>
    where
        F: FnOnce() + Send + 'static,
    {
        let spawn = {
            let mut state = self.shared.lock();
            if state.shut_down {
                return Err(PostError::ShutDown);
            }
            let Some(sequence) = state.sequences.get_mut(&self.id) else {
                return Err(PostError::ShutDown);
            };
            if sequence.tasks >= sequence.cap {
                return Err(PostError::Full);
            }
            sequence.tasks += 1;
            sequence.items.push_back(Item::Task(Box::new(task)));
            let became_ready = !sequence.running && sequence.tasks == 1;
            if became_ready {
                state.ready[self.priority.index()].push_back(self.id);
            }
            became_ready && self.shared.wake_or_reserve(&mut state, self.priority)
        };
        if spawn {
            self.shared.spawn_worker(self.priority);
        }
        Ok(())
    }

    /// Queued tasks plus the running one.
    #[cfg(test)]
    pub(crate) fn depth(&self) -> usize {
        let state = self.shared.lock();
        state
            .sequences
            .get(&self.id)
            .map_or(0, |sequence| sequence.tasks + usize::from(sequence.running))
    }

    /// No task queued or running.
    #[cfg(test)]
    pub(crate) fn is_idle(&self) -> bool {
        self.depth() == 0
    }
}

impl Drop for Sequence {
    fn drop(&mut self) {
        let mut state = self.shared.lock();
        let remove = match state.sequences.get_mut(&self.id) {
            Some(sequence) => {
                sequence.released = true;
                !sequence.running && sequence.items.is_empty()
            }
            None => false,
        };
        if remove {
            state.sequences.remove(&self.id);
        }
    }
}

thread_local! {
    /// The pool and priority of the worker this thread is, for
    /// [`will_block`].
    static WORKER: RefCell<Option<(Arc<Shared>, SequencePriority)>> = const { RefCell::new(None) };
    /// Inside a [`will_block`] already: a nested scope counts nothing.
    static BLOCKED: Cell<bool> = const { Cell::new(false) };
}

/// Runs `f`, which waits (a request that waits by design, spawns a process,
/// or reaches the network), outside its priority's worker count: when other
/// work of the priority is ready, a temporary worker starts for it.
/// Off a pool worker, or nested, it only runs `f`.
pub(crate) fn will_block<R>(f: impl FnOnce() -> R) -> R {
    let Some((shared, priority)) = WORKER.with(|worker| worker.borrow().clone()) else {
        return f();
    };
    if BLOCKED.with(|blocked| blocked.replace(true)) {
        return f();
    }
    shared.enter_blocked(priority);
    let _leave = LeaveBlocked { shared, priority };
    f()
}

struct LeaveBlocked {
    shared: Arc<Shared>,
    priority: SequencePriority,
}

impl Drop for LeaveBlocked {
    fn drop(&mut self) {
        BLOCKED.with(|blocked| blocked.set(false));
        let index = self.priority.index();
        let mut state = self.shared.lock();
        state.workers[index].blocked = state.workers[index].blocked.saturating_sub(1);
        // One worker too many now: an idle one wakes to exit.
        let limit = self.shared.limit(&state, self.priority);
        let workers = &mut state.workers[index];
        if workers.live > limit && workers.idle > workers.waking {
            workers.waking += 1;
            self.shared.work[index].notify_one();
        }
    }
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, PoolState> {
        self.state.lock().recover_poison()
    }

    /// The most live workers `priority` may have now.
    fn limit(&self, state: &PoolState, priority: SequencePriority) -> usize {
        let workers = state.workers[priority.index()];
        self.config.workers(priority) + workers.blocked.min(MAX_COMPENSATING_WORKERS)
    }

    /// Wakes an idle worker for one more ready sequence, or reserves a new
    /// worker (true: the caller starts it after releasing the lock).
    fn wake_or_reserve(&self, state: &mut PoolState, priority: SequencePriority) -> bool {
        let limit = self.limit(state, priority);
        let workers = &mut state.workers[priority.index()];
        if workers.idle > workers.waking {
            workers.waking += 1;
            self.work[priority.index()].notify_one();
            return false;
        }
        if workers.live < limit {
            workers.live += 1;
            return true;
        }
        false
    }

    fn enter_blocked(self: &Arc<Self>, priority: SequencePriority) {
        let spawn = {
            let mut state = self.lock();
            state.workers[priority.index()].blocked += 1;
            let ready = state.ready[priority.index()].len();
            let workers = state.workers[priority.index()];
            ready > workers.idle.saturating_sub(workers.waking)
                && self.wake_or_reserve(&mut state, priority)
        };
        if spawn {
            self.spawn_worker(priority);
        }
    }

    /// Starts a worker whose slot [`Self::wake_or_reserve`] reserved.
    fn spawn_worker(self: &Arc<Self>, priority: SequencePriority) {
        let shared = self.clone();
        let started = cmux_threads::spawn(priority.thread_name(), priority.qos(), move || {
            if priority.is_request_class() {
                cmux_threads::disallow_blocking();
            }
            shared.run_worker(priority);
        });
        match started {
            Ok(_detached) => {
                self.started.fetch_add(1, Ordering::Relaxed);
            }
            Err(error) => {
                eprintln!("cmux: could not start {} worker: {error}", priority.thread_name());
                self.lock().workers[priority.index()].live -= 1;
            }
        }
    }

    fn run_worker(self: &Arc<Self>, priority: SequencePriority) {
        WORKER.with(|worker| *worker.borrow_mut() = Some((self.clone(), priority)));
        let _clear = ClearWorker;
        let index = priority.index();
        let mut state = self.lock();
        loop {
            if state.shut_down {
                state.workers[index].live -= 1;
                return;
            }
            let Some(id) = state.ready[index].pop_front() else {
                // A temporary worker whose blocked task left exits once it
                // has nothing to run; it never waits.
                if state.workers[index].live > self.limit(&state, priority) {
                    state.workers[index].live -= 1;
                    return;
                }
                state.workers[index].idle += 1;
                state = self.work[index].wait(state).recover_poison();
                self.wakeups.fetch_add(1, Ordering::Relaxed);
                let workers = &mut state.workers[index];
                workers.idle -= 1;
                workers.waking = workers.waking.saturating_sub(1);
                continue;
            };
            let Some(task) = take_task(&mut state, id) else { continue };
            drop(state);
            if catch_unwind(AssertUnwindSafe(task)).is_err() {
                eprintln!("cmux: a {} task panicked", priority.thread_name());
            }
            state = self.lock();
            let callbacks = finish_task(&mut state, id);
            if !callbacks.is_empty() {
                drop(state);
                for then in callbacks {
                    if catch_unwind(AssertUnwindSafe(then)).is_err() {
                        eprintln!("cmux: a {} fence callback panicked", priority.thread_name());
                    }
                }
                state = self.lock();
            }
        }
    }
}

struct ClearWorker;

impl Drop for ClearWorker {
    fn drop(&mut self) {
        let _ = WORKER.try_with(|worker| worker.borrow_mut().take());
    }
}

/// Takes the head task of ready sequence `id` and marks it running.
fn take_task(state: &mut PoolState, id: u64) -> Option<Task> {
    let sequence = state.sequences.get_mut(&id)?;
    match sequence.items.pop_front() {
        Some(Item::Task(task)) => {
            sequence.tasks -= 1;
            sequence.running = true;
            Some(task)
        }
        // A ready sequence's head is a task: fences are passed when the
        // task before them finishes.
        Some(Item::Fence(fence)) => {
            sequence.items.push_front(Item::Fence(fence));
            None
        }
        None => None,
    }
}

/// Ends sequence `id`'s running task: passes the fences behind it, puts the
/// sequence back in its ready queue when it has a task left, and removes it
/// when its handle is gone and it is empty. Returns the fence callbacks
/// that came due, to run without the lock.
fn finish_task(state: &mut PoolState, id: u64) -> Vec<Task> {
    let mut passed = Vec::new();
    let Some(sequence) = state.sequences.get_mut(&id) else { return Vec::new() };
    sequence.running = false;
    while let Some(Item::Fence(fence)) = sequence.items.front() {
        passed.push(*fence);
        sequence.items.pop_front();
    }
    let (has_task, remove, priority) = (
        !sequence.items.is_empty(),
        sequence.released && sequence.items.is_empty(),
        sequence.priority,
    );
    if has_task {
        state.ready[priority.index()].push_back(id);
    }
    if remove {
        state.sequences.remove(&id);
    }
    let mut callbacks = Vec::new();
    for fence in passed {
        let due = match state.fences.get_mut(&fence) {
            Some(fence) => {
                fence.remaining -= 1;
                fence.remaining == 0
            }
            None => false,
        };
        if due && let Some(fence) = state.fences.remove(&fence) {
            callbacks.push(fence.then);
        }
    }
    callbacks
}

#[cfg(test)]
#[path = "sequenced_pool_tests.rs"]
mod tests;
