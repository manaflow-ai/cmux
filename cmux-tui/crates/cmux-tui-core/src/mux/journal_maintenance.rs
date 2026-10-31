//! Journal maintenance: hook delivery dispatch, internal diagnostics, reconnect checkpoints, journal checkpoints and segments, the periodic maintenance worker, and their test hooks.

use super::*;

const JOURNAL_MAINTENANCE_INTERVAL: Duration = Duration::from_secs(30);
const JOURNAL_MAINTENANCE_CHECKPOINT_RECORDS: u64 = 4_096;
const JOURNAL_MAINTENANCE_SEAL_BATCHES_PER_TICK: usize = 8;
/// A maintenance tick this long is logged: its steps hold the workspace
/// registry lock that `tab.update` and `list-workspaces` wait on, so a slow
/// tick stalls the app's requests (a 12-15 s stall on 2026-10-21 left no
/// trace of its cause).
const SLOW_MAINTENANCE_TICK: Duration = Duration::from_millis(500);

/// How long each step of one maintenance tick took.
#[derive(Default)]
struct MaintenanceSteps {
    steps: Vec<(&'static str, Duration)>,
}

impl MaintenanceSteps {
    fn time<T>(&mut self, step: &'static str, run: impl FnOnce() -> T) -> T {
        let started = Instant::now();
        let value = run();
        self.record(step, started.elapsed());
        value
    }

    fn record(&mut self, step: &'static str, took: Duration) {
        self.steps.push((step, took));
    }

    /// One line naming the tick's total and its slowest step, when the tick
    /// took at least `threshold`.
    fn slow_report(&self, threshold: Duration) -> Option<String> {
        let total: Duration = self.steps.iter().map(|(_, took)| *took).sum();
        if total < threshold {
            return None;
        }
        let (slowest, took) = self.steps.iter().max_by_key(|(_, took)| *took)?;
        Some(format!(
            "slow journal maintenance: {} ms ({} steps; slowest {slowest} {} ms)",
            total.as_millis(),
            self.steps.len(),
            took.as_millis()
        ))
    }
}

/// Debug builds only: overrides [`JOURNAL_MAINTENANCE_INTERVAL`] so behavior
/// tests through the binary see maintenance ticks in seconds. Release builds
/// ignore it.
#[cfg(debug_assertions)]
const JOURNAL_MAINTENANCE_INTERVAL_TEST_ENV: &str = "CMUX_TUI_TEST_JOURNAL_MAINTENANCE_INTERVAL_MS";

fn journal_maintenance_interval() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) = std::env::var(JOURNAL_MAINTENANCE_INTERVAL_TEST_ENV)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|ms| *ms > 0)
    {
        return Duration::from_millis(ms);
    }
    JOURNAL_MAINTENANCE_INTERVAL
}

#[derive(Default)]
struct ControlState {
    stopped: bool,
    /// A journal commit was published since the worker last started a tick.
    journal_changed: bool,
    /// The worker sleeps until the journal changes: only then does a commit
    /// notify it, so commits never wake it while it waits out an interval.
    waiting_for_change: bool,
}

/// The worker's stop signal and its "the registry changed" wake. The mux owns
/// it from construction, so every [`Mux::publish_journal_event`] (and a
/// ledger write that publishes none) can mark it.
#[derive(Default)]
pub(super) struct JournalMaintenanceControl {
    state: Mutex<ControlState>,
    changed: Condvar,
}

impl JournalMaintenanceControl {
    fn lock(&self) -> MutexGuard<'_, ControlState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The registry changed (a published journal event, or a write that
    /// fills a mutation ledger without one). Wakes the worker only when it
    /// sleeps until the next change, and only for the first of a burst.
    pub(super) fn note_change(&self) {
        let mut state = self.lock();
        if !state.journal_changed {
            state.journal_changed = true;
            if state.waiting_for_change {
                self.changed.notify_all();
            }
        }
    }

    fn stop(&self) {
        self.lock().stopped = true;
        self.changed.notify_all();
    }

    /// Blocks until the journal changed since the last tick started, or
    /// until `fallback`. False once stopped.
    fn wait_for_change(&self, fallback: Duration) -> bool {
        let deadline = Instant::now() + fallback;
        let mut state = self.lock();
        state.waiting_for_change = true;
        while !state.stopped && !state.journal_changed {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else { break };
            state =
                self.changed.wait_timeout(state, left).unwrap_or_else(PoisonError::into_inner).0;
        }
        state.waiting_for_change = false;
        !state.stopped
    }

