//! Every task and thread an acpmux process starts runs under a declared failure
//! policy (plans/cmux-next/chrome-parity/p10-stability.md, "Supervision").
//!
//! Chromium's split, which [`cmux_panic_log::Supervisor`] implements:
//! - Work on shared state (the hub's sessions, turns, queues and peers; the
//!   writer threads' queues; an agent host's event loop) runs under the
//!   process's [`Supervisor`] as [`Fatal`]. A panic there may leave that state
//!   half-changed, so the process records it and ends with
//!   [`cmux_panic_log::SUPERVISED_FATAL_EXIT_CODE`]; its supervisor (launchd,
//!   the app, the daemon for a host) starts it again and the journal restores
//!   what it held (`content/browser/browser_main_loop.cc`: a dead browser
//!   thread is fatal, never a live process serving nothing).
//! - Work scoped to one request or one connection runs through
//!   [`spawn_scoped`]: a panic ends only that scope. The request gets an
//!   internal error, the connection closes
//!   (`content/public/browser/render_process_host.h`, `ReportBadMessage`
//!   ends one renderer, not the browser).
//!
//! Every call names its policy and its [`ShutdownBehavior`]. The supervisor is
//! built by each process's composition root ([`process_supervisor`]) and
//! passed to the code that starts workers; nothing here is process-global.

use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::Arc;

use futures::FutureExt;

pub use cmux_panic_log::{
    ExitProcess, Fatal, Fields, ShutdownBehavior, StopToken, SuperviseError, Supervisor,
    WorkerHandle,
};

/// The supervisor of an acpmux process: a fatal failure appends a
/// `supervised_exit` line to `log` (the process's panic log) and ends the
/// process, so whatever supervises it starts it again.
pub fn process_supervisor(log: Option<PathBuf>, fields: Fields) -> Supervisor {
    Supervisor::new(Arc::new(ExitProcess::new(log, fields, exit_process)))
}

/// The supervisor of a hub or store built outside a daemon (tests, one-shot
/// CLI commands): a fatal failure ends the process, with no panic-log line.
pub fn embedded() -> Supervisor {
    process_supervisor(None, Fields::new())
}

fn exit_process(code: i32) {
    std::process::exit(code)
}

/// Starts `work` on the current runtime under `supervisor` with `policy` and
/// `shutdown`. A start the supervisor refuses (its shutdown began, or no
/// runtime runs here) is logged, and the work does not run.
pub fn task<F>(
    supervisor: &Supervisor,
    name: &str,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    work: F,
) where
    F: Future<Output = ()> + Send + 'static,
{
    if let Err(error) = supervisor.supervise_task(name, policy, shutdown, move |_stop| work) {
        tracing::warn!(task = name, "not started: {error}");
    }
}

/// A supervised thread its owner waits for, as it would join a `JoinHandle`.
pub struct OwnedThread {
    done: std::sync::mpsc::Receiver<()>,
}

impl OwnedThread {
    /// Returns once the thread's body has ended (returned, or unwound before a
    /// fatal exit).
    pub fn join(self) {
        // Nothing is sent: the body's end drops the only sender.
        let _ = self.done.recv();
    }
}

/// Starts `body` on a thread named `name` under `supervisor` with `policy` and
/// `shutdown`; its owner keeps the [`OwnedThread`] and joins it when it stops it.
pub fn owned_thread<F>(
    supervisor: &Supervisor,
    name: &str,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    body: F,
) -> Result<OwnedThread, SuperviseError>
where
    F: FnOnce() + Send + 'static,
{
    let (ended, done) = std::sync::mpsc::sync_channel::<()>(0);
    supervisor.supervise_thread(name, policy, shutdown, move |_stop| {
        let _ended = ended;
        body();
    })?;
    Ok(OwnedThread { done })
}

/// Runs `work` on the runtime's blocking pool as a supervised task: a panic in
/// `work` is the task's, under `policy`.
pub fn blocking<F>(
    supervisor: &Supervisor,
    name: &str,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    work: F,
) where
    F: FnOnce() + Send + 'static,
{
    task(supervisor, name, policy, shutdown, async move {
        if let Err(error) = tokio::task::spawn_blocking(work).await
            && error.is_panic()
        {
            std::panic::resume_unwind(error.into_panic());
        }
    });
}

/// Starts `work`, a task scoped to one request or one connection. A panic in
/// it ends only that scope: `ended` then runs, answering the request with an
/// internal error or closing the connection. The panic hook has already
/// logged the panic with its stack.
pub fn spawn_scoped<F, E>(work: F, ended: E)
where
    F: Future<Output = ()> + Send + 'static,
    E: Future<Output = ()> + Send + 'static,
{
    // supervise-allow: scoped: the task catches its own panic and ends its request or connection with `ended`, so its handle carries nothing.
    tokio::spawn(async move {
        // AssertUnwindSafe: the scope's own state is dropped with it, and `ended` reads only
        // what it captured.
        if AssertUnwindSafe(work).catch_unwind().await.is_err() {
            ended.await;
        }
    });
}

#[cfg(test)]
#[path = "supervised_tests.rs"]
pub(crate) mod tests;
