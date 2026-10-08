//! Journal retention after terminal-host reconnects (nx-scale step 1).
//!
//! A reconnect used to capture a full-session journal checkpoint inline:
//! every terminal's parser snapshot plus the public session snapshot, read
//! under the registry lock. A wave of N reconnects (machine resume, a daemon
//! stall that overflows host taps, teardown) therefore cost O(N^2) work under
//! one mutex and stalled the daemon near 1,024 terminals.
//!
//! Now a reconnect does O(1) work: it appends a `terminal.output.gap` record
//! (reason `host_reconnect`) to its terminal journal lane, so a restore
//! preview reports the no-tap interval instead of claiming an exact stream,
//! and it marks the terminal in [`RetentionSchedule`]. One retention worker
//! per mux coalesces the marks into one checkpoint once the wave settles (no
//! reconnect for one settle time, capped), at most one per interval. That
//! checkpoint covers every gap of the wave, also of terminals that ended
//! meanwhile. While `shutdown-daemon end_terminals` ends terminals no capture
//! starts, and a daemon that is shutting down or handing off captures
//! nothing, so ending N terminals costs no checkpoint work.
//!
//! Trade-off: a crash between a reconnect and its coalesced checkpoint
//! restores from an older checkpoint whose tail contains the gap record, so
//! the preview is honestly not fully reducible for at most one interval.

use super::*;

/// At most one coalesced reconnect checkpoint per interval.
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(30);
/// A reconnect wave settles (no new reconnect) this long before its
/// checkpoint, so the terminals of one wave share one capture.
const WAVE_SETTLE: Duration = Duration::from_secs(1);
/// A wave that keeps going is captured after at most this many settle times.
const WAVE_MAX_SETTLES: u32 = 10;
/// First retry delay after a failed capture; it doubles up to the interval.
const RETRY_INITIAL: Duration = Duration::from_millis(250);
const CHECKPOINT_ORIGIN: &str = "terminal_host_reconnect";
const SLOW_CAPTURE: Duration = Duration::from_secs(1);

/// Pure coalescing state, driven by an injected clock.
#[derive(Debug)]
pub(crate) struct RetentionSchedule {
    interval: Duration,
    settle: Duration,
    pending: BTreeSet<TerminalPublicId>,
    first_pending_at: Option<Instant>,
    last_note_at: Option<Instant>,
    last_capture_at: Option<Instant>,
    retry_at: Option<Instant>,
    failures: u32,
    teardowns: usize,
    shutdown: bool,
}

impl RetentionSchedule {
    pub(crate) fn new(interval: Duration, settle: Duration) -> Self {
        Self {
            interval,
            settle,
            pending: BTreeSet::new(),
            first_pending_at: None,
            last_note_at: None,
            last_capture_at: None,
            retry_at: None,
            failures: 0,
            teardowns: 0,
            shutdown: false,
        }
    }

    /// A terminal's replay boundary moved: a later checkpoint must cover it.
    pub(crate) fn note(&mut self, terminal: TerminalPublicId, now: Instant) {
        if self.pending.is_empty() {
            self.first_pending_at = Some(now);
        }
        self.last_note_at = Some(now);
        self.pending.insert(terminal);
    }

    /// When the next capture may run; `None` while nothing is pending, a
    /// teardown is ending terminals, or the mux is shutting down.
    pub(crate) fn due_at(&self) -> Option<Instant> {
        if self.shutdown || self.teardowns > 0 || self.pending.is_empty() {
            return None;
        }
        // Debounce on the last reconnect, capped for a wave that keeps going.
        let settled = self.last_note_at.unwrap_or(self.first_pending_at?) + self.settle;
        let capped = self.first_pending_at? + self.settle.saturating_mul(WAVE_MAX_SETTLES);
        let mut due = settled.min(capped);
        if let Some(last) = self.last_capture_at {
            due = due.max(last + self.interval);
        }
        if let Some(retry) = self.retry_at {
            due = due.max(retry);
        }
        Some(due)
    }

    /// Take the pending terminals when a capture is due at `now`.
    pub(crate) fn take_due(&mut self, now: Instant) -> Option<Vec<TerminalPublicId>> {
        if self.due_at()? > now {
            return None;
        }
        self.first_pending_at = None;
        self.last_note_at = None;
        Some(std::mem::take(&mut self.pending).into_iter().collect())
    }

