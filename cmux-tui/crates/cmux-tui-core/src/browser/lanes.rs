//! Browser lanes: every daemon browser surface's work runs as ordered lanes
//! on one small worker pool, never on threads of its own (p01-process-206).
//!
//! Chrome runs a sequence's tasks one at a time, in order, on whichever pool
//! worker is free ("prefer sequences to threads", docs/threading_and_tasks.md;
//! base/task/thread_pool/pooled_sequenced_task_runner.cc). A browser surface
//! has two lanes here, its CDP event lane and its command lane, and a provider
//! bootstrap is a third lane that ends when the tab is attached. The
//! `browser-runtime-events` thread demultiplexes CDP events into the event
//! lanes.
//!
//! - **Order.** A lane runs one turn at a time. A wake during a turn runs the
//!   lane once more after it.
//! - **Fairness.** A lane with work left after a turn goes to the back of the
//!   ready queue (base/task/thread_pool/thread_group_impl.cc re-enqueues a
//!   sequence after each task).
//! - **Workers.** [`BASE_WORKERS`] workers stay once started. A turn waits on
//!   CDP, a reply from another process, which Chrome runs in a WILL_BLOCK
//!   scope that adds a worker at once (base/threading/scoped_blocking_call.h,
//!   thread_group_impl.cc `BlockingStarted`). So a lane that becomes ready
//!   while no worker idles starts one more, up to [`MAX_WORKERS`] (Chrome's
//!   `kMaxNumberOfWorkers`), and that worker exits as soon as nothing is
//!   ready: one wedged page never delays another surface, and idle surfaces
//!   cost no thread.
//! - **Deadlines.** A turn may ask to run again at an instant. An idle worker
//!   waits until the earliest one; there is no timer thread, as in
//!   server/sequenced_pool.rs (Chrome's DelayedTaskManager).
//! - **Shutdown.** [`BrowserLanes`] owns the pool: dropping it drops every
//!   lane's task and lets the workers exit after their current turn.
//!
//! Lock order: the pool never calls out while it holds its lock; tasks run,
//! and are dropped, outside it.

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc::{SyncSender, TrySendError};
use std::sync::{Arc, MutexGuard};
use std::time::Instant;

use cmux_threads::sync::{Condvar, Mutex};

use crate::panic_free::RecoverPoison;
use crate::thread_qos::ThreadType;

/// Workers that stay once started: what idle browser surfaces cost.
pub(crate) const BASE_WORKERS: usize = 2;
/// The most workers the pool runs, temporary ones included.
pub(crate) const MAX_WORKERS: usize = 256;
const WORKER_NAME: &str = "browser-lane";

/// What a lane does with one turn.
pub(crate) trait LaneTask: Send + 'static {
    fn run(&mut self) -> LaneTurn;
}

/// When a lane runs next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LaneTurn {
    /// At its next wake.
    Idle,
    /// Again, behind the other ready lanes.
    Again,
    /// At its next wake or at this instant, whichever is first.
    WakeAt(Instant),
    /// Never: the lane is removed and its task dropped.
    Done,
}

/// The pool's owner: dropping it shuts the pool down.
pub(crate) struct BrowserLanes {
    pool: LanePool,
}

impl BrowserLanes {
    pub(crate) fn new() -> Self {
        Self { pool: LanePool { shared: Arc::new(Shared::default()) } }
    }

    pub(crate) fn pool(&self) -> &LanePool {
        &self.pool
    }
}

impl Default for BrowserLanes {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for BrowserLanes {
    fn drop(&mut self) {
        self.pool.shared.shutdown();
    }
}

/// A handle to the pool, for making lanes.
#[derive(Clone)]
pub(crate) struct LanePool {
    shared: Arc<Shared>,
}

impl LanePool {
    /// A lane with no task yet: wakes before [`LaneHandle::start`] run it
    /// once it starts.
    pub(crate) fn reserve(&self) -> LaneHandle {
        let mut state = self.shared.lock();
        let id = state.next_id;
        state.next_id += 1;
        if !state.shut_down {
            state.lanes.insert(id, Lane::default());
        }
        LaneHandle { shared: self.shared.clone(), id }
    }

