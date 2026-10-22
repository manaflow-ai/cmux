//! Supervisors for the task and connection boundaries of cmux daemons
//! (plans/cmux-next/rust-panic-free.md, section 5).
//!
//! Release builds keep `panic = "unwind"`, so a panic that is left (third-party
//! code, a missed path) unwinds to the nearest boundary. Without a boundary it
//! ends a thread or a tokio task silently, and a daemon whose accept loop or
//! actor is gone stays alive and answers nothing: a crash becomes a hang
//! (manaflow-ai/cmux#22844). These boundaries close that gap:
//!
//! - [`spawn`]: a long-lived worker thread. After a panic the worker restarts
//!   with backoff ([`OnPanic::Restart`]), or, when its state cannot be rebuilt,
//!   the process ends with a clear line on stderr ([`OnPanic::EndProcess`]) so
//!   its process supervisor restarts it.
//! - [`catch`]: one connection or one request. A panic becomes
//!   `Err(Panicked)`; the caller answers that request with an internal error
//!   or closes that one connection and keeps serving the others.
//! - [`restarting`]: the async form of a restarting worker, for a tokio
//!   task that rebuilds its state on start.
//! - [`catch_future`]: the same as [`catch`] for a future, for a tokio task whose
//!   `JoinHandle` is dropped (`tokio::spawn(catch_future(..))`), where
//!   `JoinError::is_panic` would never be read.
//!
//! The panic hook ([`crate::install`]) has already written the panic (message,
//! location, backtrace) to the panic log when a boundary sees it; the
//! boundary adds one stderr line naming the boundary and what it did.
//!
//! Callers must not leave state half-changed across a boundary: every lock in
//! cmux recovers from poison (`unwrap_or_else(PoisonError::into_inner)`), so
//! the boundaries assert unwind safety for their bodies.

use std::any::Any;
use std::future::Future;
use std::io::Write as _;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::pin::Pin;
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Exit status of a process that a supervisor ended (`EX_SOFTWARE`).
pub const EXIT_UNRECOVERABLE: i32 = 70;
/// First restart delay of a worker that panicked.
pub const RESTART_INITIAL: Duration = Duration::from_millis(100);
/// Longest restart delay: a worker that panics at once on every start is
/// retried at this pace instead of spinning.
pub const RESTART_MAX: Duration = Duration::from_secs(10);
/// A worker that ran this long before its panic restarts after
/// [`RESTART_INITIAL`] again.
pub const RESTART_RESET_AFTER: Duration = Duration::from_secs(60);

/// A panic that a boundary caught.
#[derive(Debug, Clone)]
pub struct Panicked {
    /// The boundary's label (the worker, connection or request kind).
    pub label: String,
    /// The panic message, or a fixed text for a payload that is not text.
    pub message: String,
}

impl std::fmt::Display for Panicked {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} panicked: {}", self.label, self.message)
    }
}

impl std::error::Error for Panicked {}

/// What a supervised worker does after its body panicked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnPanic {
    /// Run the body again after a backoff ([`RESTART_INITIAL`] doubling to
    /// [`RESTART_MAX`]). For a worker that rebuilds its state on start.
    Restart,
    /// End the process with [`EXIT_UNRECOVERABLE`]. For a worker whose state
    /// cannot be rebuilt in-process: a live process without it would answer
    /// nothing, while a restarted one restores from the journal.
    EndProcess,
}

/// Spawn a named worker thread whose `body` runs under a supervisor. The
/// worker ends when `body` returns; a panic restarts it or ends the process
/// as `on_panic` says.
pub fn spawn<F>(
    name: impl Into<String>,
    on_panic: OnPanic,
    mut body: F,
) -> std::io::Result<JoinHandle<()>>
where
    F: FnMut() + Send + 'static,
{
    let name = name.into();
    let label = name.clone();
    std::thread::Builder::new().name(name).spawn(move || {
        let mut backoff = Backoff::new();
        loop {
            let started = Instant::now();
            let Err(payload) = catch_unwind(AssertUnwindSafe(&mut body)) else {
                return;
            };
            let panicked = Panicked { label: label.clone(), message: payload_message(&*payload) };
            if on_panic == OnPanic::EndProcess {
                end_process(&panicked);
            }
            std::thread::sleep(backoff.after_panic(&panicked, started));
        }
    })
}