    pub(crate) fn captured(&mut self, now: Instant) {
        self.last_capture_at = Some(now);
        self.retry_at = None;
        self.failures = 0;
    }

    /// The capture failed: keep the batch pending and retry after a growing
    /// delay, capped at the interval.
    pub(crate) fn failed(&mut self, batch: Vec<TerminalPublicId>, now: Instant) {
        if self.pending.is_empty() && !batch.is_empty() {
            self.first_pending_at = Some(now);
            self.last_note_at = Some(now);
        }
        self.pending.extend(batch);
        let delay = RETRY_INITIAL.saturating_mul(1_u32 << self.failures.min(10)).min(self.interval);
        self.failures = self.failures.saturating_add(1);
        self.retry_at = Some(now + delay);
    }

    /// A teardown began after this batch was taken: keep it pending without
    /// counting a failure.
    pub(crate) fn requeue(&mut self, batch: Vec<TerminalPublicId>, now: Instant) {
        for terminal in batch {
            self.note(terminal, now);
        }
    }

    pub(crate) fn begin_teardown(&mut self) {
        self.teardowns += 1;
    }

    pub(crate) fn end_teardown(&mut self) {
        self.teardowns = self.teardowns.saturating_sub(1);
    }

    #[cfg(test)]
    pub(crate) fn pending_len(&self) -> usize {
        self.pending.len()
    }
}

struct RetentionShared {
    schedule: Mutex<RetentionSchedule>,
    changed: Condvar,
}

/// Mux-owned handle: the schedule and its lazily started worker thread.
pub(crate) struct JournalRetention {
    shared: Arc<RetentionShared>,
    worker_started: AtomicBool,
    captures: AtomicU64,
}

impl Default for JournalRetention {
    fn default() -> Self {
        let (interval, settle) = configured_interval();
        Self {
            shared: Arc::new(RetentionShared {
                schedule: Mutex::new(RetentionSchedule::new(interval, settle)),
                changed: Condvar::new(),
            }),
            worker_started: AtomicBool::new(false),
            captures: AtomicU64::new(0),
        }
    }
}

impl JournalRetention {
    fn teardown_active(&self) -> bool {
        self.shared.schedule.lock().unwrap_or_else(PoisonError::into_inner).teardowns > 0
    }
}

impl Drop for JournalRetention {
    fn drop(&mut self) {
        self.shared.schedule.lock().unwrap_or_else(PoisonError::into_inner).shutdown = true;
        self.shared.changed.notify_all();
    }
}

/// Debug builds accept `CMUX_TUI_TEST_JOURNAL_CHECKPOINT_INTERVAL_MS` so
/// tests observe coalescing without waiting 30 s; the wave settle time is
/// then a quarter of that interval, at most one second.
fn configured_interval() -> (Duration, Duration) {
    #[cfg(debug_assertions)]
    if let Some(interval) = std::env::var("CMUX_TUI_TEST_JOURNAL_CHECKPOINT_INTERVAL_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .map(Duration::from_millis)
    {
        return (interval, (interval / 4).min(WAVE_SETTLE));
    }
    (CHECKPOINT_INTERVAL, WAVE_SETTLE)
}

enum CaptureOutcome {
    Captured,
    /// The daemon is shutting down or handing off: no capture.
    Skipped,
    /// A teardown started after the batch was taken: capture later.
    Deferred,
    Failed,
}

/// Ends a teardown window when dropped; see [`Mux::begin_terminal_teardown`].
pub(crate) struct TerminalTeardown<'a> {
    retention: &'a JournalRetention,
}

impl Drop for TerminalTeardown<'_> {
    fn drop(&mut self) {
        self.retention
            .shared
            .schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .end_teardown();
        self.retention.shared.changed.notify_all();
    }
}

