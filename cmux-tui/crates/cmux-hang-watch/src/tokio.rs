//! Hang watch for tokio multi-thread runtimes (p09-observability task 118, section 3E): a scheduler
//! worker blocked in one call (a `std::thread::sleep`, a sync lock, a file read) for
//! [`WORKER_DEADLINE`] gives one hang record that names the worker.
//!
//! Chrome watches its thread-pool workers with one `WatchHangsInScope` per task
//! (base/task/thread_pool/worker_thread.cc, `RunWorker`). Release tokio has no hook between task
//! polls (`on_before_task_poll` needs `tokio_unstable`, and the `park_yield` of a `yield_now` or of
//! the scheduler's maintenance runs no hook), so a busy worker runs many polls inside one
//! unpark-to-park period. That period is a running scope ([`crate::Guard::watch_running`]): its
//! deadline moves while the worker gets CPU time, so a busy worker running short polls is not
//! blamed and a worker blocked in one call is. [`WorkerHooks`] supplies tokio's four thread hooks:
//!
//! - `on_thread_start` registers the thread with the process watch ([`crate::register_thread`],
//!   [`ThreadKind::Pool`]). Tokio runs it on blocking-pool threads too, so work there opens scopes
//!   with [`crate::watch`] on that registration and never registers again.
//! - `on_thread_unpark` opens the [`WORKER_DEADLINE`] running scope and starts a busy period.
//!   Tokio calls it only on scheduler workers, so a worker's run before its first park is not
//!   watched.
//! - `on_thread_park` closes the scope and adds the busy period to `runtime.busy_ms`
//!   ([`crate::Stats::runtime_busy_ms`] for the process, [`WorkerHooks::busy`] for the runtime).
//! - `on_thread_stop` closes and unregisters before the thread exits.
//!
//! A worker that runs a task's blocking call through [`block_in_place`] (feature `tokio`) hands its
//! queue to another thread, so the runtime is not stalled: that wait is not blamed, and its busy
//! period ends there.
//!
//! Before [`crate::init`] the registration is inert and the park and unpark hooks do nothing more
//! than a thread-local read. Opening and closing a scope takes no lock, allocation or system call.

use std::cell::RefCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::Duration;

use crate::{Guard, Scope, ThreadKind};

/// How long a tokio worker may go without CPU time between an unpark and its next park.
pub const WORKER_DEADLINE: Duration = Duration::from_secs(2);

/// One runtime's `runtime.busy_ms`.
#[derive(Debug, Default)]
struct Busy {
    ns: AtomicU64,
    periods: AtomicU64,
}

/// One runtime's busy time so far ([`WorkerHooks::busy`]).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RuntimeBusy {
    /// Time its workers ran between an unpark and the next park (or a [`block_in_place`]).
    pub busy_ms: u64,
    /// The busy periods summed in `busy_ms`.
    pub periods: u64,
}

/// The hooks of one runtime. Tokio keeps one hook of each kind: a runtime builder takes them with
/// [`instrument`] or [`WorkerHooks::apply`], and a builder that has its own hooks
/// (`cmux_blocking::ThreadHooks`) calls these from its own.
#[derive(Clone)]
pub struct WorkerHooks {
    runtime: Arc<str>,
    started: Arc<AtomicU32>,
    busy: Arc<Busy>,
}

impl WorkerHooks {
    /// Hooks for the runtime `runtime` (a catalog name): its threads register as `<runtime>-<n>`,
    /// `n` counting the threads it started.
    pub fn new(runtime: &str) -> WorkerHooks {
        WorkerHooks {
            runtime: Arc::from(runtime),
            started: Arc::new(AtomicU32::new(0)),
            busy: Arc::default(),
        }
    }

    /// This runtime's busy time so far (0 before [`crate::init`]).
    pub fn busy(&self) -> RuntimeBusy {
        RuntimeBusy {
            busy_ms: self.busy.ns.load(Ordering::Relaxed) / 1_000_000,
            periods: self.busy.periods.load(Ordering::Relaxed),
        }
    }

