//! One shared executor for per-entity serial work (perf100 tui lane).
//!
//! The daemon used to give every terminal and browser surface its own thread
//! that slept until that entity had work ("thread per entity"): 1743 threads
//! in one Chief daemon with 335 terminals and 353 browser surfaces on
//! 2026-10-20. A [`Lane`] replaces such a thread. It owns a run function,
//! and the executor calls it on one of a few shared worker threads when the
//! lane is kicked or its deadline arrives:
//!
//! - Serial: one lane's run function never runs on two threads at once, and a
//!   kick while it runs makes it run once more after it returns, so no kick is
//!   lost.
//! - Deadlines: the run function returns [`LaneNext::At`] to run again at an
//!   instant (a cadence, a lifecycle deadline). One worker waits for the
//!   earliest deadline of every lane; a kick before the deadline runs the lane
//!   at once and drops the deadline.
//! - Elastic workers: a ready lane with no idle worker gets a new worker, so
//!   a run function that blocks (a CDP round trip) never stalls other lanes.
//!   Workers beyond the first exit after [`IDLE_WORKER_EXIT`] without work.
//!   Threads therefore grow with the work in flight, never with the number
//!   of lanes, and an idle daemon keeps one worker blocked with no timeout.

use std::cmp::Reverse;
use std::collections::{BinaryHeap, VecDeque};
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How long a worker beyond the first waits for work before it exits.
const IDLE_WORKER_EXIT: Duration = Duration::from_secs(10);
/// Upper bound on workers; a ready lane past it waits for a free worker.
const MAX_WORKERS: usize = 512;

/// What a lane's run function wants next.
pub(crate) enum LaneNext {
    /// Run again only when kicked.
    Idle,
    /// Run again at this instant (or sooner, when kicked).
    At(Instant),
    /// Never run again; later kicks do nothing.
    Close,
}

type RunFn = Box<dyn FnMut() -> LaneNext + Send>;

const IDLE: u8 = 0;
const WAITING: u8 = 1;
const QUEUED: u8 = 2;
const RUNNING: u8 = 3;
const KICKED: u8 = 4;
const CLOSED: u8 = 5;

struct LaneShared {
    status: AtomicU8,
    /// Generation of the lane's current deadline; a heap entry with an older
    /// one is stale (the lane was kicked or rescheduled since).
    deadline_generation: AtomicU64,
    run: Mutex<RunFn>,
    name: &'static str,
}

/// A serial unit of work on the shared executor; see the module docs.
/// Dropping the last handle while the lane is idle frees it; a queued or
/// waiting lane is freed after its next run.
#[derive(Clone)]
pub(crate) struct Lane(Arc<LaneShared>);

impl Lane {
    /// A new idle lane; it first runs at the first [`Lane::kick`]. `name`
    /// labels a panic in its run function.
    pub(crate) fn new(name: &'static str, run: impl FnMut() -> LaneNext + Send + 'static) -> Self {
        Lane(Arc::new(LaneShared {
            status: AtomicU8::new(IDLE),
            deadline_generation: AtomicU64::new(0),
            run: Mutex::new(Box::new(run)),
            name,
        }))
    }

    /// Run the lane's function soon: at once when idle or waiting for a
    /// deadline, again after the current run when running.
    pub(crate) fn kick(&self) {
        let status = &self.0.status;
        let mut current = status.load(Ordering::Acquire);
        loop {
            let next = match current {
                IDLE | WAITING => QUEUED,
                RUNNING => KICKED,
                _ => return,
            };
            if current == WAITING {
                // Invalidate the pending deadline entry before taking the
                // lane, so a deadline the next run sets is never the one
                // invalidated.
                self.0.deadline_generation.fetch_add(1, Ordering::AcqRel);
            }
            match status.compare_exchange_weak(current, next, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => {
                    if next == QUEUED {
                        executor().push_ready(self.0.clone());
                    }
                    return;
                }
                Err(actual) => current = actual,
            }
        }
    }

    /// Never run the lane again; a run in progress finishes.
    pub(crate) fn close(&self) {
        self.0.status.store(CLOSED, Ordering::Release);
        self.0.deadline_generation.fetch_add(1, Ordering::AcqRel);
    }
}

