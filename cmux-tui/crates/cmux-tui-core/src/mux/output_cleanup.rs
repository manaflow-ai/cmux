//! The owner's side of the one-time output cleanup
//! (`workspace_registry::output_cleanup`): a low-priority thread that waits
//! a while after start, stages the registry's sealed segments and builds the
//! new registry from them (Phase A), keeps it current while the owner serves,
//! and holds back journal sealing while a cleanup is pending. The swap itself
//! runs at the next owner start, in `WorkspaceRegistry::open`.
//!
//! The same thread runs the journal compaction
//! (`workspace_registry::output_cleanup::journal_compact`) instead, only when
//! the daemon was started with `CMUX_TUI_JOURNAL_COMPACT=1` and the registry
//! was not compacted yet. Without that variable nothing here changes.

use super::*;
use crate::workspace_registry::output_cleanup::{
    self, CleanupMode, StageControl, StageOutcome, failed_path, journal_compact, stage_registry_in,
};

/// How long after start the cleanup waits, so it never competes with
/// session restore.
const START_DELAY: Duration = Duration::from_secs(60);

/// How often the built registry takes in the records appended since, so the
/// swap at the next start packs only a short tail.
const CATCH_UP_INTERVAL: Duration = Duration::from_secs(30);

/// How long a stop waits for the worker. Its last step (recording "not
/// needed") takes the registry and its connection locks, which a stalled
/// journal commit can hold; shutdown must not wait on them without a limit.
const STOP_WAIT: Duration = Duration::from_secs(2);

#[derive(Default)]
pub(super) struct OutputCleanupState {
    /// Set while a registry is staged or being staged: journal maintenance
    /// seals no more live rows (they are almost all output to be removed).
    pending: Arc<AtomicBool>,
    worker: Mutex<Option<OutputCleanupWorker>>,
}

struct Control {
    stopped: Mutex<bool>,
    changed: Condvar,
}

