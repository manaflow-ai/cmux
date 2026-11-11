//! The owner's side of the output cleanup and of the rebuild at a retention
//! floor (`workspace_registry::output_cleanup`): a low-priority thread that
//! waits a while after start, stages the registry's sealed segments and
//! builds the new registry from them (Phase A), keeps it current while the
//! owner serves, and holds back journal sealing while a cleanup is pending.
//! The swap itself runs at the next owner start, in `WorkspaceRegistry::open`.
//!
//! The join with retention (`mux/journal_segment_retention.rs`): a registry
//! the one-time cleanup is done for is built again only for a floor. The
//! retention pass names it ([`Mux::offer_rebuild_floor`]) when the sealed
//! segments at or below it hold enough records that deleting them in place
//! would leave the file at its size, and it deletes none of them while this
//! worker can still rebuild ([`Mux::journal_rebuild_possible`]). A rebuild
//! that is refused, skipped or fails ends that: the pass deletes in place.
//! So does a start beside the file that the last swap replaced: no worker
//! runs while that file is kept (at least 7 days and 3 full starts).

use super::*;
use crate::workspace_registry::output_cleanup::{
    self, StageControl, StageOutcome, failed_path, stage_registry,
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
    /// True while the worker of this start can still rebuild the registry
    /// at a retention floor. False with no worker, and once a rebuild was
    /// not needed, refused, skipped or failed.
    rebuild_possible: Arc<AtomicBool>,
    /// Retention ticks of this start that waited for the agent history fold
    /// before they named a rebuild floor.
    fold_waits: std::sync::atomic::AtomicU32,
    /// A test's count of records that are worth a rebuild (0: the
    /// product's), for the worker thread of that test's daemon.
    #[cfg(test)]
    records_limit_for_test: Arc<AtomicU64>,
    worker: Mutex<Option<OutputCleanupWorker>>,
}

struct Control {
    stopped: Mutex<bool>,
    changed: Condvar,
    /// The retention floor of the rebuild of this start (0: the retention
    /// pass named none yet). The first one stays.
    floor: AtomicU64,
}

impl Control {
    fn new() -> Self {
        Self { stopped: Mutex::new(false), changed: Condvar::new(), floor: AtomicU64::new(0) }
    }

    /// Names the floor of this start's rebuild and wakes the worker.
    fn offer_floor(&self, floor: u64) {
        if floor > 0
            && self.floor.compare_exchange(0, floor, Ordering::AcqRel, Ordering::Acquire).is_ok()
        {
            // Under the lock the worker waits on, so it cannot miss the wake.
            let _stopped = self.stopped.lock().unwrap_or_else(PoisonError::into_inner);
            self.changed.notify_all();
        }
    }

    /// Waits for a floor from the retention pass; `None` once stopped.
    fn wait_for_floor(&self) -> Option<u64> {
        let mut stopped = self.stopped.lock().unwrap_or_else(PoisonError::into_inner);
        loop {
            if *stopped {
                return None;
            }
            let floor = self.floor.load(Ordering::Acquire);
            if floor > 0 {
                return Some(floor);
            }
            stopped = self.changed.wait(stopped).unwrap_or_else(PoisonError::into_inner);
        }
    }

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

/// Ends [`OutputCleanupState::rebuild_possible`] when the worker thread ends,
/// a panic included: the retention pass then deletes in place.
///
/// It then wakes the journal maintenance worker: a retention pass that gave
/// way to this worker has settled, and a settled worker sleeps until the
/// journal changes (an idle daemon: up to the hourly ledger scan).
struct NoRebuildAfter(Arc<AtomicBool>, Arc<journal_maintenance::JournalMaintenanceControl>);

impl Drop for NoRebuildAfter {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
        self.1.note_change();
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

    /// True while the cleanup worker of this start can still rebuild the
    /// registry at a retention floor: the retention pass then leaves a run
    /// that is worth a rebuild to it.
    pub(crate) fn journal_rebuild_possible(&self) -> bool {
        self.output_cleanup.rebuild_possible.load(Ordering::Acquire)
    }

    /// Retention ticks that waited for the agent history fold so far.
    pub(super) fn journal_rebuild_fold_waits(&self) -> u32 {
        self.output_cleanup.fold_waits.load(Ordering::Acquire)
    }

