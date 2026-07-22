use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_remote_protocol::RpcError;
use tokio::sync::{Notify, Semaphore};

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
    #[cfg(test)]
    before_job: Option<Arc<dyn Fn() + Send + Sync>>,
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
            #[cfg(test)]
            before_job: None,
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
        #[cfg(test)]
        let before_job = self.before_job.clone();
        tokio::task::spawn_blocking(move || {
            // Keep admission charged even if the awaiting request is canceled.
            let _permit = permit;
            let _registration = registration;
            #[cfg(test)]
            if let Some(before_job) = before_job {
                before_job();
            }
            job()
        })
        .await
        .map_err(|error| {
            RpcError::new("internal", format!("workspace {operation} worker failed: {error}"))
        })?
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
            #[cfg(test)]
            before_job: None,
        }
    }

    #[cfg(test)]
    pub(crate) fn with_hook(jobs: usize, before_job: Arc<dyn Fn() + Send + Sync>) -> Self {
        let mut pool = Self::with_jobs(jobs);
        pool.before_job = Some(before_job);
        pool
    }
}

#[cfg(test)]
mod tests {
    use std::task::Poll;

    use tokio::sync::oneshot;

    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn drain_tracks_a_worker_after_its_awaiting_request_is_aborted() {
        let pool = WorkspaceBlockingPool::with_jobs(1);
        let gate = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
        let (entered_tx, entered_rx) = oneshot::channel();
        let worker = {
            let pool = pool.clone();
            let gate = gate.clone();
            tokio::spawn(async move {
                pool.run("test", move || {
                    let _ = entered_tx.send(());
                    let (released, changed) = &*gate;
                    let released =
                        released.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    drop(
                        changed
                            .wait_while(released, |released| !*released)
                            .unwrap_or_else(std::sync::PoisonError::into_inner),
                    );
                    Ok(())
                })
                .await
            })
        };
        entered_rx.await.unwrap();
        worker.abort();
        assert!(worker.await.unwrap_err().is_cancelled());

        let mut drain = Box::pin(pool.close_and_drain(Duration::from_secs(2)));
        let first_poll = futures_util::poll!(&mut drain);

        let (released, changed) = &*gate;
        *released.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = true;
        changed.notify_all();
        match first_poll {
            Poll::Pending => assert_eq!(drain.await, 0),
            Poll::Ready(residual) => {
                panic!("drain completed with {residual} jobs while its worker was still blocked")
            }
        }
    }
}
