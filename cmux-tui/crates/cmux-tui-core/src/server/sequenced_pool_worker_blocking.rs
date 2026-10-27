//! A sequenced pool worker's blocking observer (sequenced_pool.rs,
//! "Blocking compensation"): the blocking sites of a task tell the worker's
//! priority it is blocked, so the priority starts a temporary worker.

use std::cell::{Cell, RefCell};
use std::sync::Arc;

use crate::request_path::{BlockingKind, BlockingObserver, set_blocking_observer};

use super::{SequencePriority, Shared};

/// Makes this thread worker `priority` of `shared` until the returned guard
/// drops: its blocking sites report to that priority.
pub(super) fn enter_worker(shared: Arc<Shared>, priority: SequencePriority) -> ClearWorker {
    WORKER.with(|worker| *worker.borrow_mut() = Some((shared, priority)));
    set_blocking_observer(Some(&WORKER_OBSERVER));
    ClearWorker
}

thread_local! {
    /// The pool and priority of the worker this thread is.
    static WORKER: RefCell<Option<(Arc<Shared>, SequencePriority)>> = const { RefCell::new(None) };
    /// `request_path::will_block` scopes open on this worker's task.
    static SCOPES: Cell<usize> = const { Cell::new(0) };
    /// This worker's task noted a blocking kind: blocked until it ends.
    static TASK_BLOCKED: Cell<bool> = const { Cell::new(false) };
}

/// Every worker's `request_path::BlockingObserver`: it reads the worker it
/// runs on from [`WORKER`].
struct WorkerObserver;

static WORKER_OBSERVER: WorkerObserver = WorkerObserver;

impl WorkerObserver {
    fn blocked() -> bool {
        SCOPES.with(Cell::get) > 0 || TASK_BLOCKED.with(Cell::get)
    }

    fn worker() -> Option<(Arc<Shared>, SequencePriority)> {
        WORKER.try_with(|worker| worker.borrow().clone()).ok().flatten()
    }
}

impl BlockingObserver for WorkerObserver {
    fn noted(&self, _kind: BlockingKind) {
        if TASK_BLOCKED.with(Cell::get) {
            return;
        }
        let was_blocked = Self::blocked();
        TASK_BLOCKED.with(|blocked| blocked.set(true));
        if !was_blocked && let Some((shared, priority)) = Self::worker() {
            shared.enter_blocked(priority);
        }
    }

    fn scope_started(&self) {
        let was_blocked = Self::blocked();
        SCOPES.with(|scopes| scopes.set(scopes.get() + 1));
        if !was_blocked && let Some((shared, priority)) = Self::worker() {
            shared.enter_blocked(priority);
        }
    }

    fn scope_ended(&self) {
        SCOPES.with(|scopes| scopes.set(scopes.get().saturating_sub(1)));
        if !Self::blocked()
            && let Some((shared, priority)) = Self::worker()
        {
            shared.leave_blocked(priority);
        }
    }
}

/// Ends the blocked state a finished task's note left (its scopes ended
/// with it).
pub(super) fn end_task_block(shared: &Shared, priority: SequencePriority) {
    if TASK_BLOCKED.with(|blocked| blocked.replace(false)) && SCOPES.with(Cell::get) == 0 {
        shared.leave_blocked(priority);
    }
}

/// Ends the thread's worker registration when its worker loop returns.
pub(super) struct ClearWorker;

impl Drop for ClearWorker {
    fn drop(&mut self) {
        set_blocking_observer(None);
        let _ = WORKER.try_with(|worker| worker.borrow_mut().take());
    }
}
