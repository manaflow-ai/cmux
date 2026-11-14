//! An owner for async tasks.
//!
//! Every task has an owner that cancels it and joins it. A [`Scope`] is that
//! owner: [`Scope::spawn`] is the spawn (a bare `tokio::spawn` has no owner,
//! and the spawn-owner ratchet counts it), [`Scope::cancelled`] is what a
//! task watches to stop, and [`Scope::close`] is the shutdown: it cancels
//! every task, joins them within a deadline, aborts the ones still running
//! past it and names them in its [`CloseReport`]. A scope belongs to the
//! thing whose life its tasks share (acpmux's `Hub`, a `Peer`, a server
//! `Conn`); [`Scope::child`] makes one for a part of it whose tasks end with
//! the part and, at the latest, with the whole. `Drop` cannot await, so a
//! scope dropped without `close` cancels its tasks and logs the owner that
//! skipped the join (debug builds with `CMUX_SCOPE_STRICT=1`, and this
//! crate's tests, panic instead). `cmux_process::Child` is the same rule for
//! child processes.
//!
//! ```
//! # #[tokio::main(flavor = "current_thread")]
//! # async fn main() {
//! use std::time::Duration;
//!
//! let scope = cmux_scope::Scope::new("example");
//! let stop = scope.cancelled();
//! scope.spawn_named("ticker", async move {
//!     tokio::select! {
//!         () = stop => {}
//!         () = tokio::time::sleep(Duration::from_secs(3600)) => {}
//!     }
//! });
//! let report = scope.close(Duration::from_secs(1)).await;
//! assert!(report.joined(), "{report}");
//! # }
//! ```

#![deny(clippy::disallowed_methods)]

use std::collections::HashMap;
use std::fmt;
use std::future::Future;
use std::panic::Location;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tokio::task::{AbortHandle, JoinHandle};
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};
use tokio_util::task::TaskTracker;
use tokio_util::task::task_tracker::TaskTrackerToken;

/// The owner of a set of tasks: it spawns them, cancels them and joins them.
pub struct Scope {
    owner: &'static str,
    tracker: TaskTracker,
    cancel: CancellationToken,
    /// This scope's live tasks; a parent's also holds its children's.
    live: Arc<Live>,
    /// The ancestors' trackers and live tables: a child's task counts in each
    /// ancestor's join and report.
    ancestors: Vec<(TaskTracker, Arc<Live>)>,
    closed: AtomicBool,
}

/// The tasks still running, by id: what each is called and how to abort it.
#[derive(Default)]
struct Live(Mutex<LiveTable>);

/// One live table, under one lock: a task's row and its abort handle, and whether the owner's
/// close is past its wait (`aborting`). A spawn fills in its handle under the same lock, so a
/// task a close could not abort yet (its handle was not in) is aborted by its own spawn.
#[derive(Default)]
struct LiveTable {
    tasks: HashMap<u64, (TaskName, Option<AbortHandle>)>,
    aborting: bool,
}

impl Live {
    fn lock(&self) -> std::sync::MutexGuard<'_, LiveTable> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Fill in task `id`'s abort handle; abort it now when this table's close is past its wait.
    /// A task that already ended removed its row: nothing to fill in.
    fn fill_in(&self, id: u64, abort: &AbortHandle) {
        let mut table = self.lock();
        let aborting = table.aborting;
        if let Some((_, slot)) = table.tasks.get_mut(&id) {
            if aborting {
                abort.abort();
            } else {
                *slot = Some(abort.clone());
            }
        }
    }

    /// The close's end: from now on every task of this table, and every one whose spawn has not
    /// filled in its handle yet, is aborted. The names of the ones still running, sorted.
    fn abort_all(&self) -> Vec<String> {
        let mut table = self.lock();
        table.aborting = true;
        let mut names: Vec<String> = table
            .tasks
            .values()
            .map(|(name, abort)| {
                if let Some(abort) = abort {
                    abort.abort();
                }
                name.to_string()
            })
            .collect();
        names.sort();
        names
    }
}