impl Mux {
    /// O(1) reconnect bookkeeping, called by the hosted reader after it
    /// installed the host's replacement snapshot and before it reads new
    /// output. The gap record precedes that output in the terminal lane.
    pub(crate) fn journal_terminal_host_reconnect(
        self: &Arc<Self>,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
    ) {
        self.journal_ingress.send(crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
            terminal_id: terminal_id.clone(),
            generation,
            occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
            reason: "host_reconnect",
        });
        let retention = &self.journal_retention;
        retention
            .shared
            .schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .note(TerminalPublicId::clone(&terminal_id), Instant::now());
        retention.shared.changed.notify_all();
        if !retention.worker_started.swap(true, Ordering::AcqRel) {
            let shared = retention.shared.clone();
            let mux = Arc::downgrade(self);
            let spawned = std::thread::Builder::new()
                .name("journal-retention".into())
                .spawn(move || run_retention_worker(&shared, &mux));
            if let Err(error) = spawned {
                retention.worker_started.store(false, Ordering::Release);
                eprintln!("cmux-tui: could not start the journal retention worker: {error}");
            }
        }
    }

    /// Postpone coalesced checkpoints while terminals are being ended; the
    /// returned guard ends the window.
    pub(crate) fn begin_terminal_teardown(&self) -> TerminalTeardown<'_> {
        self.journal_retention
            .shared
            .schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .begin_teardown();
        TerminalTeardown { retention: &self.journal_retention }
    }

    /// Coalesced checkpoints committed by the retention worker.
    #[cfg(test)]
    pub(crate) fn coalesced_reconnect_checkpoints(&self) -> u64 {
        self.journal_retention.captures.load(Ordering::Acquire)
    }

    fn capture_coalesced_checkpoint(&self, batch: &[TerminalPublicId]) -> CaptureOutcome {
        // A daemon that is shutting down or handing off its hosts (also right
        // after shutdown-daemon end_terminals) captures nothing more.
        if self.shutting_down.load(Ordering::Acquire)
            || self.control_clients.daemon_handoff_in_progress()
        {
            return CaptureOutcome::Skipped;
        }
        if self.journal_retention.teardown_active() {
            return CaptureOutcome::Deferred;
        }
        let Some(first) = batch.first() else { return CaptureOutcome::Skipped };
        // Terminals of the batch that ended still left gap records in the
        // journal tail, so the checkpoint is taken for them too.
        let sequence = self.journal_retention.captures.load(Ordering::Acquire);
        let key = format!(
            "host-reconnects:{}:{}:{sequence}:{}",
            std::process::id(),
            crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
            first.as_str()
        );
        let started = Instant::now();
        let captured = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.create_journal_checkpoint(CHECKPOINT_ORIGIN, &key)
        }))
        .unwrap_or_else(|_| Err(anyhow::anyhow!("checkpoint capture panicked")));
        match captured {
            Ok(_) => {
                self.journal_retention.captures.fetch_add(1, Ordering::AcqRel);
                self.note_reconnect_checkpoint_captured();
                let elapsed = started.elapsed();
                if elapsed >= SLOW_CAPTURE {
                    eprintln!(
                        "cmux-tui: coalesced reconnect checkpoint for {} terminal(s) took {} ms",
                        batch.len(),
                        elapsed.as_millis()
                    );
                }
                CaptureOutcome::Captured
            }
            Err(error) => {
                let subject = format!("{} (and {} more)", first.as_str(), batch.len() - 1);
                self.report_skipped_reconnect_checkpoint(subject, &error);
                CaptureOutcome::Failed
            }
        }
    }
}