    /// A lane running `task`, idle until its first wake.
    pub(crate) fn start(&self, task: impl LaneTask) -> LaneHandle {
        let lane = self.reserve();
        lane.start(task);
        lane
    }

    /// Workers alive now.
    #[cfg(test)]
    pub(crate) fn live_workers(&self) -> usize {
        self.shared.lock().live
    }

    /// Lanes not done yet.
    #[cfg(test)]
    pub(crate) fn lanes(&self) -> usize {
        self.shared.lock().lanes.len()
    }
}

/// One lane. Clones wake the same lane; dropping every handle does not end
/// it: only its task does, by returning [`LaneTurn::Done`].
#[derive(Clone)]
pub(crate) struct LaneHandle {
    shared: Arc<Shared>,
    id: u64,
}

impl std::fmt::Debug for LaneHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LaneHandle").field("id", &self.id).finish()
    }
}

impl LaneHandle {
    /// Gives a reserved lane its task. A lane that is gone (the pool shut
    /// down) drops it.
    pub(crate) fn start(&self, task: impl LaneTask) {
        let task: Box<dyn LaneTask> = Box::new(task);
        let mut state = self.shared.lock();
        let Some(lane) = state.lanes.get_mut(&self.id) else {
            drop(state);
            drop(task);
            return;
        };
        lane.task = Some(task);
        let spawn =
            std::mem::take(&mut lane.woken_early) && self.shared.make_ready(&mut state, self.id);
        drop(state);
        if spawn {
            self.shared.spawn_worker();
        }
    }

    /// Runs the lane's task once more soon.
    pub(crate) fn wake(&self) {
        let mut state = self.shared.lock();
        let Some(lane) = state.lanes.get_mut(&self.id) else { return };
        let spawn = match &mut lane.phase {
            Phase::Running { again } => {
                *again = true;
                false
            }
            Phase::Ready => false,
            Phase::Idle if lane.task.is_none() => {
                lane.woken_early = true;
                false
            }
            Phase::Idle => self.shared.make_ready(&mut state, self.id),
        };
        drop(state);
        if spawn {
            self.shared.spawn_worker();
        }
    }
}

/// A bounded channel sender that wakes its receiving lane on every send,
/// and once more when the last clone drops so the lane sees the channel
/// close.
pub(crate) struct LaneSender<T> {
    inner: Arc<LaneSenderInner<T>>,
}

struct LaneSenderInner<T> {
    tx: Option<SyncSender<T>>,
    lane: LaneHandle,
}

impl<T> Clone for LaneSender<T> {
    fn clone(&self) -> Self {
        Self { inner: self.inner.clone() }
    }
}

impl<T> LaneSender<T> {
    pub(crate) fn new(tx: SyncSender<T>, lane: LaneHandle) -> Self {
        Self { inner: Arc::new(LaneSenderInner { tx: Some(tx), lane }) }
    }

    /// `SyncSender::try_send`, then a wake of the lane when it was queued.
    pub(crate) fn try_send(&self, value: T) -> Result<(), TrySendError<T>> {
        let Some(tx) = self.inner.tx.as_ref() else {
            return Err(TrySendError::Disconnected(value));
        };
        tx.try_send(value)?;
        self.inner.lane.wake();
        Ok(())
    }
}

impl<T> Drop for LaneSenderInner<T> {
    fn drop(&mut self) {
        // The channel closes first, so the turn this wake runs sees it closed.
        drop(self.tx.take());
        self.lane.wake();
    }
}

#[derive(Default)]
struct Shared {
    state: Mutex<PoolState>,
    work: Condvar,
}

#[derive(Default)]
struct PoolState {
    lanes: HashMap<u64, Lane>,
    ready: VecDeque<u64>,
    timers: BinaryHeap<Reverse<Timer>>,
    next_id: u64,
    live: usize,
    idle: usize,
    /// Notified idle workers that have not woken yet.
    waking: usize,
    shut_down: bool,
}