    /// Sets the four hooks on `builder`, replacing any it had. Call it before `build`: threads the
    /// runtime starts before [`crate::init`] are not watched.
    #[cfg(feature = "tokio")]
    pub fn apply<'b>(
        &self,
        builder: &'b mut ::tokio::runtime::Builder,
    ) -> &'b mut ::tokio::runtime::Builder {
        builder
            .on_thread_start(self.on_thread_start())
            .on_thread_unpark(self.on_thread_unpark())
            .on_thread_park(self.on_thread_park())
            .on_thread_stop(self.on_thread_stop())
    }

    /// Tokio's `on_thread_start`: every runtime thread, workers and blocking-pool threads alike.
    pub fn on_thread_start(&self) -> impl Fn() + Send + Sync + 'static {
        let hooks = self.clone();
        move || hooks.thread_started()
    }

    /// Tokio's `on_thread_unpark`: a scheduler worker that unparked.
    pub fn on_thread_unpark(&self) -> impl Fn() + Send + Sync + 'static {
        worker_unparked
    }

    /// Tokio's `on_thread_park`: a scheduler worker about to park.
    pub fn on_thread_park(&self) -> impl Fn() + Send + Sync + 'static {
        worker_parked
    }

    /// Tokio's `on_thread_stop`.
    pub fn on_thread_stop(&self) -> impl Fn() + Send + Sync + 'static {
        thread_stopped
    }

    fn thread_started(&self) {
        let index = self.started.fetch_add(1, Ordering::Relaxed);
        let name = format!("{}-{index}", self.runtime);
        let _ = RUNTIME_THREAD.try_with(|cell| {
            let mut thread = cell.borrow_mut();
            if thread.guard.is_none() {
                thread.guard = Some(crate::register_thread(ThreadKind::Pool, &name));
                thread.busy = Some(Arc::clone(&self.busy));
            }
        });
    }
}

/// A runtime thread's registration, its open worker scope and its busy period.
struct RuntimeThread {
    /// Declared before `guard`, so it closes first when the thread's locals drop.
    scope: Option<Scope<'static>>,
    /// When the busy period began (the unpark), on the watch's clock; None outside one.
    busy_since: Option<u64>,
    /// The runtime's `runtime.busy_ms`.
    busy: Option<Arc<Busy>>,
    guard: Option<Guard<'static>>,
}

impl RuntimeThread {
    /// Ends the busy period, if one runs, and counts it.
    fn end_busy(&mut self) {
        let Some(since) = self.busy_since.take() else { return };
        let Some(guard) = &self.guard else { return };
        let Some(now_ns) = guard.now_ns() else { return };
        let ns = now_ns.saturating_sub(since);
        guard.add_runtime_busy(ns);
        if let Some(busy) = &self.busy {
            busy.ns.fetch_add(ns, Ordering::Relaxed);
            busy.periods.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Ends the busy period and closes the worker scope.
    fn park(&mut self) {
        self.end_busy();
        self.scope = None;
    }
}

thread_local! {
    static RUNTIME_THREAD: RefCell<RuntimeThread> = const {
        RefCell::new(RuntimeThread { scope: None, busy_since: None, busy: None, guard: None })
    };
}

fn worker_unparked() {
    let _ = RUNTIME_THREAD.try_with(|cell| {
        let mut thread = cell.borrow_mut();
        if !thread.guard.as_ref().is_some_and(Guard::is_registered) {
            return;
        }
        // A scope still open lost its park: the thread left its worker loop in `block_in_place`
        // and now runs a worker again. The new scope must not nest in that stale one.
        thread.park();
        let RuntimeThread { scope, busy_since, guard: Some(guard), .. } = &mut *thread else {
            return;
        };
        *busy_since = guard.now_ns();
        *scope = Some(guard.watch_running(WORKER_DEADLINE));
    });
}

fn worker_parked() {
    let _ = RUNTIME_THREAD.try_with(|cell| cell.borrow_mut().park());
}

fn thread_stopped() {
    let _ = RUNTIME_THREAD.try_with(|cell| {
        let mut thread = cell.borrow_mut();
        thread.park();
        thread.guard = None;
    });
}

/// Sets the four hooks of [`WorkerHooks`] for the runtime `runtime` on `builder`, replacing any it
/// had. Call it before `build`: threads the runtime starts before [`crate::init`] are not watched.
#[cfg(feature = "tokio")]
pub fn instrument<'b>(
    builder: &'b mut ::tokio::runtime::Builder,
    runtime: &str,
) -> &'b mut ::tokio::runtime::Builder {
    WorkerHooks::new(runtime).apply(builder)
}

/// `tokio::task::block_in_place` that the hang watch does not blame: tokio hands the worker's queue
/// to another thread for the call, so the runtime keeps running while this thread waits. The
/// thread's scopes stop being watched until the outermost closes ([`crate::invalidate_active`],
/// Chrome's `HangWatcher::InvalidateActiveExpectations`), and its busy period ends here: after the
/// call the thread may idle in the blocking pool, and its next unpark starts the next period.
#[cfg(feature = "tokio")]
pub fn block_in_place<R>(f: impl FnOnce() -> R) -> R {
    let _ = RUNTIME_THREAD.try_with(|cell| cell.borrow_mut().end_busy());
    crate::invalidate_active();
    ::tokio::task::block_in_place(f)
}
