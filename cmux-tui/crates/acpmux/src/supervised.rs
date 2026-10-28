//! Every task and thread an acpmux process starts runs under a declared failure
//! policy (plans/cmux-next/chrome-parity/p10-stability.md, "Supervision").
//!
//! Chromium's split, which [`cmux_panic_log::Supervisor`] implements:
//! - Work on shared state (the hub's sessions, turns, queues and peers, and so
//!   each client connection, request and notification handler of the hub; the
//!   writer threads' queues; an agent host's event loop) runs under the
//!   process's [`Supervisor`] as [`Fatal`]. A panic there may leave that state
//!   half-changed or a lock on it poisoned, so the process records it and ends
//!   with [`cmux_panic_log::SUPERVISED_FATAL_EXIT_CODE`]; its supervisor
//!   (launchd, the app, the daemon for a host) starts it again and the journal
//!   restores what it held (`content/browser/browser_main_loop.cc`: a dead
//!   browser thread is fatal, never a live process serving nothing). A caller
//!   that waits for such work as for an inline call uses [`call`].
//! - Work that owns only its scope's state (a pump between a socket half and a
//!   channel, a child's pipe, one call's reply) runs through [`spawn_scoped`],
//!   [`scoped_thread`] or [`spawn_request`]: a panic ends only that scope
//!   (`content/public/browser/render_process_host.h`, `ReportBadMessage` ends
//!   one renderer, not the browser). Cleanup such a task owes shared state
//!   runs from a drop guard made at its start, so an unwind runs it too.
//!
//! Every call names its policy and its [`ShutdownBehavior`]. The supervisor is
//! built by each process's composition root ([`process_supervisor`]) and
//! passed to the code that starts workers; nothing here is process-global.

use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::path::PathBuf;
use std::sync::Arc;

use futures::FutureExt;
use futures::future::BoxFuture;

pub use cmux_panic_log::{
    ExitProcess, Fatal, Fields, ShutdownBehavior, StopToken, SuperviseError, Supervisor,
    WorkerHandle, WorkerOutcome,
};
pub use cmux_threads::ThreadQos;

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
    task_boxed(supervisor, name, policy, shutdown, Box::pin(work));
}

/// [`task`] for work already on the heap. The daemon's futures are large in
/// debug builds; boxed before they pass through the supervisor's frames, a
/// worker's stack holds only a pointer to each.
pub fn task_boxed(
    supervisor: &Supervisor,
    name: &str,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    work: BoxFuture<'static, ()>,
) {
    if let Err(error) = supervisor.supervise_task(name, policy, shutdown, move |_stop| work) {
        tracing::warn!(task = name, "not started: {error}");
    }
}

/// Runs `work` under `supervisor` with `policy` and `shutdown`, and returns once
/// it has ended (returned, unwound, or stopped): its caller waits as for an
/// inline call, while a panic in `work` reaches the supervisor under `name`.
/// Dropping the returned future first stops `work`, as dropping it inline
/// would have (with [`ShutdownBehavior::Skip`], at its next await). `work` comes
/// boxed, as to [`task_boxed`]: the daemon's connection and request futures are
/// large, and the caller's stack then holds only a pointer to each.
pub async fn call(
    supervisor: &Supervisor,
    name: &str,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    work: BoxFuture<'static, ()>,
) -> Result<(), SuperviseError> {
    let (ended_tx, ended) = tokio::sync::oneshot::channel::<()>();
    let handle = supervisor.supervise_task(name, policy, shutdown, move |_stop| async move {
        // Dropped when `work` returns or unwinds, which ends the caller's wait.
        let _ended = ended_tx;
        work.await;
    })?;
    let stop = StopUnlessEnded(Some(handle));
    let _ = ended.await;
    // Ended: a stop now could race the supervisor's read of a panic.
    stop.disarm();
    Ok(())
}

/// Stops its worker when its caller's wait is dropped before the worker ended.
struct StopUnlessEnded(Option<WorkerHandle>);

impl StopUnlessEnded {
    fn disarm(mut self) {
        self.0 = None;
    }
}