/// The async form of a restarting worker: run the future that `make`
/// builds; after a panic, build and run a new one after the backoff of
/// [`spawn`]. `sleep` is the runtime's timer (`tokio::time::sleep`), so this
/// crate needs no runtime. Ends when a run returns.
pub async fn restarting<M, Fut, S, SleepFut>(label: &str, mut make: M, sleep: S)
where
    M: FnMut() -> Fut,
    Fut: Future<Output = ()>,
    S: Fn(Duration) -> SleepFut,
    SleepFut: Future<Output = ()>,
{
    let mut backoff = Backoff::new();
    loop {
        let started = Instant::now();
        let Err(panicked) = catch_future(label, make()).await else {
            return;
        };
        sleep(backoff.after_panic(&panicked, started)).await;
    }
}

/// The restart delay: [`RESTART_INITIAL`] doubling to [`RESTART_MAX`], back
/// to the start after a run of [`RESTART_RESET_AFTER`].
struct Backoff {
    delay: Duration,
    restarts: u64,
}

impl Backoff {
    fn new() -> Self {
        Self { delay: RESTART_INITIAL, restarts: 0 }
    }

    /// Note the panic of a run that began at `started`; the delay before the next run.
    fn after_panic(&mut self, panicked: &Panicked, started: Instant) -> Duration {
        if started.elapsed() >= RESTART_RESET_AFTER {
            self.delay = RESTART_INITIAL;
        }
        let delay = self.delay;
        self.restarts = self.restarts.saturating_add(1);
        note(&format!(
            "{panicked}; restarting in {} ms (restart {})",
            delay.as_millis(),
            self.restarts
        ));
        self.delay = delay.saturating_mul(2).min(RESTART_MAX);
        delay
    }
}

/// Run one connection or request under a boundary: a panic in `f` returns
/// `Err` instead of ending the thread or task that serves the others.
pub fn catch<R>(label: &str, f: impl FnOnce() -> R) -> Result<R, Panicked> {
    catch_unwind(AssertUnwindSafe(f)).map_err(|payload| {
        let panicked = Panicked { label: label.to_string(), message: payload_message(&*payload) };
        note(&format!("{panicked}; the boundary contained it"));
        panicked
    })
}

/// A future that resolves to `Err(Panicked)` when polling `future` panics.
pub fn catch_future<F: Future>(label: impl Into<String>, future: F) -> CatchFuture<F> {
    CatchFuture { label: label.into(), future: Box::pin(future) }
}

/// See [`catch_future`].
pub struct CatchFuture<F> {
    label: String,
    future: Pin<Box<F>>,
}

impl<F: Future> Future for CatchFuture<F> {
    type Output = Result<F::Output, Panicked>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        // `CatchFuture` is `Unpin`: the inner future is pinned in its box.
        let this = self.get_mut();
        match catch_unwind(AssertUnwindSafe(|| this.future.as_mut().poll(cx))) {
            Ok(Poll::Pending) => Poll::Pending,
            Ok(Poll::Ready(output)) => Poll::Ready(Ok(output)),
            Err(payload) => {
                let panicked =
                    Panicked { label: this.label.clone(), message: payload_message(&*payload) };
                note(&format!("{panicked}; the boundary contained it"));
                Poll::Ready(Err(panicked))
            }
        }
    }
}

/// End the process after a panic in a part it cannot run without. The
/// process supervisor (the app, the owner, `server ensure`) restarts it and
/// the state comes back from the journal and the output store.
pub fn end_process(panicked: &Panicked) -> ! {
    note(&format!("{panicked}; it cannot be rebuilt in this process, ending the process"));
    // crash-allow: the supervisor's deliberate crash-only exit; the process supervisor restarts it
    std::process::exit(EXIT_UNRECOVERABLE)
}

/// The text of a panic payload (`&str` or `String`).
pub fn payload_message(payload: &(dyn Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|text| (*text).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "non-text panic payload".to_string())
}

/// One line on stderr (a daemon's log). Never panics, unlike `eprintln!`.
fn note(line: &str) {
    let _ = writeln!(std::io::stderr(), "cmux supervisor: {line}");
}