fn run_retention_worker(shared: &RetentionShared, mux: &Weak<Mux>) {
    let mut schedule = shared.schedule.lock().unwrap_or_else(PoisonError::into_inner);
    loop {
        if schedule.shutdown {
            return;
        }
        let now = Instant::now();
        let Some(due) = schedule.due_at() else {
            schedule = shared.changed.wait(schedule).unwrap_or_else(PoisonError::into_inner);
            continue;
        };
        if due > now {
            schedule = shared
                .changed
                .wait_timeout(schedule, due - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
            continue;
        }
        let Some(batch) = schedule.take_due(now) else { continue };
        drop(schedule);
        // Hold the mux only for the capture: the last owner may drop it here,
        // and its drop must not find this worker holding the schedule.
        let outcome = match mux.upgrade() {
            Some(mux) => mux.capture_coalesced_checkpoint(&batch),
            None => return,
        };
        schedule = shared.schedule.lock().unwrap_or_else(PoisonError::into_inner);
        match outcome {
            CaptureOutcome::Captured => schedule.captured(Instant::now()),
            CaptureOutcome::Skipped => {}
            CaptureOutcome::Deferred => schedule.requeue(batch, Instant::now()),
            CaptureOutcome::Failed => schedule.failed(batch, Instant::now()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(index: u8) -> TerminalPublicId {
        TerminalPublicId::parse(format!("term_{index:032x}")).unwrap()
    }

    fn schedule() -> RetentionSchedule {
        RetentionSchedule::new(Duration::from_secs(30), Duration::from_secs(1))
    }

    #[test]
    fn a_reconnect_wave_coalesces_into_one_capture_after_it_settles() {
        let start = Instant::now();
        let mut schedule = schedule();
        for index in 0..100 {
            schedule.note(terminal(index), start + Duration::from_millis(u64::from(index)));
        }
        // One second after the last reconnect of the wave.
        assert_eq!(schedule.due_at(), Some(start + Duration::from_millis(1_099)));
        assert!(schedule.take_due(start + Duration::from_millis(1_098)).is_none());
        let batch = schedule.take_due(start + Duration::from_millis(1_099)).unwrap();
        assert_eq!(batch.len(), 100);
        assert_eq!(schedule.due_at(), None);
    }

    #[test]
    fn captures_are_at_most_one_per_interval() {
        let start = Instant::now();
        let mut schedule = schedule();
        schedule.note(terminal(1), start);
        schedule.take_due(start + Duration::from_secs(1)).unwrap();
        schedule.captured(start + Duration::from_secs(2));
        schedule.note(terminal(2), start + Duration::from_secs(3));
        assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(32)));
        schedule.note(terminal(2), start + Duration::from_secs(4));
        assert_eq!(schedule.pending_len(), 1, "a terminal is pending once");
    }

    #[test]
    fn a_failed_capture_keeps_its_batch_and_backs_off_up_to_the_interval() {
        let start = Instant::now();
        let mut schedule = schedule();
        schedule.note(terminal(1), start);
        let batch = schedule.take_due(start + Duration::from_secs(1)).unwrap();
        schedule.failed(batch, start + Duration::from_secs(1));
        assert_eq!(schedule.pending_len(), 1);
        // The retry is spaced, and a re-queued batch settles again.
        assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(2)));
        let mut now = start;
        for _ in 0..20 {
            now = schedule.due_at().unwrap();
            let batch = schedule.take_due(now).unwrap();
            schedule.failed(batch, now);
        }
        assert_eq!(
            schedule.due_at(),
            Some(now + Duration::from_secs(30)),
            "retry spacing is capped at the interval"
        );
    }

    #[test]
    fn a_teardown_postpones_capture_until_it_ends() {
        let start = Instant::now();
        let mut schedule = schedule();
        schedule.note(terminal(1), start);
        schedule.begin_teardown();
        assert_eq!(schedule.due_at(), None);
        assert!(schedule.take_due(start + Duration::from_secs(60)).is_none());
        schedule.end_teardown();
        assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(1)));
    }

    #[test]
    fn a_wave_that_keeps_reconnecting_is_debounced_then_capped() {
        let start = Instant::now();
        let mut schedule = schedule();
        schedule.note(terminal(1), start);
        schedule.note(terminal(2), start + Duration::from_millis(900));
        assert_eq!(schedule.due_at(), Some(start + Duration::from_millis(1_900)));
        for step in 1..30_u64 {
            schedule.note(terminal(3), start + Duration::from_millis(900 * step));
        }
        assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(10)));
    }

    #[test]
    fn a_capture_during_teardown_or_handoff_does_not_run() {
        let mux = Mux::new_for_test("retention", SurfaceOptions::default());
        let teardown = mux.begin_terminal_teardown();
        assert!(matches!(
            mux.capture_coalesced_checkpoint(&[terminal(7)]),
            CaptureOutcome::Deferred
        ));
        drop(teardown);
        mux.shutting_down.store(true, Ordering::Release);
        assert!(matches!(
            mux.capture_coalesced_checkpoint(&[terminal(7)]),
            CaptureOutcome::Skipped
        ));
        assert_eq!(mux.coalesced_reconnect_checkpoints(), 0);
    }
}