struct TimerEntry {
    at: Instant,
    order: u64,
    generation: u64,
    lane: Arc<LaneShared>,
}

impl PartialEq for TimerEntry {
    fn eq(&self, other: &Self) -> bool {
        (self.at, self.order) == (other.at, other.order)
    }
}
impl Eq for TimerEntry {}
impl PartialOrd for TimerEntry {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for TimerEntry {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        (self.at, self.order).cmp(&(other.at, other.order))
    }
}

#[derive(Default)]
struct Inner {
    ready: VecDeque<Arc<LaneShared>>,
    timers: BinaryHeap<Reverse<TimerEntry>>,
    next_order: u64,
    workers: usize,
    /// Workers parked on `work` with nothing to do.
    idle: usize,
    /// The deadline the timer worker sleeps until, while one does.
    timer_wait: Option<Instant>,
}

struct Executor {
    inner: Mutex<Inner>,
    /// Idle workers wait here for ready lanes.
    work: Condvar,
    /// The one timer worker waits here for the earliest deadline.
    timer: Condvar,
}

fn executor() -> &'static Executor {
    static EXECUTOR: OnceLock<Executor> = OnceLock::new();
    EXECUTOR.get_or_init(|| Executor {
        inner: Mutex::new(Inner::default()),
        work: Condvar::new(),
        timer: Condvar::new(),
    })
}

impl Executor {
    fn push_ready(&'static self, lane: Arc<LaneShared>) {
        let mut inner = self.inner.lock().unwrap();
        inner.ready.push_back(lane);
        self.wake_for_ready(&mut inner);
    }

    fn push_timer(&'static self, lane: Arc<LaneShared>, at: Instant, generation: u64) {
        let mut inner = self.inner.lock().unwrap();
        let order = inner.next_order;
        inner.next_order += 1;
        inner.timers.push(Reverse(TimerEntry { at, order, generation, lane }));
        match inner.timer_wait {
            // The timer worker sleeps past this deadline: wake it to re-arm.
            Some(wait) if at < wait => self.timer.notify_one(),
            Some(_) => {}
            None if inner.idle > 0 => self.work.notify_one(),
            None => self.spawn_worker(&mut inner),
        }
    }

    /// Make sure a worker will take every ready lane soon: wake idle ones
    /// (a woken worker still counts as idle until it resumes, so compare
    /// with the queue length), else the timer worker, else start one.
    fn wake_for_ready(&'static self, inner: &mut Inner) {
        let waiting = inner.ready.len();
        if waiting <= inner.idle {
            self.work.notify_one();
        } else if inner.timer_wait.is_some() && waiting <= inner.idle + 1 {
            // The timer worker takes the lane and hands the timer role on.
            self.timer.notify_one();
        } else {
            self.spawn_worker(inner);
        }
    }

    /// Before a worker runs a lane (which may block): the rest of the ready
    /// queue and the timers still need a worker.
    fn cover_while_running(&'static self, inner: &mut Inner) {
        if !inner.ready.is_empty() {
            self.wake_for_ready(inner);
        }
        if inner.timer_wait.is_none() && !inner.timers.is_empty() {
            if inner.idle > inner.ready.len() {
                self.work.notify_one();
            } else {
                self.spawn_worker(inner);
            }
        }
    }

    fn spawn_worker(&'static self, inner: &mut Inner) {
        if inner.workers >= MAX_WORKERS {
            return;
        }
        inner.workers += 1;
        let spawned =
            std::thread::Builder::new().name("serial-lanes".into()).spawn(move || self.work_loop());
        if spawned.is_err() {
            inner.workers -= 1;
        }
    }

    /// Move due, still-valid timer entries to the ready queue.
    fn fire_due(inner: &mut Inner, now: Instant) {
        while inner.timers.peek().is_some_and(|Reverse(entry)| entry.at <= now) {
            let Reverse(entry) = inner.timers.pop().expect("peeked");
            let lane = entry.lane;
            if lane.deadline_generation.load(Ordering::Acquire) != entry.generation {
                continue;
            }
            if lane
                .status
                .compare_exchange(WAITING, QUEUED, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                inner.ready.push_back(lane);
            }
        }
    }

