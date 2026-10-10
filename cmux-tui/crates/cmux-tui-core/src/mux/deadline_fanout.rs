//! Bounded deadline fanout: a lazily grown worker pool that runs a batch of
//! jobs against one shared deadline and returns completed, pending, or
//! unscheduled results in input order. Cell pixel and kitty budget updates use
//! it so one slow surface cannot stall the rest.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// Most jobs admitted at once (queued plus running), and most worker threads.
pub(super) const CELL_PIXEL_FANOUT_MAX_WORKERS: usize = 32;
const DEADLINE_FANOUT_IDLE_TIMEOUT: Duration = Duration::from_millis(250);

pub(super) type DeadlineFanoutJob = Box<dyn FnOnce() + Send + 'static>;

#[derive(Default)]
pub(super) struct DeadlineFanoutState {
    jobs: VecDeque<DeadlineFanoutJob>,
    worker_count: usize,
    pub(super) admitted_jobs: usize,
    next_worker: u64,
    shutdown: bool,
}

#[derive(Default)]
pub(super) struct DeadlineFanoutInner {
    pub(super) state: Mutex<DeadlineFanoutState>,
    pub(super) changed: Condvar,
}

pub(super) struct DeadlineFanoutPool {
    pub(super) inner: Arc<DeadlineFanoutInner>,
}

impl DeadlineFanoutPool {
    pub(super) fn new() -> Self {
        Self { inner: Arc::new(DeadlineFanoutInner::default()) }
    }

    pub(super) fn submit(&self, job: DeadlineFanoutJob) -> bool {
        self.submit_until(None, job)
    }

    pub(super) fn submit_before(&self, deadline: Instant, job: DeadlineFanoutJob) -> bool {
        self.submit_until(Some(deadline), job)
    }

    fn submit_until(&self, deadline: Option<Instant>, job: DeadlineFanoutJob) -> bool {
        let mut state = self.inner.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if deadline.is_some_and(|deadline| Instant::now() >= deadline)
            || state.shutdown
            || state.admitted_jobs >= CELL_PIXEL_FANOUT_MAX_WORKERS
        {
            return false;
        }

        let active_jobs = state.admitted_jobs.saturating_sub(state.jobs.len());
        let available_workers = state.worker_count.saturating_sub(active_jobs);
        if state.jobs.len() + 1 > available_workers
            && state.worker_count < CELL_PIXEL_FANOUT_MAX_WORKERS
        {
            let worker_index = state.next_worker;
            state.next_worker = state.next_worker.wrapping_add(1);
            state.worker_count += 1;
            let inner = self.inner.clone();
            if std::thread::Builder::new()
                .name(format!("mux-deadline-{worker_index}"))
                .spawn(move || deadline_fanout_worker(inner))
                .is_err()
            {
                state.worker_count -= 1;
                if state.worker_count == 0 {
                    return false;
                }
            }
        }

        // Thread creation can outlive a short shared deadline. Sample time
        // again while queue capacity is still protected by the admission lock.
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            return false;
        }

        state.jobs.push_back(job);
        state.admitted_jobs += 1;
        self.inner.changed.notify_one();
        true
    }
}

impl Drop for DeadlineFanoutPool {
    fn drop(&mut self) {
        let mut state = self.inner.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        state.shutdown = true;
        state.admitted_jobs = state.admitted_jobs.saturating_sub(state.jobs.len());
        state.jobs.clear();
        self.inner.changed.notify_all();
    }
}

fn deadline_fanout_worker(inner: Arc<DeadlineFanoutInner>) {
    loop {
        let job = {
            let mut state = inner.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if state.shutdown {
                state.worker_count = state.worker_count.saturating_sub(1);
                inner.changed.notify_all();
                return;
            }
            let (mut state, _) = inner
                .changed
                .wait_timeout_while(state, DEADLINE_FANOUT_IDLE_TIMEOUT, |state| {
                    !state.shutdown && state.jobs.is_empty()
                })
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if state.shutdown || state.jobs.is_empty() {
                state.worker_count = state.worker_count.saturating_sub(1);
                inner.changed.notify_all();
                return;
            }
            state.jobs.pop_front().expect("deadline fanout queue was checked as non-empty")
        };

        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
        let mut state = inner.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        state.admitted_jobs = state.admitted_jobs.saturating_sub(1);
    }
}

pub(super) struct DeadlinePending<R> {
    pub(super) result: Arc<Mutex<Option<DeadlineCompletion<R>>>>,
}

pub(super) struct DeadlineCompletion<R> {
    pub(super) completed_at: Instant,
    pub(super) value: R,
}

impl<R> DeadlinePending<R> {
    pub(super) fn try_take(&self) -> Option<R> {
        self.result.lock().unwrap().take().map(|completion| completion.value)
    }

    pub(super) fn try_take_before(&self, deadline: Instant) -> Option<R> {
        let mut result = self.result.lock().unwrap();
        if result.as_ref().is_some_and(|completion| completion.completed_at <= deadline) {
            result.take().map(|completion| completion.value)
        } else {
            None
        }
    }
}

pub(super) enum DeadlineMapResult<R> {
    Complete(R),
    Pending(DeadlinePending<R>),
    Unscheduled,
}

pub(super) fn bounded_deadline_map<T, R, F>(
    pool: &DeadlineFanoutPool,
    items: &[T],
    deadline: Instant,
    operation: F,
) -> Vec<DeadlineMapResult<R>>
where
    T: Clone + Send + 'static,
    R: Send + 'static,
    F: Fn(&T, Instant) -> R + Send + Sync + 'static,
{
    if items.is_empty() {
        return Vec::new();
    }

    let mut ordered = std::iter::repeat_with(|| DeadlineMapResult::Unscheduled)
        .take(items.len())
        .collect::<Vec<_>>();
    let operation = Arc::new(operation);
    let (sender, receiver) = std::sync::mpsc::channel();
    let mut submitted = 0;
    for (index, item) in items.iter().cloned().enumerate() {
        if Instant::now() >= deadline {
            break;
        }
        let sender = sender.clone();
        let operation = operation.clone();
        let result = Arc::new(Mutex::new(None));
        let job_result = result.clone();
        let job = Box::new(move || {
            let value = operation(&item, deadline);
            *job_result.lock().unwrap() =
                Some(DeadlineCompletion { completed_at: Instant::now(), value });
            let _ = sender.send(index);
        });
        if pool.submit_before(deadline, job) {
            submitted += 1;
            ordered[index] = DeadlineMapResult::Pending(DeadlinePending { result });
        }
    }
    drop(sender);

    while submitted > 0 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match receiver.recv_timeout(remaining) {
            Ok(index) => {
                let pending =
                    std::mem::replace(&mut ordered[index], DeadlineMapResult::Unscheduled);
                match pending {
                    DeadlineMapResult::Pending(pending) => {
                        if let Some(result) = pending.try_take_before(deadline) {
                            ordered[index] = DeadlineMapResult::Complete(result);
                            submitted -= 1;
                        } else {
                            ordered[index] = DeadlineMapResult::Pending(pending);
                        }
                    }
                    result => ordered[index] = result,
                }
            }
            Err(_) => break,
        }
    }
    for result in &mut ordered {
        let completed = match result {
            DeadlineMapResult::Pending(pending) => pending.try_take_before(deadline),
            DeadlineMapResult::Complete(_) | DeadlineMapResult::Unscheduled => None,
        };
        if let Some(completed) = completed {
            *result = DeadlineMapResult::Complete(completed);
        }
    }
    ordered
}
