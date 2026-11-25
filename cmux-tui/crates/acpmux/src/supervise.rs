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

/// Debug builds only: a panic at `point` once it is armed, where `text` holds the armed text:
/// by a unit test ([`arm_panic`]) or by `ACPMUX_TEST_PANIC_AT=POINT[:TEXT]` for the daemon's
/// integration tests. Each arming fires once, and counts every pass of its point after
/// ([`armed_passes`]), so a test sees a supervised loop come back to it. Release builds have no
/// seam.
#[cfg(any(test, debug_assertions))]
pub(crate) fn panic_point(point: &str, text: &str) {
    let fire = {
        let mut seam = PANIC_SEAM.lock().unwrap_or_else(|e| e.into_inner());
        if !seam.read_env {
            seam.read_env = true;
            if let Ok(v) = std::env::var("ACPMUX_TEST_PANIC_AT") {
                let (p, t) = v.split_once(':').unwrap_or((&v, ""));
                seam.armed.push(Armed { point: p.into(), text: t.into(), ..Armed::default() });
            }
        }
        let mut fire = false;
        for armed in seam.armed.iter_mut() {
            if armed.point == point && text.contains(armed.text.as_str()) {
                armed.passes += 1;
                // One arming fires per pass.
                if !fire && !armed.fired {
                    (armed.fired, fire) = (true, true);
                }
            }
        }
        fire
    };
    if fire {
        crate::daemon::test_panic(&format!("test panic at {point}"));
    }
}

#[cfg(not(any(test, debug_assertions)))]
#[inline(always)]
pub(crate) fn panic_point(_point: &str, _text: &str) {}

/// [`panic_point`] whose text is made only while something is armed at `point`.
#[cfg(any(test, debug_assertions))]
pub(crate) fn panic_point_with(point: &str, text: impl FnOnce() -> String) {
    let armed = {
        let seam = PANIC_SEAM.lock().unwrap_or_else(|e| e.into_inner());
        !seam.read_env || seam.armed.iter().any(|a| a.point == point)
    };
    if armed {
        panic_point(point, &text());
    }
}

#[cfg(not(any(test, debug_assertions)))]
#[inline(always)]
pub(crate) fn panic_point_with(_point: &str, _text: impl FnOnce() -> String) {}

#[cfg(any(test, debug_assertions))]
#[derive(Default)]
struct Armed {
    point: String,
    text: String,
    fired: bool,
    passes: usize,
}

#[cfg(any(test, debug_assertions))]
struct PanicSeam {
    read_env: bool,
    armed: Vec<Armed>,
}

#[cfg(any(test, debug_assertions))]
static PANIC_SEAM: std::sync::Mutex<PanicSeam> =
    std::sync::Mutex::new(PanicSeam { read_env: false, armed: Vec::new() });

/// Tests only: [`panic_point`] panics once at `point` where its text holds `text`.
#[cfg(test)]
pub(crate) fn arm_panic(point: &str, text: &str) {
    let mut seam = PANIC_SEAM.lock().unwrap_or_else(|e| e.into_inner());
    seam.armed.push(Armed { point: point.into(), text: text.into(), ..Armed::default() });
}

/// Tests only: how often `point` was passed with `text` since [`arm_panic`] armed it, the pass
/// that panicked included.
#[cfg(test)]
pub(crate) fn armed_passes(point: &str, text: &str) -> usize {
    let seam = PANIC_SEAM.lock().unwrap_or_else(|e| e.into_inner());
    seam.armed.iter().filter(|a| a.point == point && a.text == text).map(|a| a.passes).sum()
}

/// Tests only: waits up to `within` until `point` was passed at least `passes` times since it
/// was armed.
#[cfg(test)]
pub(crate) async fn passed(point: &str, text: &str, passes: usize, within: Duration) -> bool {
    let deadline = std::time::Instant::now() + within;
    while armed_passes(point, text) < passes {
        if std::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    true
}

#[cfg(test)]
#[path = "supervise_tests.rs"]
mod tests;
