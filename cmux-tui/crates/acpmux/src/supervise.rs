//! Supervision of the daemon's long-lived tasks (`plans/cmux-next/rust-panic-free.md` §5).
//!
//! A panic ends only its task. For a request that is the right size. For a loop the daemon has
//! one of (the watch loop, the notify loop, the startup task), it left a live daemon that had
//! stopped doing that job for good, with one line in `panics.jsonl` as the only sign. A task
//! started here is run again after a panic, with a growing wait. A task that keeps panicking,
//! or one that cannot run twice, raises [`Fatal`]: the daemon stops for a restart
//! (`daemon/stop_causes.rs`), its agents stay up in their hosts, and its service manager or the
//! next client starts it again. Never a live process that does nothing.

use futures_util::FutureExt as _;
use std::collections::VecDeque;
use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::Instant;

/// More panics than this within [`WINDOW`] end the restarts: the task is broken, not unlucky.
pub(crate) const MAX_RESTARTS: usize = 5;
pub(crate) const WINDOW: Duration = Duration::from_secs(60);
/// The wait before the first restart; it doubles with each panic still inside the window.
const FIRST_WAIT: Duration = Duration::from_millis(100);

/// Why the daemon must stop for a restart, once a supervised task could not go on.
#[derive(Clone)]
pub struct Fatal(Arc<watch::Sender<Option<String>>>);

impl Default for Fatal {
    fn default() -> Self {
        Self(Arc::new(watch::channel(None).0))
    }
}

impl Fatal {
    /// The first reason stays.
    pub(crate) fn raise(&self, why: String) {
        self.0.send_if_modified(|current| {
            let first = current.is_none();
            if first {
                *current = Some(why);
            }
            first
        });
    }

    /// Resolves with the reason once one is raised.
    pub(crate) async fn raised(&self) -> String {
        let mut rx = self.0.subscribe();
        match rx.wait_for(Option::is_some).await {
            Ok(why) => why.clone().unwrap_or_default(),
            Err(_) => std::future::pending().await,
        }
    }
}

/// Run `task` until it returns, and again after each panic. Aborting the handle ends it.
pub(crate) fn restarting<F, Fut>(name: &'static str, fatal: &Fatal, mut task: F) -> JoinHandle<()>
where
    F: FnMut() -> Fut + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    let fatal = fatal.clone();
    tokio::spawn(async move {
        let mut panics: VecDeque<Instant> = VecDeque::new();
        loop {
            // The call that makes the future is inside the boundary too.
            if AssertUnwindSafe(async { task().await }).catch_unwind().await.is_ok() {
                return;
            }
            let now = Instant::now();
            while panics.front().is_some_and(|at| now.duration_since(*at) > WINDOW) {
                panics.pop_front();
            }
            panics.push_back(now);
            if panics.len() > MAX_RESTARTS {
                fatal.raise(format!(
                    "the {name} task panicked {} times within {WINDOW:?}",
                    panics.len()
                ));
                return;
            }
            let wait = FIRST_WAIT * (1 << (panics.len() - 1));
            tracing::error!("the {name} task panicked; it starts again in {wait:?}");
            tokio::time::sleep(wait).await;
        }
    })
}

/// Run a task that cannot run twice: its panic raises [`Fatal`].
pub(crate) fn once<Fut>(name: &'static str, fatal: &Fatal, task: Fut) -> JoinHandle<()>
where
    Fut: Future<Output = ()> + Send + 'static,
{
    let fatal = fatal.clone();
    tokio::spawn(async move {
        if AssertUnwindSafe(task).catch_unwind().await.is_err() {
            fatal.raise(format!("the {name} task panicked and cannot start again"));
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn panicking(
        runs: &Arc<AtomicUsize>,
        until: usize,
    ) -> impl FnMut() -> std::future::Ready<()> + use<> {
        let runs = runs.clone();
        move || {
            let run = runs.fetch_add(1, Ordering::SeqCst) + 1;
            assert!(run > until, "test panic {run}");
            std::future::ready(())
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_task_that_panics_runs_again_and_one_that_returns_does_not() {
        let (fatal, runs) = (Fatal::default(), Arc::new(AtomicUsize::new(0)));
        restarting("test", &fatal, panicking(&runs, 2)).await.unwrap();
        assert_eq!(runs.load(Ordering::SeqCst), 3, "two panics, then the run that returned");
        assert!(fatal.0.borrow().is_none(), "two panics are under the limit");
    }

    #[tokio::test(start_paused = true)]
    async fn a_task_that_keeps_panicking_raises_fatal_and_stops() {
        let (fatal, runs) = (Fatal::default(), Arc::new(AtomicUsize::new(0)));
        restarting("test", &fatal, panicking(&runs, usize::MAX)).await.unwrap();
        assert_eq!(runs.load(Ordering::SeqCst), MAX_RESTARTS + 1);
        assert!(fatal.raised().await.contains("the test task panicked 6 times"));
    }

    #[tokio::test(start_paused = true)]
    async fn panics_spread_over_time_never_raise_fatal() {
        let (fatal, runs) = (Fatal::default(), Arc::new(AtomicUsize::new(0)));
        let seen = runs.clone();
        let task = restarting("test", &fatal, move || {
            let run = seen.fetch_add(1, Ordering::SeqCst);
            async move {
                tokio::time::sleep(WINDOW).await;
                assert!(run >= 20, "test panic {run}");
            }
        });
        task.await.unwrap();
        assert_eq!(runs.load(Ordering::SeqCst), 21);
        assert!(fatal.0.borrow().is_none());
    }

    #[tokio::test]
    async fn a_task_that_cannot_run_twice_raises_fatal_on_its_panic() {
        let fatal = Fatal::default();
        once("startup", &fatal, async { panic!("test panic") }).await.unwrap();
        assert_eq!(fatal.raised().await, "the startup task panicked and cannot start again");
        // The first reason stays.
        fatal.raise("another".into());
        assert_eq!(fatal.raised().await, "the startup task panicked and cannot start again");
    }
}