    /// Waits out `interval`, so the changes it gathers share one tick, then
    /// starts the tick: later changes count for the next one. False once
    /// stopped.
    fn wait_interval_then_start_tick(&self, interval: Duration) -> bool {
        let deadline = Instant::now() + interval;
        let mut state = self.lock();
        while !state.stopped {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else { break };
            state =
                self.changed.wait_timeout(state, left).unwrap_or_else(PoisonError::into_inner).0;
        }
        state.journal_changed = false;
        !state.stopped
    }
}

/// Whether a maintenance tick left work for the next one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TickOutcome {
    /// More to do (a bounded batch, a retry, a pause): tick again after the
    /// interval.
    WorkRemains,
    /// Nothing left: the next tick waits for a journal change.
    Settled,
}

/// The journal maintenance worker of a persistent session: a tick bounds and
/// scans the mutation ledgers, migrates a legacy registry to incremental
/// auto-vacuum, takes a checkpoint after enough new records, seals bounded
/// segments up to the latest checkpoint, and returns free pages. Ticks are
/// at least one interval apart. Once a tick finds nothing left to do, the
/// worker sleeps until the journal changes, so an idle daemon does not wake
/// for maintenance (it used to tick every 30 s for good); the ledger scan
/// interval bounds that sleep, so the hourly ledger scan still runs.
pub(super) struct JournalMaintenance {
    control: Arc<JournalMaintenanceControl>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl JournalMaintenance {
    fn start(mux: &Arc<Mux>) -> anyhow::Result<Self> {
        let control = mux.journal_maintenance_control.clone();
        let worker_control = control.clone();
        let weak_mux = Arc::downgrade(mux);
        let interval = journal_maintenance_interval();
        let thread = std::thread::Builder::new().name("cmux-journal-maintenance".into()).spawn(
            move || {
                let mut ledgers = ledger_maintenance::LedgerMaintenance::default();
                let mut outcome = TickOutcome::WorkRemains;
                loop {
                    if outcome == TickOutcome::Settled
                        && !worker_control.wait_for_change(ledger_maintenance::LEDGER_SCAN_INTERVAL)
                    {
                        return;
                    }
                    if !worker_control.wait_interval_then_start_tick(interval) {
                        return;
                    }
                    let Some(mux) = weak_mux.upgrade() else { return };
                    outcome = mux.run_journal_maintenance(&mut ledgers);
                }
            },
        )?;
        Ok(Self { control, thread: Some(thread) })
    }

    pub(super) fn stop(mut self) {
        self.control.stop();
        if let Some(thread) = self.thread.take() {
            // The last `Arc<Mux>` can drop on the worker itself; it must not
            // join its own thread.
            if thread.thread().id() != std::thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

impl Drop for JournalMaintenance {
    /// A mux dropped without a shutdown still ends its worker, which may
    /// sleep until the next journal change.
    fn drop(&mut self) {
        self.control.stop();
    }
}

impl Mux {
    pub(super) fn start_journal_maintenance(self: &Arc<Self>) -> anyhow::Result<()> {
        if self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .session_journal_database_path()
            .is_some()
        {
            let maintenance = JournalMaintenance::start(self)?;
            *self.journal_maintenance.lock().unwrap_or_else(PoisonError::into_inner) =
                Some(maintenance);
        }
        Ok(())
    }

    pub(super) fn stop_journal_maintenance(&self) {
        let maintenance =
            self.journal_maintenance.lock().unwrap_or_else(PoisonError::into_inner).take();
        if let Some(maintenance) = maintenance {
            maintenance.stop();
        }
    }

    /// Once per owner: a legacy registry too large to convert without a
    /// long stall keeps its free pages (cx-4bd8m).
    fn note_auto_vacuum_deferred(&self, live_bytes: u64) {
        static NOTED: AtomicBool = AtomicBool::new(false);
        if NOTED.swap(true, Ordering::Relaxed) {
            return;
        }
        eprintln!(
            "cmux-tui: session journal auto-vacuum conversion deferred: {} MiB live data",
            live_bytes / (1024 * 1024)
        );
        self.report_internal_diagnostic(
            "session journal auto-vacuum conversion deferred; the registry keeps its free pages",
        );
    }

    /// Like the reconnect retention worker: no maintenance while the daemon
    /// shuts down, hands off its hosts, or ends terminals.
    pub(super) fn journal_maintenance_paused(&self) -> bool {
        self.shutting_down.load(Ordering::Acquire)
            || self.journal_retention.teardown_active()
            || self.control_clients.daemon_handoff_in_progress()
    }

    /// One tick; [`TickOutcome::Settled`] only when nothing is left: the
    /// ledgers are within their bounds, no migration, checkpoint or seal is
    /// due, and no free page waits for the incremental vacuum.
    fn run_journal_maintenance(
        &self,
        ledgers: &mut ledger_maintenance::LedgerMaintenance,
    ) -> TickOutcome {
        if self.journal_maintenance_paused() {
            return TickOutcome::WorkRemains;
        }
        let mut steps = MaintenanceSteps::default();
        let ledgers_remain = steps.time("ledgers", || self.run_ledger_maintenance(ledgers));
        // The roster cursor follows the head, so a start replays one tick. A
        // settled worker wakes on every journal change, so the head never
        // moves without a tick that catches the roster up.
        steps.time("agent_roster", || self.catch_up_agent_roster());
        let result = (|| -> anyhow::Result<TickOutcome> {
            let migration = steps.time("auto_vacuum_migration", || {
                self.workspace_registry
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .migrate_journal_auto_vacuum()
            })?;
            match migration {
                // A legacy registry migration performs one full VACUUM. Keep
                // that rewrite isolated to this maintenance tick before
                // attempting checkpoint or sealing work.
                crate::workspace_registry::AutoVacuumMigration::Converted => {
                    return Ok(TickOutcome::WorkRemains);
                }
                crate::workspace_registry::AutoVacuumMigration::Deferred { live_bytes } => {
                    self.note_auto_vacuum_deferred(live_bytes);
                }
                crate::workspace_registry::AutoVacuumMigration::NotNeeded => {}
            }
            let head = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .session_journal_head()?;
            let latest = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .journal_checkpoints()?
                .into_iter()
                .next();
            let checkpoint_source = latest.map_or(0, |checkpoint| checkpoint.source_sequence);
            let mut sealed_through = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .journal_segments_end()?;
            let pending_seal = checkpoint_source > sealed_through;
            if !pending_seal
                && head.saturating_sub(checkpoint_source) < JOURNAL_MAINTENANCE_CHECKPOINT_RECORDS
            {
                let pages_remain = steps.time("incremental_vacuum", || {
                    self.workspace_registry
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .incremental_journal_vacuum()
                })?;
                return Ok(if pages_remain {
                    TickOutcome::WorkRemains
                } else {
                    TickOutcome::Settled
                });
            }

            let target = if pending_seal {
                checkpoint_source
            } else {
                let checkpoint_key = format!("auto_checkpoint_{head}");
                steps
                    .time("checkpoint", || {
                        self.create_journal_checkpoint("journal-maintenance", &checkpoint_key)
                    })?
                    .checkpoint
                    .source_sequence
            };
            if target == 0 {
                return Ok(TickOutcome::WorkRemains);
            }
            // The live rows are almost all output that the pending cleanup
            // removes; sealing them first is wasted work. The seal waits, so
            // work remains: a settled worker would sleep past the cleanup.
            if self.output_cleanup_pending() {
                return Ok(TickOutcome::WorkRemains);
            }

            for batch in 0..JOURNAL_MAINTENANCE_SEAL_BATCHES_PER_TICK {
                if sealed_through >= target {
                    break;
                }
                let key = format!("auto_segment_{target}_{batch}_{sealed_through}");
                let commit = steps.time("seal", || {
                    self.seal_journal_segments(target, "journal-maintenance", &key)
                })?;
                if commit.through_sequence <= sealed_through {
                    break;
                }
                sealed_through = commit.through_sequence;
            }
            steps.time("incremental_vacuum", || {
                self.workspace_registry
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .incremental_journal_vacuum()
            })?;
            // A checkpoint or seal changed the journal: the next tick checks
            // again, and settles once there is nothing left.
            Ok(TickOutcome::WorkRemains)
        })();
        if let Some(report) = steps.slow_report(SLOW_MAINTENANCE_TICK) {
            eprintln!("cmux-tui: {report}");
            self.report_internal_diagnostic(report);
        }
        match result {
            Ok(TickOutcome::Settled) if !ledgers_remain => TickOutcome::Settled,
            Ok(_) => TickOutcome::WorkRemains,
            Err(error) => {
                eprintln!("cmux-tui: journal maintenance deferred: {error:#}");
                self.report_internal_diagnostic(
                    "journal maintenance deferred; checkpoint maintenance will retry",
                );
                TickOutcome::WorkRemains
            }
        }
    }
}

impl Mux {
    pub(crate) fn journal_hook_states(
        &self,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookState>> {
        self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner).journal_hook_states()
    }

    pub(crate) fn journal_events_caused_by_hooks(
        &self,
        hook_ids: &[String],
        event_ids: &[String],
    ) -> anyhow::Result<HashSet<(String, String)>> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_events_caused_by_hooks(hook_ids, event_ids)
    }

    pub(crate) fn put_journal_hook(
        self: &Arc<Self>,
        manifest: &crate::JournalHookManifest,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::JournalAppendCommit> {
        let commit = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .put_journal_hook(manifest, origin, idempotency_key)?;
        if !commit.replayed {
            self.publish_journal_event();
        }
        crate::journal_hooks::start(self)?;
        Ok(commit)
    }

    pub(crate) fn try_claim_journal_hook_dispatcher(&self) -> bool {
        self.journal_hook_dispatcher_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    pub(crate) fn journal_hook_runtime(&self) -> Arc<crate::journal_hooks::JournalHookRuntime> {
        self.journal_hook_runtime.clone()
    }

    pub(crate) fn release_journal_hook_dispatcher(&self) {
        self.journal_hook_dispatcher_started.store(false, Ordering::Release);
    }

    pub(crate) fn schedule_journal_hook_deliveries(
        &self,
        scans: &[crate::workspace_registry::JournalHookScan],
    ) -> anyhow::Result<Vec<bool>> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .schedule_journal_hook_deliveries(scans)
    }

    /// When the next scheduled hook retry is due, if any.
    pub(crate) fn next_journal_hook_attempt_deadline(&self) -> anyhow::Result<Option<Instant>> {
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        let next = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .next_journal_hook_attempt_at_ms()?;
        Ok(next.map(|at| Instant::now() + Duration::from_millis(at.saturating_sub(now_ms))))
    }

    pub(crate) fn pending_journal_hook_deliveries(
        &self,
        limit: usize,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookDelivery>> {
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pending_journal_hook_deliveries(now_ms, limit)
    }

    pub(crate) fn start_journal_hook_deliveries(
        &self,
        deliveries: &[crate::workspace_registry::JournalHookDelivery],
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalHookAttempt>> {
        let attempts = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .start_journal_hook_deliveries(deliveries)?;
        if !attempts.is_empty() {
            self.publish_journal_event();
        }
        Ok(attempts)
    }

    pub(crate) fn finish_journal_hook_deliveries(
        &self,
        results: &[crate::workspace_registry::JournalHookDeliveryResult],
    ) -> anyhow::Result<()> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .finish_journal_hook_deliveries(results)?;
        if !results.is_empty() {
            self.publish_journal_event();
        }
        Ok(())
    }

    /// Sends a diagnostic to the frontend-owned sink without writing to a
    /// frontend terminal. The first messages are retained when startup races
    /// sink installation, so a later startup message cannot replace an
    /// earlier one (the agent roster restore reports before hook retries).
    pub(crate) fn report_internal_diagnostic(&self, message: impl Into<String>) {
        let message = message.into();
        if let Some(reporter) = self.diagnostic_reporter.get().cloned() {
            reporter(&message);
            return;
        }

        // Mux construction can start hosted-surface readers before the
        // frontend has a chance to install its reporter. Recheck under the
        // pending slot lock so a concurrent setter cannot leave this message
        // stranded between the initial lookup and the store.
        let mut pending = self.pending_diagnostics.lock().unwrap();
        if let Some(reporter) = self.diagnostic_reporter.get().cloned() {
            drop(pending);
            reporter(&message);
        } else if pending.len() < MAX_PENDING_DIAGNOSTICS {
            pending.push(message);
        }
    }

    /// Logs a skipped terminal-host reconnect checkpoint at most once
    /// until a later reconnect checkpoint succeeds. A checkpoint is a
    /// journal-replay optimization: skipping one only moves the next replay
    /// boundary back, so repeated skips are daemon-log noise, not per-toast
    /// news.
    pub(crate) fn report_skipped_reconnect_checkpoint(
        &self,
        terminal_id: impl fmt::Display,
        error: &anyhow::Error,
    ) {
        let message = format!(
            "skipped terminal {terminal_id} reconnect checkpoint (replay starts from the previous boundary): {error:#}"
        );
        if self.reconnect_checkpoint_skip_reported.swap(true, Ordering::AcqRel) {
            return;
        }
        self.report_internal_diagnostic(message);
    }

    /// Installs the frontend-owned sink for diagnostics emitted by the mux.
    ///
    /// A mux has one owner for its lifetime, so accepting the first reporter
    /// avoids replacing a sink while a reconnect worker is reporting. A
    /// caller that tries to install a second sink receives `false` and must
    /// keep the original owner unchanged.
    pub fn set_diagnostic_reporter(&self, reporter: DiagnosticReporter) -> bool {
        let pending_reporter = reporter.clone();
        if self.diagnostic_reporter.set(reporter).is_err() {
            return false;
        }
        let pending = std::mem::take(&mut *self.pending_diagnostics.lock().unwrap());
        for message in pending {
            pending_reporter(&message);
        }
        true
    }

    pub(crate) fn note_reconnect_checkpoint_captured(&self) {
        self.reconnect_checkpoint_skip_reported.store(false, Ordering::Release);
    }

    pub(crate) fn create_journal_checkpoint(
        &self,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::workspace_registry::JournalCheckpointCommit> {
        let mut last_error = None;
        for attempt in 0..crate::journal_checkpoint::MAX_CHECKPOINT_CAPTURE_ATTEMPTS {
            if let Some(commit) = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .journal_checkpoint_receipt(origin, idempotency_key)?
            {
                return Ok(commit);
            }
            let captured = match crate::journal_checkpoint::capture(self) {
                Ok(captured) => captured,
                Err(error)
                    if crate::journal_checkpoint::capture_error_is_retryable(&error)
                        && attempt + 1
                            < crate::journal_checkpoint::MAX_CHECKPOINT_CAPTURE_ATTEMPTS =>
                {
                    last_error = Some(error);
                    std::thread::yield_now();
                    continue;
                }
                Err(error) => return Err(error),
            };
            match self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .create_journal_checkpoint(
                    captured.source_sequence,
                    crate::journal_checkpoint::JOURNAL_REDUCER_VERSION,
                    &captured.state,
                    &captured.blobs,
                    origin,
                    idempotency_key,
                ) {
                Ok(commit) => {
                    if !commit.journal.replayed {
                        self.publish_journal_event();
                    }
                    return Ok(commit);
                }
                Err(error)
                    if crate::journal_checkpoint::capture_error_is_retryable(&error)
                        && attempt + 1
                            < crate::journal_checkpoint::MAX_CHECKPOINT_CAPTURE_ATTEMPTS =>
                {
                    last_error = Some(error);
                    std::thread::yield_now();
                }
                Err(error) => return Err(error),
            }
        }
        Err(last_error.expect("checkpoint retry loop must retain its last error"))
    }

    pub(crate) fn journal_checkpoints(
        &self,
    ) -> anyhow::Result<Vec<crate::workspace_registry::JournalCheckpointSummary>> {
        self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner).journal_checkpoints()
    }

    pub(crate) fn journal_restore_preview(&self, selector: &str) -> anyhow::Result<Value> {
        let checkpoint = self
            .workspace_registry
            .lock()
            .unwrap()
            .journal_checkpoint(selector)?
            .with_context(|| format!("journal checkpoint {selector:?} does not exist"))?;
        let mut reducer = crate::journal_checkpoint::RestoreReducer::new(&checkpoint)?;

        let database_path = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .session_journal_database_path();
        if let Some(database_path) = database_path {
            let reader = crate::workspace_registry::SessionJournalReader::open(&database_path)?;
            let mut cursor = reader.restore_cursor(checkpoint.source_sequence)?;
            let head_sequence = loop {
                let page = cursor.next_page(1024)?;
                let head = page.head_sequence;
                let empty = page.records.is_empty();
                for record in page.records {
                    reducer.apply_read(&record)?;
                }
                if empty {
                    break head;
                }
            };
            if reducer.last_sequence() < head_sequence
                && cursor.tail_is_pruned(reducer.last_sequence())?
            {
                reducer.skip_pruned_tail(head_sequence);
            }
            cursor.finish()?;
            return reducer.finish(head_sequence);
        }

        let mut sequence = checkpoint.source_sequence;
        let mut target_head = None;
        let head_sequence = loop {
            let page = self.session_journal_after(sequence, 1024)?;
            let head = *target_head.get_or_insert(page.head_sequence);
            let empty = page.records.is_empty();
            for record in page.records {
                if record.sequence > head {
                    break;
                }
                sequence = record.sequence;
                reducer.apply_read(&record)?;
            }
            if empty || sequence >= head {
                break head;
            }
        };
        reducer.finish(head_sequence)
    }

    pub(crate) fn journal_segments(&self) -> anyhow::Result<Vec<crate::JournalSegment>> {
        self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner).journal_segments()
    }

    pub(crate) fn seal_journal_segments(
        &self,
        through_sequence: u64,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<crate::workspace_registry::JournalSegmentSealCommit> {
        let database_path = self
            .workspace_registry
            .lock()
            .unwrap()
            .session_journal_database_path()
            .context("journal segment sealing requires a persistent session")?;
        let reader = crate::workspace_registry::SessionJournalReader::open(&database_path)?;
        for _ in 0..4 {
            let start = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .begin_journal_segment_seal(through_sequence, origin, idempotency_key)?;
            let plan = match start {
                crate::workspace_registry::JournalSegmentSealStart::Replay(commit) => {
                    return Ok(commit);
                }
                crate::workspace_registry::JournalSegmentSealStart::Prepare(plan) => plan,
            };
            #[cfg(test)]
            if let Some(hook) = self.journal_segment_prepare_hook.lock().unwrap().take() {
                hook();
            }
            let prepared = plan.prepare(&reader)?;
            let commit = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .commit_journal_segment_seal(prepared, origin, idempotency_key)?;
            if let Some(commit) = commit {
                if !commit.journal.replayed {
                    self.publish_journal_event();
                }
                return Ok(commit);
            }
        }
        anyhow::bail!("journal segment boundary changed repeatedly during sealing")
    }

    #[cfg(test)]
    pub(crate) fn set_screen_created_hook_for_test(
        &self,
        hook: impl FnOnce(SurfaceId) + Send + 'static,
    ) {
        *self.screen_created_hook.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(Box::new(hook));
    }

    #[cfg(test)]
    pub(crate) fn set_journal_segment_prepare_hook_for_test(
        &self,
        hook: impl FnOnce() + Send + 'static,
    ) {
        *self.journal_segment_prepare_hook.lock().unwrap() = Some(Box::new(hook));
    }

    #[cfg(test)]
    pub(crate) fn journal_database_reader_count_for_test(&self) -> u64 {
        self.journal_kernel.database_reader_count()
    }

    #[cfg(test)]
    pub(crate) fn resource_mutation_count_for_test(&self) -> anyhow::Result<u64> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .resource_mutation_count_for_test()
    }

    #[cfg(test)]
    pub(crate) fn resource_agent_projection_count_for_test(&self) -> anyhow::Result<u64> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .resource_agent_projection_count_for_test()
    }

    #[cfg(test)]
    pub(crate) fn corrupt_agent_projection_for_test(&self, terminal_id: &TerminalPublicId) {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .corrupt_agent_projection_for_test(terminal_id);
    }
}

#[cfg(test)]
mod maintenance_steps_tests {
    use super::*;

    #[test]
    fn a_fast_tick_reports_nothing() {
        let mut steps = MaintenanceSteps::default();
        steps.record("ledgers", Duration::from_millis(3));
        steps.record("incremental_vacuum", Duration::from_millis(40));
        assert_eq!(steps.slow_report(SLOW_MAINTENANCE_TICK), None);
    }

    #[test]
    fn a_slow_tick_names_its_slowest_step() {
        let mut steps = MaintenanceSteps::default();
        steps.record("ledgers", Duration::from_millis(5));
        steps.record("checkpoint", Duration::from_millis(900));
        steps.record("seal", Duration::from_millis(11_000));
        steps.record("incremental_vacuum", Duration::from_millis(400));
        assert_eq!(
            steps.slow_report(SLOW_MAINTENANCE_TICK).as_deref(),
            Some("slow journal maintenance: 12305 ms (4 steps; slowest seal 11000 ms)")
        );
    }
}
