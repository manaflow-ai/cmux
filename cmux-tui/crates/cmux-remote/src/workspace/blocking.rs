use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_remote_protocol::RpcError;
use tokio::sync::{Notify, OwnedSemaphorePermit, Semaphore, oneshot};

const MAX_WORKSPACE_BLOCKING_JOBS: usize = 4;

/// Bounds workspace work whose futures contain long synchronous CPU sections.
///
/// The daemon's service handlers run on a `LocalSet` so they can preserve
/// per-stream ordering without making every handler `Send`. Polling a large
/// diff parser or search scanner on that thread would also stop terminal and
/// mux-control polling. These jobs instead own all of their inputs and poll on
/// a Tokio blocking worker. A permit lives in the worker closure, so dropping a
/// canceled caller cannot accidentally exceed the concurrency bound while the
/// non-preemptible work drains.
#[derive(Clone)]
pub(crate) struct WorkspaceBlockingPool {
    slots: Arc<Semaphore>,
    lifecycle: Arc<BlockingLifecycle>,
}

#[derive(Default)]
struct BlockingLifecycle {
    state: Mutex<BlockingLifecycleState>,
    changed: Notify,
}

#[derive(Default)]
struct BlockingLifecycleState {
    closing: bool,
    active: usize,
}

struct JobRegistration {
    lifecycle: Arc<BlockingLifecycle>,
}

struct CompletedBlockingJob<T> {
    result: Option<Result<T, RpcError>>,
    permit: Option<OwnedSemaphorePermit>,
    registration: Option<JobRegistration>,
}

impl<T> CompletedBlockingJob<T> {
    fn new(
        result: Result<T, RpcError>,
        permit: OwnedSemaphorePermit,
        registration: JobRegistration,
    ) -> Self {
        Self { result: Some(result), permit: Some(permit), registration: Some(registration) }
    }

    fn into_result(mut self) -> Result<T, RpcError> {
        let result = self.result.take().expect("blocking job result remains present");
        drop(self.registration.take());
        drop(self.permit.take());
        result
    }
}

impl<T> Drop for CompletedBlockingJob<T> {
    fn drop(&mut self) {
        // Stateful results can own rollback guards. Release those before
        // another job acquires this slot and observes the guarded state.
        drop(self.result.take());
        drop(self.registration.take());
        drop(self.permit.take());
    }
}

impl Drop for JobRegistration {
    fn drop(&mut self) {
        let mut state =
            self.lifecycle.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.active = state.active.saturating_sub(1);
        drop(state);
        // `notify_one` retains a permit if drain has created but not yet
        // polled its waiter, avoiding a lost completion wakeup.
        self.lifecycle.changed.notify_one();
    }
}

impl Default for WorkspaceBlockingPool {
    fn default() -> Self {
        let parallelism = std::thread::available_parallelism().map_or(2, usize::from);
        // Leave one logical CPU out of this pool's concurrency budget when
        // possible, preserving scheduler capacity for latency-sensitive work.
        let jobs = parallelism.saturating_sub(1).clamp(1, MAX_WORKSPACE_BLOCKING_JOBS);
        Self {
            slots: Arc::new(Semaphore::new(jobs)),
            lifecycle: Arc::new(BlockingLifecycle::default()),
        }
    }
}

impl WorkspaceBlockingPool {
    pub(crate) async fn run<T, F>(&self, operation: &'static str, job: F) -> Result<T, RpcError>
    where
        T: Send + 'static,
        F: FnOnce() -> Result<T, RpcError> + Send + 'static,
    {
        let registration = {
            let mut state =
                self.lifecycle.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.closing {
                return Err(RpcError::new(
                    "session-closed",
                    "workspace blocking executor is shutting down",
                ));
            }
            state.active = state.active.saturating_add(1);
            JobRegistration { lifecycle: self.lifecycle.clone() }
        };
        let permit = self.slots.clone().acquire_owned().await.map_err(|_| {
            RpcError::new("session-closed", "workspace blocking executor is shutting down")
        })?;
        let (completed_tx, completed_rx) = oneshot::channel();
        let worker = tokio::task::spawn_blocking(move || {
            // Move admission into the result so a canceled receiver drops any
            // rollback guard before releasing this worker slot.
            drop(completed_tx.send(CompletedBlockingJob::new(job(), permit, registration)));
        });
        let result = match completed_rx.await {
            Ok(result) => result,
            Err(_) => {
                return match worker.await {
                    Ok(()) => Err(RpcError::new(
                        "internal",
                        format!("workspace {operation} worker returned no result"),
                    )),
                    Err(error) => Err(RpcError::new(
                        "internal",
                        format!("workspace {operation} worker failed: {error}"),
                    )),
                };
            }
        };
        worker.await.map_err(|error| {
            RpcError::new("internal", format!("workspace {operation} worker failed: {error}"))
        })?;
        result.into_result()
    }

    pub(crate) async fn run_async<T, F, Fut>(
        &self,
        operation: &'static str,
        job: F,
    ) -> Result<T, RpcError>
    where
        T: Send + 'static,
        F: FnOnce() -> Fut + Send + 'static,
        Fut: Future<Output = Result<T, RpcError>> + 'static,
    {
        let runtime = tokio::runtime::Handle::current();
        self.run(operation, move || runtime.block_on(job())).await
    }

    /// Prevent new jobs and wait up to `timeout` for already admitted work.
    /// The returned count remains registered and will decrement when detached
    /// blocking workers eventually finish.
    pub(crate) async fn close_and_drain(&self, timeout: Duration) -> usize {
        {
            let mut state =
                self.lifecycle.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            state.closing = true;
        }
        self.slots.close();
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let changed = self.lifecycle.changed.notified();
            let active = self
                .lifecycle
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .active;
            if active == 0 {
                return 0;
            }
            if tokio::time::timeout_at(deadline, changed).await.is_err() {
                return self
                    .lifecycle
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .active;
            }
        }
    }

    pub(crate) fn with_jobs(jobs: usize) -> Self {
        Self {
            slots: Arc::new(Semaphore::new(jobs.max(1))),
            lifecycle: Arc::new(BlockingLifecycle::default()),
        }
    }
}
