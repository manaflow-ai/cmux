//! Journal retention after terminal-host reconnects (port of feat's nx-scale
//! step 1).
//!
//! A reconnect used to capture a full-session journal checkpoint inline, on
//! the terminal's host reader thread: every terminal's parser snapshot plus
//! the public session snapshot. The reader read nothing from the replacement
//! host stream until that capture ended, so under continuous output the host
//! dropped the replacement tap too (its 8 MiB viewer budget filled), and the
//! terminal never got back to `running`. A wave of N reconnects also cost
//! O(N^2) work under one mutex.
//!
//! Now a reconnect does O(1) work on the reader: it appends a
//! `terminal.output.gap` record (reason `host_reconnect`) to its terminal
//! journal lane, so a restore preview reports the no-tap interval instead of
//! claiming an exact stream, and it marks the terminal in
//! [`RetentionSchedule`]. One retention worker per mux coalesces the marks
//! into at most one checkpoint per interval. The checkpoint after a wave
//! covers every gap of that wave; terminals that ended meanwhile are skipped.
//! A hosted reader whose terminal lane is full records the same kind of gap
//! (reason `journal_queue_full`) for the output it could not journal, and the
//! same checkpoint covers it. Such a gap marks its terminal when it becomes
//! pending, before its record can enter the lane, and the worker records a
//! gap that is still pending ahead of its checkpoint: a terminal that prints
//! nothing after the drop still gets its gap record and its checkpoint.
//!
//! Unlike feat, whose checkpoints hold no terminal screens, a checkpoint here
//! replays every terminal under its parser lock, and it fails ("session
//! changed during checkpoint capture") while output continues. A failed
//! capture is therefore retried only after the full interval: a sooner retry
//! would stall the hosted readers again and make their hosts drop them.
//!
//! Trade-off: a crash between a reconnect and its coalesced checkpoint
//! restores from an older checkpoint whose tail contains the gap record, so
//! the preview is honestly not fully reducible for at most one interval.

use super::*;

/// At most one coalesced reconnect checkpoint per interval.
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(30);
/// A reconnect wave settles this long before its checkpoint, so the
/// terminals of one wave share one capture.
const WAVE_SETTLE: Duration = Duration::from_secs(1);
const CHECKPOINT_ORIGIN: &str = "terminal_host_reconnect";
const SLOW_CAPTURE: Duration = Duration::from_secs(1);

/// Pure coalescing state, driven by an injected clock.
#[derive(Debug)]
pub(crate) struct RetentionSchedule {
    interval: Duration,
    settle: Duration,
    pending: BTreeSet<TerminalPublicId>,
    first_pending_at: Option<Instant>,
    last_capture_at: Option<Instant>,
    retry_at: Option<Instant>,
    shutdown: bool,
}

impl RetentionSchedule {
    pub(crate) fn new(interval: Duration, settle: Duration) -> Self {
        Self {
            interval,
            settle,
            pending: BTreeSet::new(),
            first_pending_at: None,
            last_capture_at: None,
            retry_at: None,
            shutdown: false,
        }
    }

    /// A terminal's replay boundary moved: a later checkpoint must cover it.
    pub(crate) fn note(&mut self, terminal: TerminalPublicId, now: Instant) {
        if self.pending.is_empty() {
            self.first_pending_at = Some(now);
        }
        self.pending.insert(terminal);
    }

    /// When the next capture may run; `None` while nothing is pending or the
    /// mux is shutting down.
    pub(crate) fn due_at(&self) -> Option<Instant> {
        if self.shutdown || self.pending.is_empty() {
            return None;
        }
        let mut due = self.first_pending_at? + self.settle;
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
        Some(std::mem::take(&mut self.pending).into_iter().collect())
    }

    pub(crate) fn captured(&mut self, now: Instant) {
        self.last_capture_at = Some(now);
        self.retry_at = None;
    }

    /// The capture failed: keep the batch pending and retry after the
    /// interval (see the module documentation).
    pub(crate) fn failed(&mut self, batch: Vec<TerminalPublicId>, now: Instant) {
        if self.pending.is_empty() && !batch.is_empty() {
            self.first_pending_at = Some(now);
        }
        self.pending.extend(batch);
        self.retry_at = Some(now + self.interval);
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
    NothingLive,
    Failed,
}

impl Mux {
    /// O(1) gap bookkeeping for a terminal whose journal lost output: the
    /// host dropped the daemon's tap (`host_reconnect`), or the terminal lane
    /// was full (`journal_queue_full`). Records the gap without waiting and,
    /// with `note_retention`, notes the terminal for the next coalesced
    /// checkpoint. `false` when the terminal lane has no room: nothing was
    /// recorded, and the caller keeps the gap pending ahead of its next
    /// output.
    pub(crate) fn journal_terminal_output_gap(
        self: &Arc<Self>,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        reason: &'static str,
        note_retention: bool,
    ) -> bool {
        let recorded = self.journal_ingress.try_send_terminal_gap(
            crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
                terminal_id: terminal_id.clone(),
                generation,
                occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
                reason,
            },
        );
        if recorded.is_err() {
            return false;
        }
        if note_retention {
            self.note_journal_gap_for_retention(&terminal_id);
        }
        true
    }