impl Drop for StopUnlessEnded {
    fn drop(&mut self) {
        if let Some(handle) = &self.0 {
            handle.stop();
        }
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
/// `shutdown`, registered with `cmux_threads` at `qos` (its row in the thread
/// registry, its QoS set before `body` runs; p02-threads tasks 213-218). The
/// row is gone when `body` returns or unwinds.
pub fn thread<F, O>(
    supervisor: &Supervisor,
    name: &str,
    qos: ThreadQos,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    body: F,
) -> Result<WorkerHandle, SuperviseError>
where
    F: FnOnce(&StopToken) -> O + Send + 'static,
    O: WorkerOutcome,
{
    let row = name.to_owned();
    supervisor.supervise_thread(name, policy, shutdown, move |stop| {
        cmux_threads::register_current(row, qos);
        let _row = RegistryRow;
        body(stop)
    })
}

/// Removes the thread's `cmux_threads` row when its body returns or unwinds.
struct RegistryRow;

impl Drop for RegistryRow {
    fn drop(&mut self) {
        cmux_threads::deregister_current();
    }
}

/// Starts `body` on a thread named `name` under `supervisor` with `policy` and
/// `shutdown`, at `qos` like [`thread`]; its owner keeps the [`OwnedThread`] and
/// joins it when it stops it.
pub fn owned_thread<F>(
    supervisor: &Supervisor,
    name: &str,
    qos: ThreadQos,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    body: F,
) -> Result<OwnedThread, SuperviseError>
where
    F: FnOnce() + Send + 'static,
{
    let (ended, done) = std::sync::mpsc::sync_channel::<()>(0);
    let row = name.to_owned();
    supervisor.supervise_thread(name, policy, shutdown, move |_stop| {
        // Dropped last, after the row: a joined thread has no row (cmux_threads::spawn).
        let _ended = ended;
        cmux_threads::register_current(row, qos);
        let _row = RegistryRow;
        body();
    })?;
    Ok(OwnedThread { done })
}

/// Runs `work` on the runtime's blocking pool as a supervised task: a panic in
/// `work` is the task's, under `policy`. The item may block and is hang-watched
/// (`crate::daemon::spawn_blocking`).
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
        if let Err(error) = crate::daemon::spawn_blocking(work).await
            && error.is_panic()
        {
            std::panic::resume_unwind(error.into_panic());
        }
    });
}

/// Starts `body` on a thread named `name`, scoped to one call, child process or
/// connection: it owns only its pipe or socket ends, and a panic in it drops them,
/// which ends that scope for whoever reads the other end (or joins the handle).
/// It is a `cmux_threads` thread at `qos` (named, registered); a helper its
/// caller joins passes `cmux_threads::caller_qos(..)`, so the join is never a
/// priority inversion.
pub fn scoped_thread<T, F>(
    name: &str,
    qos: ThreadQos,
    body: F,
) -> std::io::Result<std::thread::JoinHandle<T>>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    // supervise-allow: scoped: the thread owns only its scope's ends; a panic drops them and ends that scope.
    cmux_threads::spawn(name, qos, body)
}

/// Starts `work`, a task scoped to one connection, child process or call that
/// owns only its scope's state (channel ends, a socket half, a pipe). A panic
/// in it ends only that scope: its captures drop, which closes its channels for
/// the other side, and the drop guards it made run. Work that changes shared
/// state runs under a [`Supervisor`] instead ([`task`], [`call`]). Shutdown:
/// Skip (the runtime drops it when the process ends).
pub fn spawn_scoped<F>(work: F)
where
    F: Future<Output = ()> + Send + 'static,
{
    let work: BoxFuture<'static, ()> = Box::pin(work);
    // supervise-allow: scoped: the task owns only its scope's state; a panic drops it and ends that scope.
    tokio::spawn(work);
}

/// Starts `work`, a task scoped to one request whose state is its own (a call
/// into another process, a reply to send). A panic in it ends only that
/// request: `ended` then runs and answers it with an internal error (the panic
/// hook has already logged the panic with its stack). A request handler that
/// changes the hub's shared state runs under the hub's [`Supervisor`] as
/// [`Fatal`] instead (`server/request_task.rs`). Shutdown: Skip.
pub fn spawn_request<F, E>(work: F, ended: E)
where
    F: Future<Output = ()> + Send + 'static,
    E: Future<Output = ()> + Send + 'static,
{
    let (work, ended): (BoxFuture<'static, ()>, BoxFuture<'static, ()>) =
        (Box::pin(work), Box::pin(ended));
    // supervise-allow: scoped: the task catches its own panic and answers its request with `ended`, so its handle carries nothing.
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