impl Control {
    fn is_stopped(&self) -> bool {
        *self.stopped.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Waits up to `timeout` unless stopped first; false once stopped.
    fn wait(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut stopped = self.stopped.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if *stopped {
                return false;
            }
            let now = Instant::now();
            if now >= deadline {
                return true;
            }
            stopped = self
                .changed
                .wait_timeout(stopped, deadline - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }
}

struct OutputCleanupWorker {
    control: Arc<Control>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// Disconnects when the worker thread ends (its sender drops, panics
    /// included).
    exited: Receiver<()>,
}

impl OutputCleanupWorker {
    /// Stops the worker and joins it, waiting at most `wait`: a worker still
    /// blocked after that is left to finish on its own.
    fn stop(mut self, wait: Duration) {
        *self.control.stopped.lock().unwrap_or_else(PoisonError::into_inner) = true;
        self.control.changed.notify_all();
        let Some(thread) = self.thread.take() else { return };
        // The last `Arc<Mux>` can drop on the worker itself; it must not
        // join its own thread.
        if thread.thread().id() == std::thread::current().id() {
            return;
        }
        match self.exited.recv_timeout(wait) {
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => eprintln!(
                "cmux-tui: output cleanup: the worker did not stop within {:.1} s; \
                 shutdown goes on without it",
                wait.as_secs_f64()
            ),
            _ => {
                let _ = thread.join();
            }
        }
    }
}

fn env_duration(_name: &str) -> Option<Duration> {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var(_name).ok().and_then(|value| value.parse::<u64>().ok()) {
        return Some(Duration::from_millis(ms));
    }
    None
}

impl Mux {
    pub(crate) fn output_cleanup_pending(&self) -> bool {
        self.output_cleanup.pending.load(Ordering::Acquire)
    }

    pub(super) fn start_output_cleanup(self: &Arc<Self>) -> anyhow::Result<()> {
        // The opt-in is read here, once per owner start.
        self.start_cleanup(journal_compact::requested_by_env())
    }

    /// Starts the cleanup thread when this registry has a cleanup to run:
    /// the journal compaction with `compact_requested` (the opt-in) on a
    /// registry not compacted yet, else the output cleanup when not done.
    fn start_cleanup(self: &Arc<Self>, compact_requested: bool) -> anyhow::Result<()> {
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(db_path) = registry.session_journal_database_path() else { return Ok(()) };
        let Some(mode) = journal_compact::scheduled_mode(
            compact_requested,
            compact_requested && registry.cleanup_done(CleanupMode::Compact)?,
            registry.output_cleanup_done()?,
        ) else {
            return Ok(());
        };
        drop(registry);
        if mode == CleanupMode::Compact {
            eprintln!(
                "cmux-tui: output cleanup: {}=1, the journal compaction runs for this registry",
                journal_compact::OPT_IN_ENV
            );
        }
        if output_cleanup::failed_for_this_build(&db_path) {
            eprintln!(
                "cmux-tui: output cleanup: skipped; an earlier attempt failed (see {})",
                failed_path(&db_path).display()
            );
            return Ok(());
        }
        // A staged registry from an earlier start: no sealing during the
        // start delay either (Phase A would have to stage those segments).
        if output_cleanup::staging_path(&db_path).is_file() {
            self.output_cleanup.pending.store(true, Ordering::Release);
        }
        let control = Arc::new(Control { stopped: Mutex::new(false), changed: Condvar::new() });
        let worker_control = control.clone();
        let pending = self.output_cleanup.pending.clone();
        let weak_mux = Arc::downgrade(self);
        let (exited_sender, exited) = std::sync::mpsc::channel::<()>();
        let thread =
            std::thread::Builder::new().name("cmux-output-cleanup".into()).spawn(move || {
                let _exited = exited_sender;
                lower_thread_priority();
                let delay =
                    env_duration("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS").unwrap_or(START_DELAY);
                if !worker_control.wait(delay) {
                    return;
                }
                let not_needed = run_output_cleanup(&db_path, &worker_control, &pending, mode);
                if not_needed
                    && !worker_control.is_stopped()
                    && let Some(mux) = weak_mux.upgrade()
                {
                    let marked = mux
                        .workspace_registry
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .mark_cleanup_done(mode, "not-needed");
                    if let Err(error) = marked {
                        eprintln!(
                            "cmux-tui: output cleanup: could not record the result: {error:#}"
                        );
                    }
                }
            })?;
        *self.output_cleanup.worker.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(OutputCleanupWorker { control, thread: Some(thread), exited });
        Ok(())
    }

    pub(super) fn stop_output_cleanup(&self) {
        let worker =
            self.output_cleanup.worker.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(worker) = worker {
            worker.stop(STOP_WAIT);
        }
    }
}

/// Phase A for the registry at `db_path`. True when the registry holds no
/// stored output, so the caller records that the cleanup is done.
fn run_output_cleanup(
    db_path: &Path,
    control: &Arc<Control>,
    pending: &AtomicBool,
    mode: CleanupMode,
) -> bool {
    let pause = env_duration("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_PAUSE_MS");
    let catch_up =
        env_duration("CMUX_TUI_TEST_OUTPUT_CLEANUP_CATCH_UP_MS").unwrap_or(CATCH_UP_INTERVAL);
    let stop_control = control.clone();
    let outcome = stage_registry_in(
        db_path,
        &StageControl {
            on_pending: &|| pending.store(true, Ordering::Release),
            next_segment: &|| match pause {
                Some(pause) => control.wait(pause),
                None => !control.is_stopped(),
            },
            catch_up: &|| control.wait(catch_up),
            stopped: Arc::new(move || stop_control.is_stopped()),
        },
        mode,
    );
    match outcome {
        Ok(StageOutcome::NotNeeded) => {
            pending.store(false, Ordering::Release);
            return true;
        }
        Ok(StageOutcome::Built) => {}
        Ok(StageOutcome::Refused(reason)) => {
            pending.store(false, Ordering::Release);
            eprintln!(
                "cmux-tui: output cleanup: not enough free space, retried at the next start: {reason}"
            );
        }
        Ok(StageOutcome::Skipped(reason)) => {
            pending.store(false, Ordering::Release);
            eprintln!("cmux-tui: output cleanup: skipped, the registry is unchanged: {reason}");
        }
        Ok(StageOutcome::Stopped) => {
            eprintln!("cmux-tui: output cleanup: stopped; it resumes at the next start");
        }
        Err(error) => {
            pending.store(false, Ordering::Release);
            eprintln!(
                "cmux-tui: output cleanup: staging failed, retried at the next start: {error:#}"
            );
        }
    }
    false
}

/// Background QoS on macOS; lowest CPU and idle IO priority for this thread
/// on Linux. Elsewhere the thread keeps its default priority.
fn lower_thread_priority() {
    #[cfg(target_vendor = "apple")]
    // SAFETY: sets the calling thread's own QoS class; no pointers.
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_BACKGROUND, 0);
    }
    #[cfg(target_os = "linux")]
    // SAFETY: plain syscalls on the calling thread's own id.
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
        libc::setpriority(libc::PRIO_PROCESS, tid, 19);
        // ioprio_set(IOPRIO_WHO_PROCESS, tid, IOPRIO_CLASS_IDLE).
        libc::syscall(libc::SYS_ioprio_set, 1, tid, 3 << 13);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn worker_blocked_on(lock: Arc<Mutex<()>>) -> OutputCleanupWorker {
        let control = Arc::new(Control { stopped: Mutex::new(false), changed: Condvar::new() });
        let (exited_sender, exited) = std::sync::mpsc::channel::<()>();
        let thread = std::thread::spawn(move || {
            let _exited = exited_sender;
            // The final record waits on a lock a stalled journal commit holds.
            drop(lock.lock().unwrap_or_else(PoisonError::into_inner));
        });
        OutputCleanupWorker { control, thread: Some(thread), exited }
    }