    /// Notes a terminal whose journal lost output for the next coalesced
    /// checkpoint, and starts the retention worker on first use.
    pub(crate) fn note_journal_gap_for_retention(self: &Arc<Self>, terminal_id: &TerminalPublicId) {
        let retention = &self.journal_retention;
        retention
            .shared
            .schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .note(terminal_id.clone(), Instant::now());
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

    /// Coalesced checkpoints committed by the retention worker.
    #[cfg(test)]
    pub(crate) fn coalesced_reconnect_checkpoints(&self) -> u64 {
        self.journal_retention.captures.load(Ordering::Acquire)
    }

    /// Waits until the retention worker has committed `count` coalesced
    /// checkpoints; `false` when `timeout` ends first.
    #[cfg(test)]
    pub(crate) fn wait_for_coalesced_checkpoints_for_test(
        &self,
        count: u64,
        timeout: Duration,
    ) -> bool {
        let retention = &self.journal_retention;
        let deadline = Instant::now() + timeout;
        let mut schedule = retention.shared.schedule.lock().unwrap_or_else(PoisonError::into_inner);
        while retention.captures.load(Ordering::Acquire) < count {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            schedule = retention
                .shared
                .changed
                .wait_timeout(schedule, remaining)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        true
    }

    fn capture_coalesced_checkpoint(&self, batch: &[TerminalPublicId]) -> CaptureOutcome {
        if self.shutting_down.load(Ordering::Acquire) {
            return CaptureOutcome::NothingLive;
        }
        let live = batch.iter().filter(|id| self.terminal_resource_surface(id).is_some()).count();
        let Some(first) = batch.first().filter(|_| live > 0) else {
            return CaptureOutcome::NothingLive;
        };
        // A gap still pending (its terminal printed nothing since the drop)
        // goes into the journal ahead of the checkpoint that covers it.
        for terminal in batch {
            if let Some(surface) = self.terminal_resource_surface(terminal) {
                surface.record_pending_journal_gap();
            }
        }
        let sequence = self.journal_retention.captures.load(Ordering::Acquire);
        let key = format!(
            "host-reconnects:{}:{}:{sequence}:{}",
            std::process::id(),
            crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
            first.as_str()
        );
        let started = Instant::now();
        match self.create_journal_checkpoint(CHECKPOINT_ORIGIN, &key) {
            Ok(_) => {
                self.journal_retention.captures.fetch_add(1, Ordering::AcqRel);
                self.note_reconnect_checkpoint_captured();
                let elapsed = started.elapsed();
                if elapsed >= SLOW_CAPTURE {
                    eprintln!(
                        "cmux-tui: coalesced reconnect checkpoint for {live} terminal(s) took {} ms",
                        elapsed.as_millis()
                    );
                }
                CaptureOutcome::Captured
            }
            Err(error) => {
                self.report_skipped_reconnect_checkpoint(first.as_str(), &error);
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
            CaptureOutcome::NothingLive => {}
            CaptureOutcome::Failed => schedule.failed(batch, Instant::now()),
        }
        // Wakes test waiters for a capture; the worker itself is not waiting.
        shared.changed.notify_all();
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
        assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(1)));
        assert!(schedule.take_due(start + Duration::from_millis(999)).is_none());
        let batch = schedule.take_due(start + Duration::from_secs(1)).unwrap();
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
    fn a_failed_capture_keeps_its_batch_and_retries_after_the_interval() {
        let start = Instant::now();
        let mut schedule = schedule();
        schedule.note(terminal(1), start);
        let batch = schedule.take_due(start + Duration::from_secs(1)).unwrap();
        schedule.failed(batch, start + Duration::from_secs(1));
        assert_eq!(schedule.pending_len(), 1);
        // A reconnect during the wait neither brings the retry forward nor
        // adds a second entry.
        schedule.note(terminal(1), start + Duration::from_secs(2));
        assert_eq!(schedule.pending_len(), 1);
        assert_eq!(schedule.due_at(), Some(start + Duration::from_secs(31)));
        assert!(schedule.take_due(start + Duration::from_secs(30)).is_none());
        let batch = schedule.take_due(start + Duration::from_secs(31)).unwrap();
        schedule.captured(start + Duration::from_secs(32));
        assert_eq!(batch.len(), 1);
        assert_eq!(schedule.due_at(), None);
    }

    #[test]
    fn ending_every_reconnected_terminal_commits_no_checkpoint() {
        let mux = Mux::new_for_test("retention", SurfaceOptions::default());
        mux.journal_retention.shared.schedule.lock().unwrap().note(terminal(7), Instant::now());
        // The terminal does not exist (it ended): nothing to capture.
        assert!(matches!(
            mux.capture_coalesced_checkpoint(&[terminal(7)]),
            CaptureOutcome::NothingLive
        ));
        assert_eq!(mux.coalesced_reconnect_checkpoints(), 0);
    }
}
