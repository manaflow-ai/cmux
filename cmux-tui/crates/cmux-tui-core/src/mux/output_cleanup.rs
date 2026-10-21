//! The owner's side of the one-time output cleanup
//! (`workspace_registry::output_cleanup`): a low-priority thread that waits
//! a while after start, stages the registry's sealed segments (Phase A), and
//! holds back journal sealing while a cleanup is pending. The swap itself
//! runs at the next owner start, in `WorkspaceRegistry::open`.

use super::*;
use crate::workspace_registry::output_cleanup::{
    self, StageControl, StageOutcome, failed_path, stage_registry,
};

/// How long after start the cleanup waits, so it never competes with
/// session restore.
const START_DELAY: Duration = Duration::from_secs(60);

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
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(db_path) = registry.session_journal_database_path() else { return Ok(()) };
        if registry.output_cleanup_done()? {
            return Ok(());
        }
        drop(registry);
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
        let thread =
            std::thread::Builder::new().name("cmux-output-cleanup".into()).spawn(move || {
                lower_thread_priority();
                let delay =
                    env_duration("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS").unwrap_or(START_DELAY);
                if !worker_control.wait(delay) {
                    return;
                }
                let not_needed = run_output_cleanup(&db_path, &worker_control, &pending);
                if not_needed && let Some(mux) = weak_mux.upgrade() {
                    let marked = mux
                        .workspace_registry
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .mark_output_cleanup_done("not-needed");
                    if let Err(error) = marked {
                        eprintln!(
                            "cmux-tui: output cleanup: could not record the result: {error:#}"
                        );
                    }
                }
            })?;
        *self.output_cleanup.worker.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(OutputCleanupWorker { control, thread: Some(thread) });
        Ok(())
    }

    pub(super) fn stop_output_cleanup(&self) {
        let worker =
            self.output_cleanup.worker.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(mut worker) = worker {
            *worker.control.stopped.lock().unwrap_or_else(PoisonError::into_inner) = true;
            worker.control.changed.notify_all();
            if let Some(thread) = worker.thread.take()
                && thread.thread().id() != std::thread::current().id()
            {
                let _ = thread.join();
            }
        }
    }
}

/// Phase A for the registry at `db_path`. True when the registry holds no
/// stored output, so the caller records that the cleanup is done.
fn run_output_cleanup(db_path: &Path, control: &Control, pending: &AtomicBool) -> bool {
    let pause = env_duration("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_PAUSE_MS");
    let started = Instant::now();
    let outcome = stage_registry(
        db_path,
        &StageControl {
            on_pending: &|| pending.store(true, Ordering::Release),
            next_segment: &|| match pause {
                Some(pause) => control.wait(pause),
                None => !*control.stopped.lock().unwrap_or_else(PoisonError::into_inner),
            },
        },
    );
    match outcome {
        Ok(StageOutcome::NotNeeded) => {
            pending.store(false, Ordering::Release);
            return true;
        }
        Ok(StageOutcome::Complete { segments, kept }) => eprintln!(
            "cmux-tui: output cleanup: phase A complete in {:.2} s: {segments} segments \
             staged, {kept} records kept; the registry is swapped at the next start ({})",
            started.elapsed().as_secs_f64(),
            output_cleanup::staging_path(db_path).display()
        ),
        Ok(StageOutcome::Refused(reason)) => {
            pending.store(false, Ordering::Release);
            eprintln!(
                "cmux-tui: output cleanup: not enough free space, retried at the next start: {reason}"
            );
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