/// What a task is called in a report: its name, or where it was spawned.
#[derive(Clone, Copy, Debug)]
enum TaskName {
    Named(&'static str),
    At(&'static Location<'static>),
}

impl fmt::Display for TaskName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Named(name) => f.write_str(name),
            Self::At(at) => write!(f, "{}:{}", at.file(), at.line()),
        }
    }
}

static NEXT_TASK: AtomicU64 = AtomicU64::new(0);

tokio::task_local! {
    /// The scope task this code runs in (its id in the live tables).
    static CURRENT_TASK: u64;
}

/// Removes a finished (or aborted) task from every live table it is in, and
/// holds the ancestors' tracker tokens until then.
struct Running {
    id: u64,
    tables: Vec<Arc<Live>>,
    _ancestors: Vec<TaskTrackerToken>,
}

impl Drop for Running {
    fn drop(&mut self) {
        for table in &self.tables {
            table.lock().tasks.remove(&self.id);
        }
    }
}

/// What [`Scope::close`] saw: whether every task ended within the deadline,
/// and the ones it aborted because they did not.
#[derive(Debug, Clone, PartialEq, Eq)]
#[must_use = "a close report says which tasks ignored the cancellation"]
pub struct CloseReport {
    /// The scope's owner.
    pub owner: &'static str,
    /// The tasks still running at the deadline (by name, or by where they
    /// were spawned), sorted; they were aborted.
    pub still_running: Vec<String>,
}

impl CloseReport {
    /// Every task ended within the deadline.
    pub fn joined(&self) -> bool {
        self.still_running.is_empty()
    }
}

impl fmt::Display for CloseReport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.joined() {
            write!(f, "{}: every task joined", self.owner)
        } else {
            write!(
                f,
                "{}: {} task(s) ignored the cancellation and were aborted at the deadline: {}",
                self.owner,
                self.still_running.len(),
                self.still_running.join(", ")
            )
        }
    }
}

impl Scope {
    /// A scope for `owner` (the name its reports and warnings use).
    pub fn new(owner: &'static str) -> Self {
        Self {
            owner,
            tracker: TaskTracker::new(),
            cancel: CancellationToken::new(),
            live: Arc::default(),
            ancestors: Vec::new(),
            closed: AtomicBool::new(false),
        }
    }

    /// A scope inside this one: cancelled with it, and its tasks joined (and
    /// reported) by this one's close as well as its own.
    pub fn child(&self, owner: &'static str) -> Self {
        let mut ancestors = vec![(self.tracker.clone(), self.live.clone())];
        ancestors.extend(self.ancestors.iter().cloned());
        Self {
            owner,
            tracker: TaskTracker::new(),
            cancel: self.cancel.child_token(),
            live: Arc::default(),
            ancestors,
            closed: AtomicBool::new(false),
        }
    }

