//! Every thread this crate starts runs under the process's
//! [`cmux_panic_log::Supervisor`].
//!
//! The daemon's workers share the mux, the journal and the registry, so a
//! worker that fails takes the process down with [`Fatal`]: the panic hook has
//! already written the panic line, the supervisor ends the process with
//! [`cmux_panic_log::SUPERVISED_FATAL_EXIT_CODE`], and the process supervisor
//! starts it again from the journal. Before this, a failed worker ended only
//! its own thread and left a live process serving nothing. Chromium has the
//! same rule for browser-process threads: a crash on one ends the browser
//! (content/browser/browser_main_loop.cc), and its relauncher restarts it.
//!
//! The supervisor is a process resource, as Chromium's thread pool is
//! (`base::ThreadPoolInstance::Set`, base/task/thread_pool/thread_pool_instance.h)
//! and as this crate's thread registry and hang log are: the composition root
//! calls [`install`] once with a supervisor whose sink is
//! [`cmux_panic_log::ExitProcess`] (the binary owns the process's exit).
//!
//! Names are kept, threads registered with `cmux_threads` keep their QoS row,
//! and [`SupervisedThread`] keeps what callers used of `JoinHandle`: `join`,
//! `is_finished`, whether it is the current thread, and `unpark`.

use std::any::Any;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering, fence};
use std::sync::mpsc::{Receiver, sync_channel};
use std::sync::{Arc, OnceLock};
use std::thread::Thread;

use cmux_panic_log::{FailureSink, FatalReport, SuperviseError, Supervisor};
use cmux_threads::{BlockingKind, DesiredQos, ThreadQos};

pub use cmux_panic_log::{Fatal, ShutdownBehavior};

static PROCESS: OnceLock<Supervisor> = OnceLock::new();

/// Make `supervisor` the process's, for every thread this crate starts after
/// the call. Call once from the composition root before the first mux or
/// host starts; `Err` returns `supervisor` when one is already in use.
pub fn install(supervisor: Supervisor) -> Result<(), Supervisor> {
    PROCESS.set(supervisor)
}

/// The installed supervisor. Before [`install`], a fatal failure is written
/// to stderr and ends only its worker: ending the process belongs to the
/// binary, whose composition root installs [`cmux_panic_log::ExitProcess`].
pub fn process() -> &'static Supervisor {
    PROCESS.get_or_init(|| Supervisor::new(Arc::new(NotInstalled)))
}

/// The sink of a process whose composition root installed no supervisor.
struct NotInstalled;

impl FailureSink for NotInstalled {
    fn fatal(&self, report: &FatalReport) {
        eprintln!("cmux-tui: {report}; no process supervisor is installed, so only it ends");
    }
}

/// Start `body` on thread `name` under the process's supervisor, registered
/// with `cmux_threads` at `qos` (its row in the thread registry, its QoS set
/// before `body` runs). Every thread this crate starts has a row and a class
/// (p02-threads tasks 213-218), so there is no unregistered start.
pub(crate) fn spawn_at<F, T>(
    name: impl Into<String>,
    qos: ThreadQos,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    body: F,
) -> io::Result<SupervisedThread<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    spawn_on(process(), name.into(), Some(Registered::at(qos)), policy, shutdown, body)
}

/// [`spawn_at`] for a thread that follows `desired` (`cmux_threads::spawn_following`):
/// it starts at `qos` and runs at the class last requested through `desired`.
pub(crate) fn spawn_following<F, T>(
    name: impl Into<String>,
    qos: ThreadQos,
    desired: DesiredQos,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    body: F,
) -> io::Result<SupervisedThread<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    let registered = Registered { qos, desired: Some(desired) };
    spawn_on(process(), name.into(), Some(registered), policy, shutdown, body)
}

/// [`spawn_at`] at the class `crate::thread_qos::spawn_raisable` starts a
/// Utility or Background thread that may take a ranked lock at
/// (`cmux_tui_platform::qos::raisable_class`). The supervisor's threads
/// take the platform's default stack.
pub(crate) fn spawn_raisable<F, T>(
    name: impl Into<String>,
    qos: ThreadQos,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    body: F,
) -> io::Result<SupervisedThread<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    let qos = cmux_tui_platform::qos::raisable_class(qos);
    spawn_on(process(), name.into(), Some(Registered::at(qos)), policy, shutdown, body)
}

/// A thread's `cmux_threads` row: its starting class and, for a thread that
/// follows one, the desired class it applies later.
pub(crate) struct Registered {
    qos: ThreadQos,
    desired: Option<DesiredQos>,
}

impl Registered {
    pub(crate) fn at(qos: ThreadQos) -> Self {
        Self { qos, desired: None }
    }
}