    /// Counts one more such tick; the count with it.
    pub(super) fn note_journal_rebuild_fold_wait(&self) -> u32 {
        self.output_cleanup.fold_waits.fetch_add(1, Ordering::AcqRel).saturating_add(1)
    }

    /// Names the retention floor for the cleanup worker, which builds the
    /// registry again without the records at or below it. The first floor
    /// of a start is the one its rebuild uses.
    pub(super) fn offer_rebuild_floor(&self, floor: u64) {
        let worker = self.output_cleanup.worker.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(worker) = worker.as_ref() {
            worker.control.offer_floor(floor);
        }
    }

    /// The count of records that are worth a rebuild, for a test: on the
    /// calling thread (the test's own maintenance ticks) and on the cleanup
    /// worker of this daemon, so the two agree as they do in the product.
    #[cfg(test)]
    pub(crate) fn set_rebuild_records_limit_for_test(&self, limit: u64) {
        output_cleanup::set_put_records_limit_for_test(limit);
        self.output_cleanup.records_limit_for_test.store(limit, Ordering::Release);
    }

    pub(super) fn start_output_cleanup(self: &Arc<Self>) -> anyhow::Result<()> {
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(db_path) = registry.session_journal_database_path() else { return Ok(()) };
        // A registry the one-time cleanup is done for is staged again only
        // for a retention floor, which the retention pass names later.
        let done = registry.output_cleanup_done()?;
        drop(registry);
        if output_cleanup::failed_for_this_build(&db_path) {
            eprintln!(
                "cmux-tui: output cleanup: skipped; an earlier attempt failed (see {})",
                failed_path(&db_path).display()
            );
            return Ok(());
        }
        // The file that the last swap replaced is still beside the registry
        // (`output_cleanup/backup.rs`): the swap of a new rebuild would
        // replace it. No worker in this start, so the retention pass deletes
        // in place (`rebuild_possible` stays false).
        if output_cleanup::backup_held(&db_path) {
            eprintln!(
                "cmux-tui: output cleanup: no rebuild in this start; the registry that the last \
                 swap replaced is still kept beside this one"
            );
            return Ok(());
        }
        // A staged registry from an earlier start: no sealing during the
        // start delay either (Phase A would have to stage those segments).
        let resume = output_cleanup::staging_path(&db_path).is_file();
        if resume {
            self.output_cleanup.pending.store(true, Ordering::Release);
        }
        let control = Arc::new(Control::new());
        let worker_control = control.clone();
        let pending = self.output_cleanup.pending.clone();
        let rebuild_possible = self.output_cleanup.rebuild_possible.clone();
        let weak_mux = Arc::downgrade(self);
        let maintenance = self.journal_maintenance_control.clone();
        #[cfg(test)]
        let records_limit_for_test = self.output_cleanup.records_limit_for_test.clone();
        let (exited_sender, exited) = std::sync::mpsc::channel::<()>();
        // Before the thread runs: the retention pass must not delete in
        // place what this worker is about to rebuild.
        rebuild_possible.store(true, Ordering::Release);
        let spawned =
            std::thread::Builder::new().name("cmux-output-cleanup".into()).spawn(move || {
                let _exited = exited_sender;
                // However the worker ends, no rebuild starts after it.
                let _no_rebuild = NoRebuildAfter(rebuild_possible, maintenance.clone());
                lower_thread_priority();
                let delay =
                    env_duration("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS").unwrap_or(START_DELAY);
                if !worker_control.wait(delay) {
                    return;
                }
                let mut done = done;
                let mut resume = resume;
                loop {
                    let floor = if resume {
                        // The staging file of an earlier start: the retention
                        // pass waits for it (it is pending), so its floor is
                        // read here, from the registry alone.
                        resume = false;
                        output_cleanup::registry_retention_floor(&db_path).unwrap_or_else(|error| {
                            eprintln!(
                                "cmux-tui: output cleanup: the retention floor could not be \
                                     read; resuming without one: {error:#}"
                            );
                            0
                        })
                    } else if done {
                        let Some(floor) = worker_control.wait_for_floor() else { return };
                        floor
                    } else {
                        // The one-time cleanup, at the floor the retention
                        // pass named during the start delay (if any).
                        worker_control.floor.load(Ordering::Acquire)
                    };
                    #[cfg(test)]
                    match records_limit_for_test.load(Ordering::Acquire) {
                        0 => {}
                        limit => output_cleanup::set_put_records_limit_for_test(limit),
                    }
                    let outcome = run_output_cleanup(&db_path, floor, &worker_control, &pending);
                    if worker_control.is_stopped() {
                        return;
                    }
                    match outcome {
                        CleanupOutcome::NotNeeded => {}
                        // The one-time cleanup would keep too much of the
                        // journal (most of it is not output): a rebuild at a
                        // retention floor is another question, asked below.
                        CleanupOutcome::Skipped if floor == 0 => {
                            done = true;
                            // The retention pass gave way while this pass
                            // was pending and its worker may have settled:
                            // the next tick names the floor.
                            maintenance.note_change();
                            continue;
                        }
                        CleanupOutcome::Skipped | CleanupOutcome::Ended => return,
                    }
                    // A registry already marked keeps its mark: a swap's mark
                    // names the backup's registry until the backup is removed.
                    if !done && let Some(mux) = weak_mux.upgrade() {
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
                    if floor > 0 {
                        // Nothing to rebuild at the floor of this start.
                        return;
                    }
                    // No stored output: from here the worker waits for a
                    // retention floor, as for a registry that was done.
                    done = true;
                    maintenance.note_change();
                }
            });
        let thread = match spawned {
            Ok(thread) => thread,
            Err(error) => {
                self.output_cleanup.rebuild_possible.store(false, Ordering::Release);
                return Err(error.into());
            }
        };
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

/// How one pass of the worker ended.
enum CleanupOutcome {
    /// Nothing to clean up at this floor: at floor 0 the caller records
    /// that the one-time cleanup is done.
    NotNeeded,
    /// The pass would keep too much of the journal; the registry is
    /// unchanged and no staging file is left.
    Skipped,
    /// Built (and kept current until the owner stopped), stopped, refused
    /// for free space, or failed: the worker of this start is done.
    Ended,
}

/// Phase A for the registry at `db_path`.
fn run_output_cleanup(
    db_path: &Path,
    floor: u64,
    control: &Arc<Control>,
    pending: &AtomicBool,
) -> CleanupOutcome {
    let pause = env_duration("CMUX_TUI_TEST_OUTPUT_CLEANUP_SEGMENT_PAUSE_MS");
    let catch_up =
        env_duration("CMUX_TUI_TEST_OUTPUT_CLEANUP_CATCH_UP_MS").unwrap_or(CATCH_UP_INTERVAL);
    let stop_control = control.clone();
    let outcome = stage_registry(
        db_path,
        floor,
        &StageControl {
            on_pending: &|| pending.store(true, Ordering::Release),
            next_segment: &|| match pause {
                Some(pause) => control.wait(pause),
                None => !control.is_stopped(),
            },
            catch_up: &|| control.wait(catch_up),
            stopped: Arc::new(move || stop_control.is_stopped()),
        },
    );
    match outcome {
        Ok(StageOutcome::NotNeeded) => {
            pending.store(false, Ordering::Release);
            return CleanupOutcome::NotNeeded;
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
            return CleanupOutcome::Skipped;
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
    CleanupOutcome::Ended
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
        let control = Arc::new(Control::new());
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

    #[test]
    fn a_worker_that_waits_for_a_floor_takes_the_first_one_and_ends_at_a_stop() {
        let control = Arc::new(Control::new());
        control.offer_floor(0);
        control.offer_floor(7);
        control.offer_floor(9);
        assert_eq!(control.wait_for_floor(), Some(7), "the first floor of a start stays");

        let control = Arc::new(Control::new());
        let (exited_sender, exited) = std::sync::mpsc::channel::<()>();
        let worker_control = control.clone();
        let thread = std::thread::spawn(move || {
            let _exited = exited_sender;
            assert_eq!(worker_control.wait_for_floor(), None);
        });
        let worker = OutputCleanupWorker { control, thread: Some(thread), exited };
        let started = Instant::now();
        worker.stop(Duration::from_secs(5));
        assert!(started.elapsed() < Duration::from_secs(5), "a stop did not end the wait");
    }

    #[test]
    fn a_stop_joins_a_worker_that_ends() {
        let worker = worker_blocked_on(Arc::new(Mutex::new(())));
        worker.stop(Duration::from_secs(5));
    }
}