    #[test]
    fn a_stop_returns_while_the_worker_waits_on_a_held_registry_lock() {
        let lock = Arc::new(Mutex::new(()));
        let held = lock.lock().unwrap();
        let worker = worker_blocked_on(lock.clone());
        let started = Instant::now();
        worker.stop(Duration::from_millis(200));
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "a stop waited without a limit for a worker blocked on the registry lock"
        );
        drop(held);
    }

    /// Without the opt-in the owner schedules what it did before the
    /// compaction existed: the output cleanup while that is not done, and
    /// nothing after. The compaction is scheduled only with the opt-in, once.
    #[test]
    fn the_journal_compaction_is_scheduled_only_with_the_opt_in() {
        use journal_compact::{requested, scheduled_mode};
        use std::ffi::OsStr;
        assert!(!requested(None), "the compaction is on without its variable");
        for value in ["", "0", "true", "yes", "2"] {
            assert!(!requested(Some(OsStr::new(value))), "{value:?} turns the compaction on");
        }
        assert!(requested(Some(OsStr::new("1"))));
        for compact_done in [false, true] {
            assert_eq!(scheduled_mode(false, compact_done, true), None);
            assert_eq!(scheduled_mode(false, compact_done, false), Some(CleanupMode::Output));
        }
        assert_eq!(scheduled_mode(true, false, true), Some(CleanupMode::Compact));
        assert_eq!(scheduled_mode(true, false, false), Some(CleanupMode::Compact));
        assert_eq!(scheduled_mode(true, true, true), None, "the compaction runs once");
        assert_eq!(scheduled_mode(true, true, false), Some(CleanupMode::Output));
    }

    #[test]
    fn a_stop_joins_a_worker_that_ends() {
        let worker = worker_blocked_on(Arc::new(Mutex::new(())));
        worker.stop(Duration::from_secs(5));
    }
}
