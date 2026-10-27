//! Hang watch for tokio multi-thread runtimes (p09-observability task 118, section 3E): a scheduler
//! worker that does not park within [`WORKER_DEADLINE`] of unparking is hung, so one task that
//! blocks its worker (a `std::thread::sleep`, a sync lock, a file read) gives one hang record that
//! names the worker.
//!
//! Chrome watches its thread-pool workers the same way (base/task/thread_pool/worker_thread.cc):
//! `RunWorker` registers the thread with `HangWatcher::RegisterThread(kThreadPoolThread)` and holds a
//! `WatchHangsInScope` while it runs work, reset before it waits for more. Tokio gives the same
//! three points as runtime hooks, which [`WorkerHooks`] supplies:
//!
//! - `on_thread_start` registers the thread with the process watch ([`crate::register_thread`],
//!   [`ThreadKind::Pool`]). Tokio runs it on blocking-pool threads too, so work there opens scopes
//!   with [`crate::watch`] on that registration and never registers again.
//! - `on_thread_unpark` opens a [`WORKER_DEADLINE`] scope. Tokio calls it only on scheduler workers,
//!   so a worker's run before its first park is not watched.
//! - `on_thread_park` closes the scope and adds the busy period to [`crate::Stats::runtime_busy_ms`].
//! - `on_thread_stop` closes and unregisters before the thread exits.
//!
//! A worker that runs a task's blocking call through [`block_in_place`] (feature `tokio`) hands its
//! queue to another thread, so the runtime is not stalled: that wait is not blamed.
//!
//! Before [`crate::init`] the registration is inert and the park and unpark hooks do nothing more
//! than a thread-local read. Opening and closing a scope takes no lock, allocation or system call.

use std::cell::RefCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use crate::{Guard, Scope, ThreadKind};

/// How long a tokio worker may run between an unpark and its next park.
pub const WORKER_DEADLINE: Duration = Duration::from_secs(2);

/// The hooks of one runtime. Tokio keeps one hook of each kind: a runtime builder takes them with
/// [`instrument`], and a builder that has its own hooks (`cmux_blocking::ThreadHooks`) calls these
/// from its own.
#[derive(Clone)]
pub struct WorkerHooks {
    runtime: Arc<str>,
    started: Arc<AtomicU32>,
}

impl WorkerHooks {
    /// Hooks for the runtime `runtime` (a catalog name): its threads register as `<runtime>-<n>`,
    /// `n` counting the threads it started.
    pub fn new(runtime: &str) -> WorkerHooks {
        WorkerHooks { runtime: Arc::from(runtime), started: Arc::new(AtomicU32::new(0)) }
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
            }
        });
    }
}

/// A runtime thread's registration and its open worker scope.
struct RuntimeThread {
    /// Declared before `guard`, so it closes first when the thread's locals drop.
    scope: Option<Scope<'static>>,
    /// When `scope` opened, on the watch's clock.
    unparked_ns: u64,
    guard: Option<Guard<'static>>,
}

impl RuntimeThread {
    /// Closes the worker scope and counts the time since it opened as busy.
    fn close_scope(&mut self) {
        if self.scope.take().is_none() {
            return;
        }
        if let Some(guard) = &self.guard
            && let Some(now_ns) = guard.now_ns()
        {
            guard.add_runtime_busy(now_ns.saturating_sub(self.unparked_ns));
        }
    }
}

thread_local! {
    static RUNTIME_THREAD: RefCell<RuntimeThread> = const {
        RefCell::new(RuntimeThread { scope: None, unparked_ns: 0, guard: None })
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
        thread.close_scope();
        let RuntimeThread { scope, unparked_ns, guard: Some(guard) } = &mut *thread else { return };
        *unparked_ns = guard.now_ns().unwrap_or(0);
        *scope = Some(guard.watch(WORKER_DEADLINE));
    });
}

fn worker_parked() {
    let _ = RUNTIME_THREAD.try_with(|cell| cell.borrow_mut().close_scope());
}

fn thread_stopped() {
    let _ = RUNTIME_THREAD.try_with(|cell| {
        let mut thread = cell.borrow_mut();
        thread.close_scope();
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
    let hooks = WorkerHooks::new(runtime);
    builder
        .on_thread_start(hooks.on_thread_start())
        .on_thread_unpark(hooks.on_thread_unpark())
        .on_thread_park(hooks.on_thread_park())
        .on_thread_stop(hooks.on_thread_stop())
}

/// `tokio::task::block_in_place` that the hang watch does not blame: tokio hands the worker's queue
/// to another thread for the call, so the runtime keeps running while this thread waits. The
/// thread's scopes stop being watched until the outermost closes ([`crate::invalidate_active`],
/// Chrome's `HangWatcher::InvalidateActiveExpectations`), at its next park.
#[cfg(feature = "tokio")]
pub fn block_in_place<R>(f: impl FnOnce() -> R) -> R {
    crate::invalidate_active();
    ::tokio::task::block_in_place(f)
}