#[derive(Default)]
struct Lane {
    /// `None` while reserved or while a worker runs it.
    task: Option<Box<dyn LaneTask>>,
    phase: Phase,
    /// Woken while reserved: it runs once it starts.
    woken_early: bool,
    /// The deadline a live timer entry holds, and that entry's generation.
    armed: Option<Instant>,
    timer_generation: u64,
}

#[derive(Default, Debug, PartialEq, Eq)]
enum Phase {
    #[default]
    Idle,
    Ready,
    Running {
        again: bool,
    },
}

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Timer {
    due: Instant,
    lane: u64,
    generation: u64,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, PoolState> {
        self.state.lock().recover_poison()
    }

    /// Queues idle lane `id`. True: the caller starts a worker for it after
    /// releasing the lock.
    fn make_ready(&self, state: &mut PoolState, id: u64) -> bool {
        let Some(lane) = state.lanes.get_mut(&id) else { return false };
        lane.phase = Phase::Ready;
        state.ready.push_back(id);
        self.wake_or_reserve(state)
    }

    /// Wakes an idle worker for one more ready lane, or reserves a new one
    /// (true: the caller starts it after releasing the lock).
    fn wake_or_reserve(&self, state: &mut PoolState) -> bool {
        if state.idle > state.waking {
            state.waking += 1;
            self.work.notify_one();
            return false;
        }
        if state.live < MAX_WORKERS && !state.shut_down {
            state.live += 1;
            return true;
        }
        false
    }

    /// Starts the worker [`Self::wake_or_reserve`] reserved. One that does
    /// not start gives its slot back; the ready lane runs on a live worker
    /// when one frees.
    fn spawn_worker(self: &Arc<Self>) {
        let shared = self.clone();
        let started = cmux_threads::spawn(WORKER_NAME, ThreadType::Interactive.qos(), move || {
            shared.run_worker();
        });
        if let Err(error) = started {
            self.lock().live -= 1;
            eprintln!("cmux: could not start a {WORKER_NAME} worker: {error}");
        }
    }

    fn run_worker(self: &Arc<Self>) {
        let mut state = self.lock();
        loop {
            if state.shut_down {
                state.live -= 1;
                return;
            }
            let spawns = self.promote_due(&mut state);
            if spawns > 0 {
                drop(state);
                for _ in 0..spawns {
                    self.spawn_worker();
                }
                state = self.lock();
                continue;
            }
            let Some(id) = state.ready.pop_front() else {
                // A worker past the base count exits once nothing is ready.
                if state.live > BASE_WORKERS {
                    state.live -= 1;
                    return;
                }
                state.idle += 1;
                state = match self.next_due(&mut state) {
                    None => self.work.idle().wait(state).recover_poison(),
                    Some(due) => {
                        let wait = due.saturating_duration_since(Instant::now());
                        // wakeup-allow: deadline the earliest lane deadline, armed only while a lane asked for one
                        self.work.idle().wait_timeout(state, wait).recover_poison().0
                    }
                };
                state.idle -= 1;
                state.waking = state.waking.saturating_sub(1);
                continue;
            };
            let Some(mut task) = take_task(&mut state, id) else { continue };
            drop(state);
            let turn = catch_unwind(AssertUnwindSafe(|| task.run())).unwrap_or_else(|_| {
                eprintln!("cmux: a {WORKER_NAME} task panicked; its lane ends");
                LaneTurn::Done
            });
            state = self.lock();
            if let Some(finished) = self.finish_turn(&mut state, id, task, turn) {
                // Outside the lock: the task's captures take other locks as
                // they drop.
                drop(state);
                drop(finished);
                state = self.lock();
            }
        }
    }

    /// Puts lane `id`'s task back after a turn. Returns the task to drop,
    /// without the lock, when the lane is done or gone.
    fn finish_turn(
        &self,
        state: &mut PoolState,
        id: u64,
        task: Box<dyn LaneTask>,
        turn: LaneTurn,
    ) -> Option<Box<dyn LaneTask>> {
        if turn == LaneTurn::Done || state.shut_down {
            state.lanes.remove(&id);
            return Some(task);
        }
        let Some(lane) = state.lanes.get_mut(&id) else { return Some(task) };
        lane.task = Some(task);
        let woken = matches!(lane.phase, Phase::Running { again: true });
        let again = woken
            || match turn {
                LaneTurn::Again => true,
                LaneTurn::WakeAt(due) => due <= Instant::now(),
                LaneTurn::Idle | LaneTurn::Done => false,
            };
        if again {
            // This worker takes it again itself unless another lane is
            // ahead of it, and each of those already has its worker.
            lane.phase = Phase::Ready;
            state.ready.push_back(id);
            return None;
        }
        lane.phase = Phase::Idle;
        if let LaneTurn::WakeAt(due) = turn {
            self.arm(state, id, due);
        }
        None
    }

    /// Arms lane `id`'s deadline. A lane whose armed deadline is no later
    /// keeps it: that turn re-arms the later one, so a deadline that moves
    /// on every turn (a pointer lease) adds no heap entry per turn.
    fn arm(&self, state: &mut PoolState, id: u64, due: Instant) {
        let Some(lane) = state.lanes.get_mut(&id) else { return };
        if lane.armed.is_some_and(|armed| armed <= due) {
            return;
        }
        lane.armed = Some(due);
        lane.timer_generation += 1;
        let generation = lane.timer_generation;
        let earliest = state.timers.peek().is_none_or(|Reverse(head)| due < head.due);
        state.timers.push(Reverse(Timer { due, lane: id, generation }));
        // An idle worker waiting past this deadline computes its wait again.
        if earliest && state.idle > state.waking {
            state.waking += 1;
            self.work.notify_one();
        }
    }

    /// The earliest live deadline, dropping stale heap entries on the way.
    fn next_due(&self, state: &mut PoolState) -> Option<Instant> {
        while let Some(Reverse(head)) = state.timers.peek() {
            if timer_is_live(&state.lanes, head) {
                return Some(head.due);
            }
            state.timers.pop();
        }
        None
    }

    /// Readies the lanes whose deadline passed. Returns the workers to start
    /// for the lanes beyond the one this worker takes.
    fn promote_due(&self, state: &mut PoolState) -> usize {
        let now = Instant::now();
        let mut became_ready = 0;
        while state.timers.peek().is_some_and(|Reverse(head)| head.due <= now) {
            let Some(Reverse(timer)) = state.timers.pop() else { break };
            if !timer_is_live(&state.lanes, &timer) {
                continue;
            }
            let Some(lane) = state.lanes.get_mut(&timer.lane) else { continue };
            lane.armed = None;
            match &mut lane.phase {
                Phase::Running { again } => *again = true,
                Phase::Ready => {}
                Phase::Idle => {
                    lane.phase = Phase::Ready;
                    state.ready.push_back(timer.lane);
                    became_ready += 1;
                }
            }
        }
        (1..became_ready).filter(|_| self.wake_or_reserve(state)).count()
    }

    fn shutdown(&self) {
        let lanes = {
            let mut state = self.lock();
            state.shut_down = true;
            state.ready.clear();
            state.timers.clear();
            std::mem::take(&mut state.lanes)
        };
        self.work.notify_all();
        // Outside the lock: tasks hold surfaces, whose drops take other locks.
        drop(lanes);
    }
}

fn timer_is_live(lanes: &HashMap<u64, Lane>, timer: &Timer) -> bool {
    lanes.get(&timer.lane).is_some_and(|lane| {
        lane.timer_generation == timer.generation && lane.armed == Some(timer.due)
    })
}

/// Takes ready lane `id`'s task and marks it running.
fn take_task(state: &mut PoolState, id: u64) -> Option<Box<dyn LaneTask>> {
    let lane = state.lanes.get_mut(&id)?;
    if lane.phase != Phase::Ready {
        return None;
    }
    let task = lane.task.take()?;
    lane.phase = Phase::Running { again: false };
    Some(task)
}

#[cfg(test)]
#[path = "lanes_tests.rs"]
mod tests;