    fn work_loop(&'static self) {
        struct WorkerExit(&'static Executor);
        impl Drop for WorkerExit {
            fn drop(&mut self) {
                let mut inner = self.0.inner.lock().unwrap();
                inner.workers -= 1;
                // A worker that died in a run function may have been the
                // only one able to serve a ready lane or the timers.
                if !inner.ready.is_empty() || !inner.timers.is_empty() {
                    if inner.idle > 0 {
                        self.0.work.notify_one();
                    } else if inner.timer_wait.is_none() {
                        self.0.spawn_worker(&mut inner);
                    }
                }
            }
        }
        let _exit = WorkerExit(self);
        let mut inner = self.inner.lock().unwrap();
        loop {
            Self::fire_due(&mut inner, Instant::now());
            if let Some(lane) = inner.ready.pop_front() {
                self.cover_while_running(&mut inner);
                drop(inner);
                run_lane(lane);
                inner = self.inner.lock().unwrap();
                continue;
            }
            if inner.timer_wait.is_none()
                && let Some(Reverse(next)) = inner.timers.peek()
            {
                let at = next.at;
                inner.timer_wait = Some(at);
                let timeout = at.saturating_duration_since(Instant::now());
                let (guard, _) = self.timer.wait_timeout(inner, timeout).unwrap();
                inner = guard;
                inner.timer_wait = None;
                continue;
            }
            inner.idle += 1;
            let keep = inner.workers == 1;
            if keep {
                inner = self.work.wait(inner).unwrap();
                inner.idle -= 1;
            } else {
                let (guard, timeout) = self.work.wait_timeout(inner, IDLE_WORKER_EXIT).unwrap();
                inner = guard;
                inner.idle -= 1;
                if timeout.timed_out()
                    && inner.ready.is_empty()
                    && (inner.timer_wait.is_some() || inner.timers.is_empty())
                {
                    return;
                }
            }
        }
    }
}

/// Run one queued lane, then settle its status from the result.
fn run_lane(lane: Arc<LaneShared>) {
    if lane.status.compare_exchange(QUEUED, RUNNING, Ordering::AcqRel, Ordering::Acquire).is_err()
    {
        return; // closed while queued
    }
    struct ClosedOnPanic<'a>(&'a LaneShared, bool);
    impl Drop for ClosedOnPanic<'_> {
        fn drop(&mut self) {
            if !self.1 {
                self.0.status.store(CLOSED, Ordering::Release);
                // Drop what the run function owns now, as a dead thread
                // would have: a channel receiver it held disconnects its
                // senders instead of filling up unread.
                let dead: RunFn = Box::new(|| LaneNext::Close);
                drop(std::mem::replace(
                    &mut *self.0.run.lock().unwrap_or_else(|poison| poison.into_inner()),
                    dead,
                ));
                let _ = std::io::Write::write_fmt(
                    &mut std::io::stderr(),
                    format_args!("serial lane {} panicked; it will not run again\n", self.0.name),
                );
            }
        }
    }
    let mut guard = ClosedOnPanic(&lane, false);
    let next = {
        let mut run = lane.run.lock().unwrap_or_else(|poison| poison.into_inner());
        (*run)()
    };
    guard.1 = true;
    drop(guard);
    let executor = executor();
    match next {
        LaneNext::Close => lane.status.store(CLOSED, Ordering::Release),
        LaneNext::Idle => {
            if lane
                .status
                .compare_exchange(RUNNING, IDLE, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
            {
                requeue_kicked(lane, executor);
            }
        }
        LaneNext::At(at) => {
            let generation = lane.deadline_generation.fetch_add(1, Ordering::AcqRel) + 1;
            if lane
                .status
                .compare_exchange(RUNNING, WAITING, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                executor.push_timer(lane, at, generation);
            } else {
                requeue_kicked(lane, executor);
            }
        }
    }
}

/// The lane was kicked (or closed) while it ran.
fn requeue_kicked(lane: Arc<LaneShared>, executor: &'static Executor) {
    if lane.status.compare_exchange(KICKED, QUEUED, Ordering::AcqRel, Ordering::Acquire).is_ok() {
        executor.push_ready(lane);
    }
}