    /// The owner's name.
    pub fn owner(&self) -> &'static str {
        self.owner
    }

    /// Spawn `future` on the current runtime as one of this scope's tasks,
    /// reported by where it was spawned. It should end once
    /// [`Scope::cancelled`] resolves; one still running at a close's deadline
    /// is aborted.
    #[track_caller]
    pub fn spawn<F>(&self, future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        self.spawn_as(TaskName::At(Location::caller()), future)
    }

    /// [`Scope::spawn`], reported by `name`.
    pub fn spawn_named<F>(&self, name: &'static str, future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        self.spawn_as(TaskName::Named(name), future)
    }

    /// [`Scope::spawn_named`] for work that may simply stop at the
    /// cancellation (a retry loop, a wait, a projection that the next start
    /// redoes): `future` is dropped there, so the task never counts as
    /// ignoring it. `None` when it was cancelled first.
    pub fn spawn_until_cancelled<F>(
        &self,
        name: &'static str,
        future: F,
    ) -> JoinHandle<Option<F::Output>>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        let stop = self.cancelled();
        self.spawn_as(TaskName::Named(name), async move {
            tokio::select! {
                biased;
                () = stop => None,
                output = future => Some(output),
            }
        })
    }

    fn spawn_as<F>(&self, name: TaskName, future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        let id = NEXT_TASK.fetch_add(1, Ordering::Relaxed);
        let mut tables = vec![self.live.clone()];
        tables.extend(self.ancestors.iter().map(|(_, live)| live.clone()));
        for table in &tables {
            table.lock().tasks.insert(id, (name, None));
        }
        let running = Running {
            id,
            tables: tables.clone(),
            _ancestors: self.ancestors.iter().map(|(tracker, _)| tracker.token()).collect(),
        };
        // The task knows its own id: a task that holds the last handle of its owner drops the
        // owner, and this scope, as it ends, and that drop leaves the task itself out.
        let handle = self.tracker.spawn(CURRENT_TASK.scope(id, async move {
            let _running = running;
            future.await
        }));
        let abort = handle.abort_handle();
        for table in &tables {
            table.fill_in(id, &abort);
        }
        handle
    }

    /// Resolves once the scope is cancelled (by [`Scope::close`], a drop, or
    /// a parent's). Owned, so a task can move it in.
    pub fn cancelled(&self) -> WaitForCancellationFutureOwned {
        self.cancel.clone().cancelled_owned()
    }

    /// The scope's cancellation, for code that takes a token.
    pub fn token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    /// The scope was cancelled.
    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    /// How many of this scope's own tasks run now (a child's are not counted).
    pub fn len(&self) -> usize {
        self.tracker.len()
    }

    /// No task of this scope's own runs now.
    pub fn is_empty(&self) -> bool {
        self.tracker.is_empty()
    }

    /// The shutdown: cancel every task (children's too), wait at most
    /// `within` for them all to end, then abort and name the ones that did
    /// not. A task spawned while it waits starts already cancelled and is
    /// waited for too; one spawned after it returns (or whose spawn had not
    /// registered its abort handle by the deadline) is aborted by its spawn.
    pub async fn close(&self, within: Duration) -> CloseReport {
        self.closed.store(true, Ordering::SeqCst);
        self.cancel.cancel();
        self.tracker.close();
        let _ = tokio::time::timeout(within, self.tracker.wait()).await;
        CloseReport { owner: self.owner, still_running: self.live.abort_all() }
    }
}

impl fmt::Debug for Scope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Scope")
            .field("owner", &self.owner)
            .field("tasks", &self.tracker.len())
            .field("cancelled", &self.cancel.is_cancelled())
            .finish()
    }
}

/// A drop without close panics: this crate's tests, and debug builds run
/// with `CMUX_SCOPE_STRICT=1`.
fn strict() -> bool {
    cfg!(test)
        || (cfg!(debug_assertions)
            && std::env::var_os("CMUX_SCOPE_STRICT").is_some_and(|value| value == "1"))
}

impl Drop for Scope {
    fn drop(&mut self) {
        self.cancel.cancel();
        self.tracker.close();
        if self.closed.load(Ordering::SeqCst) {
            return;
        }
        // A task of this scope that drops it (it held the owner's last handle) is ending.
        let current = CURRENT_TASK.try_with(|id| *id).ok();
        let mut running: Vec<String> = self
            .live
            .lock()
            .tasks
            .iter()
            .filter(|(id, _)| Some(**id) != current)
            .map(|(_, (name, _))| name.to_string())
            .collect();
        if running.is_empty() {
            return;
        }
        running.sort();
        tracing::warn!(
            owner = self.owner,
            tasks = ?running,
            "a scope was dropped without close: its tasks were cancelled but not joined"
        );
        if strict() && !std::thread::panicking() {
            strict_failure(&format!(
                "the scope of {} was dropped without close while {} task(s) ran: {}",
                self.owner,
                running.len(),
                running.join(", ")
            ));
        }
    }
}

/// Strict mode only (tests, or a debug build with `CMUX_SCOPE_STRICT=1`): a scope dropped without
/// close fails the test that dropped it. Release builds only warn ([`Scope`]'s drop).
#[allow(clippy::panic, reason = "strict mode only: tests, or debug with CMUX_SCOPE_STRICT=1")]
fn strict_failure(message: &str) -> ! {
    // crash-allow: strict mode only (tests, or debug with CMUX_SCOPE_STRICT=1); release warns.
    panic!("{message}")
}

#[cfg(test)]
mod tests;