/// [`spawn_at`] and the others under `supervisor` (tests pass their own sink).
pub(crate) fn spawn_on<F, T>(
    supervisor: &Supervisor,
    name: String,
    qos: Option<Registered>,
    policy: Fatal,
    shutdown: ShutdownBehavior,
    body: F,
) -> io::Result<SupervisedThread<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    let started = Arc::new(Started::default());
    let (result_tx, result) = sync_channel(1);
    let thread_started = Arc::clone(&started);
    let row_name = name.clone();
    let worker = supervisor
        .supervise_thread(name, policy, shutdown, move |_stop| {
            let _finished = Finished(Arc::clone(&thread_started));
            thread_started.begin();
            let output = match qos {
                Some(Registered { qos, desired }) => {
                    match desired {
                        Some(desired) => {
                            cmux_threads::register_current_following(row_name, qos, desired)
                        }
                        None => cmux_threads::register_current(row_name, qos),
                    };
                    let _row = RegistryRow;
                    body()
                }
                None => body(),
            };
            // After the row is gone, so a joined thread has no row (cmux_threads::spawn).
            let _ = result_tx.send(output);
        })
        .map_err(|error| match error {
            SuperviseError::Spawn(error) => error,
            other => io::Error::other(other),
        })?;
    Ok(SupervisedThread { worker, started, result })
}

/// A started supervised thread. Dropping it leaves the thread running.
pub struct SupervisedThread<T> {
    worker: cmux_panic_log::WorkerHandle,
    started: Arc<Started>,
    result: Receiver<T>,
}

impl<T> SupervisedThread<T> {
    pub fn name(&self) -> &str {
        self.worker.name()
    }

    /// Wait for the thread's body and take what it returned. `Err` when the
    /// body failed under a supervisor whose sink returns (a test sink); in
    /// production a failure has ended the process.
    #[track_caller]
    pub fn join(self) -> std::thread::Result<T> {
        cmux_threads::assert_blocking_allowed(BlockingKind::Join);
        self.result.recv().map_err(|_| -> Box<dyn Any + Send> {
            Box::new(format!("supervised thread {} failed", self.worker.name()))
        })
    }

    /// Whether the body has returned or failed.
    pub fn is_finished(&self) -> bool {
        self.started.finished.load(Ordering::Acquire)
    }

    /// Whether the calling thread is this one. A thread that has not begun
    /// yet is not the caller.
    pub fn is_current(&self) -> bool {
        self.started.thread.get().is_some_and(|thread| thread.id() == std::thread::current().id())
    }

    /// `Thread::unpark` for this thread; one asked before the thread begins
    /// is kept for its first park.
    pub fn unpark(&self) {
        self.started.unpark();
    }

    /// A clone that can only unpark the thread.
    pub fn unparker(&self) -> Unparker {
        Unparker(Arc::clone(&self.started))
    }
}

/// Unparks one supervised thread ([`SupervisedThread::unpark`]).
#[derive(Clone)]
pub struct Unparker(Arc<Started>);

impl Unparker {
    pub fn unpark(&self) {
        self.0.unpark();
    }

    /// An unparker of the calling thread, for a test seam that runs a
    /// thread's work on the test thread instead of starting one.
    #[cfg(test)]
    pub(crate) fn current_for_test() -> Self {
        let started = Started::default();
        let _ = started.thread.set(std::thread::current());
        Self(Arc::new(started))
    }
}

#[derive(Default)]
struct Started {
    thread: OnceLock<Thread>,
    unpark_asked: AtomicBool,
    finished: AtomicBool,
}

impl Started {
    /// On the new thread, first: publish the thread, then take an unpark
    /// asked before it was published. Each side stores, fences, then reads
    /// the other's store, so one of them always sees the other.
    fn begin(&self) {
        let _ = self.thread.set(std::thread::current());
        fence(Ordering::SeqCst);
        if self.unpark_asked.load(Ordering::Relaxed) {
            std::thread::current().unpark();
        }
    }

    fn unpark(&self) {
        self.unpark_asked.store(true, Ordering::Relaxed);
        fence(Ordering::SeqCst);
        if let Some(thread) = self.thread.get() {
            thread.unpark();
        }
    }
}

/// Marks the thread finished when its body returns or unwinds.
struct Finished(Arc<Started>);

impl Drop for Finished {
    fn drop(&mut self) {
        self.0.finished.store(true, Ordering::Release);
    }
}

/// Removes the thread's `cmux_threads` row when its body returns or unwinds.
struct RegistryRow;

impl Drop for RegistryRow {
    fn drop(&mut self) {
        cmux_threads::deregister_current();
    }
}

#[cfg(test)]
#[path = "supervised_tests.rs"]
mod tests;
