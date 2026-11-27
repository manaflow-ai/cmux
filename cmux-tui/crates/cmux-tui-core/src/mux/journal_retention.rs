<<<<<<< ours
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
//! A daemon that stops on `SIGTERM` (logout, reboot) while its hosts keep
//! running takes one more checkpoint at shutdown, see
//! [`Mux::capture_shutdown_checkpoint`].
=======
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
//! Terminal output itself is not in the journal (output_store.rs), so a
//! checkpoint holds no terminal screens and output no longer fails its cut.
//! A gap or resize record that finds the terminal lane full (a stalled
//! writer) is not recorded; its terminal is still marked, so the checkpoint
//! covers it.
//!
//! A failed capture is retried only after the full interval.
>>>>>>> theirs
//!
//! Trade-off: a crash between a reconnect and its coalesced checkpoint
//! restores from an older checkpoint whose tail contains the gap record, so
//! the preview is honestly not fully reducible for at most one interval.

use super::*;

/// At most one coalesced reconnect checkpoint per interval.
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(30);
<<<<<<< ours
/// A reconnect wave settles (no new reconnect) this long before its
/// checkpoint, so the terminals of one wave share one capture.
const WAVE_SETTLE: Duration = Duration::from_secs(1);
/// A wave that keeps going is captured after at most this many settle times.
const WAVE_MAX_SETTLES: u32 = 10;
/// First retry delay after a failed capture; it doubles up to the interval.
const RETRY_INITIAL: Duration = Duration::from_millis(250);
const CHECKPOINT_ORIGIN: &str = "terminal_host_reconnect";
const SLOW_CAPTURE: Duration = Duration::from_secs(1);
const SHUTDOWN_CHECKPOINT_ORIGIN: &str = "daemon_shutdown";
/// How long a shutdown retries a failed screen checkpoint.
const SHUTDOWN_CAPTURE_BUDGET: Duration = Duration::from_secs(2);
const SHUTDOWN_CAPTURE_RETRY: Duration = Duration::from_millis(50);
=======
/// A reconnect wave settles this long before its checkpoint, so the
/// terminals of one wave share one capture.
const WAVE_SETTLE: Duration = Duration::from_secs(1);
const CHECKPOINT_ORIGIN: &str = "terminal_host_reconnect";
const SLOW_CAPTURE: Duration = Duration::from_secs(1);
>>>>>>> theirs

/// Pure coalescing state, driven by an injected clock.
#[derive(Debug)]
pub(crate) struct RetentionSchedule {
    interval: Duration,
    settle: Duration,
    pending: BTreeSet<TerminalPublicId>,
    first_pending_at: Option<Instant>,
<<<<<<< ours
    last_note_at: Option<Instant>,
    last_capture_at: Option<Instant>,
    retry_at: Option<Instant>,
    failures: u32,
    teardowns: usize,
=======
    last_capture_at: Option<Instant>,
    retry_at: Option<Instant>,
>>>>>>> theirs
    shutdown: bool,
}

impl RetentionSchedule {
    pub(crate) fn new(interval: Duration, settle: Duration) -> Self {
        Self {
            interval,
            settle,
            pending: BTreeSet::new(),
            first_pending_at: None,
<<<<<<< ours
            last_note_at: None,
            last_capture_at: None,
            retry_at: None,
            failures: 0,
            teardowns: 0,
=======
            last_capture_at: None,
            retry_at: None,
>>>>>>> theirs
            shutdown: false,
        }
    }

    /// A terminal's replay boundary moved: a later checkpoint must cover it.
    pub(crate) fn note(&mut self, terminal: TerminalPublicId, now: Instant) {
        if self.pending.is_empty() {
            self.first_pending_at = Some(now);
        }
<<<<<<< ours
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
=======
        self.pending.insert(terminal);
    }

    /// When the next capture may run; `None` while nothing is pending or the
    /// mux is shutting down.
    pub(crate) fn due_at(&self) -> Option<Instant> {
        if self.shutdown || self.pending.is_empty() {
            return None;
        }
        let mut due = self.first_pending_at? + self.settle;
>>>>>>> theirs
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
<<<<<<< ours
        self.last_note_at = None;
=======
>>>>>>> theirs
        Some(std::mem::take(&mut self.pending).into_iter().collect())
    }

    pub(crate) fn captured(&mut self, now: Instant) {
        self.last_capture_at = Some(now);
        self.retry_at = None;
<<<<<<< ours
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
=======
    }

    /// The capture failed: keep the batch pending and retry after the
    /// interval (see the module documentation).
    pub(crate) fn failed(&mut self, batch: Vec<TerminalPublicId>, now: Instant) {
        if self.pending.is_empty() && !batch.is_empty() {
            self.first_pending_at = Some(now);
        }
        self.pending.extend(batch);
        self.retry_at = Some(now + self.interval);
>>>>>>> theirs
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

<<<<<<< ours
impl JournalRetention {
    pub(super) fn teardown_active(&self) -> bool {
        self.shared.schedule.lock().unwrap_or_else(PoisonError::into_inner).teardowns > 0
    }
}

=======
>>>>>>> theirs
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
<<<<<<< ours
    /// The daemon is shutting down: no capture.
    Skipped,
    /// A teardown or handoff is in progress: capture later.
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
    /// O(1) bookkeeping for a terminal whose replay boundary moved: a host
    /// reconnect (called by the hosted reader after its gap record,
    /// surface/journal_reconnect.rs) or a record the full terminal lane
    /// refused (`Mux::journal_terminal_resize`). Marks the terminal for the
    /// next coalesced checkpoint.
    pub(crate) fn note_terminal_host_reconnect(self: &Arc<Self>, terminal_id: TerminalPublicId) {
=======
    NothingLive,
    Failed,
}

impl Mux {
    /// O(1) gap bookkeeping when the host dropped the daemon's tap
    /// (`host_reconnect`): records the `terminal.output.gap` marker without
    /// waiting (the hosted reader must never wait for a stalled writer) and
    /// notes the terminal for the next coalesced checkpoint, which also
    /// covers a marker the full terminal lane did not take.
    pub(crate) fn journal_terminal_output_gap(
        self: &Arc<Self>,
        terminal_id: Arc<TerminalPublicId>,
        generation: Arc<str>,
        reason: &'static str,
    ) {
        if let Err(error) = self.journal_ingress.try_send_terminal_gap(
            crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
                terminal_id: terminal_id.clone(),
                generation,
                occurred_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
                reason,
            },
        ) {
            eprintln!(
                "cmux-tui: terminal {terminal_id} {reason} gap marker was not journaled: {error:#}"
            );
        }
        self.note_journal_gap_for_retention(&terminal_id);
    }

    /// Notes a terminal whose replay boundary moved (a host reconnect, a
    /// record the full terminal lane did not take) for the next coalesced
    /// checkpoint, and starts the retention worker on first use.
    pub(crate) fn note_journal_gap_for_retention(self: &Arc<Self>, terminal_id: &TerminalPublicId) {
>>>>>>> theirs
        let retention = &self.journal_retention;
        retention
            .shared
            .schedule
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
<<<<<<< ours
            .note(terminal_id, Instant::now());
=======
            .note(terminal_id.clone(), Instant::now());
>>>>>>> theirs
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

<<<<<<< ours
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

=======
>>>>>>> theirs
    /// Coalesced checkpoints committed by the retention worker.
    #[cfg(test)]
    pub(crate) fn coalesced_reconnect_checkpoints(&self) -> u64 {
        self.journal_retention.captures.load(Ordering::Acquire)
    }

    fn capture_coalesced_checkpoint(&self, batch: &[TerminalPublicId]) -> CaptureOutcome {
<<<<<<< ours
        // A daemon that is shutting down or handing off its hosts (also right
        // after shutdown-daemon end_terminals) captures nothing more.
        if self.shutting_down.load(Ordering::Acquire) {
            return CaptureOutcome::Skipped;
        }
        // A handoff can still be cancelled: keep the batch pending.
        if self.journal_retention.teardown_active()
            || self.control_clients.daemon_handoff_in_progress()
        {
            return CaptureOutcome::Deferred;
        }
        let Some(first) = batch.first() else { return CaptureOutcome::Skipped };
        // A marker the full terminal lane still owes goes into the journal
        // ahead of the checkpoint that covers it; one that finds no room
        // stays owed for its terminal's next record or the next checkpoint.
        self.journal_ingress.offer_owed_terminal_gaps();
        // Terminals of the batch that ended still left gap records in the
        // journal tail, so the checkpoint is taken for them too.
=======
        if self.shutting_down.load(Ordering::Acquire) {
            return CaptureOutcome::NothingLive;
        }
        let live = batch.iter().filter(|id| self.terminal_resource_surface(id).is_some()).count();
        let Some(first) = batch.first().filter(|_| live > 0) else {
            return CaptureOutcome::NothingLive;
        };
>>>>>>> theirs
        let sequence = self.journal_retention.captures.load(Ordering::Acquire);
        let key = format!(
            "host-reconnects:{}:{}:{sequence}:{}",
            std::process::id(),
            crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
            first.as_str()
        );
        let started = Instant::now();
<<<<<<< ours
        let captured = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.create_journal_checkpoint(CHECKPOINT_ORIGIN, &key)
        }))
        .unwrap_or_else(|_| Err(anyhow::anyhow!("checkpoint capture panicked")));
        match captured {
=======
        match self.create_journal_checkpoint(CHECKPOINT_ORIGIN, &key) {
>>>>>>> theirs
            Ok(_) => {
                self.journal_retention.captures.fetch_add(1, Ordering::AcqRel);
                self.note_reconnect_checkpoint_captured();
                let elapsed = started.elapsed();
                if elapsed >= SLOW_CAPTURE {
                    eprintln!(
<<<<<<< ours
                        "cmux-tui: coalesced reconnect checkpoint for {} terminal(s) took {} ms",
                        batch.len(),
=======
                        "cmux-tui: coalesced reconnect checkpoint for {live} terminal(s) took {} ms",
>>>>>>> theirs
                        elapsed.as_millis()
                    );
                }
                CaptureOutcome::Captured
            }
            Err(error) => {
<<<<<<< ours
                let subject = format!("{} (and {} more)", first.as_str(), batch.len() - 1);
                self.report_skipped_reconnect_checkpoint(subject, &error);
=======
                self.report_skipped_reconnect_checkpoint(first.as_str(), &error);
>>>>>>> theirs
                CaptureOutcome::Failed
            }
        }
    }
}

<<<<<<< ours
impl Mux {
    /// Whether this shutdown checkpoints the terminal screens, decided when
    /// it starts. A reboot ends the hosts after the daemon, so no exit replay
    /// is recorded, and the respawn at the next start shows the latest
    /// checkpoint (cx-6so.49 L2): without this one, an older or no screen. A
    /// handoff skips it (an app update's next daemon adopts the live hosts;
    /// `server stop` takes the same path), as do a teardown that ends
    /// terminals and a daemon without terminals. Respawn is unix only.
    pub(super) fn wants_shutdown_checkpoint(&self) -> bool {
        if cfg!(not(unix))
            || self.control_clients.daemon_handoff_in_progress()
            || self.journal_retention.teardown_active()
        {
            return false;
        }
        let terminals =
            unique_surface_runtimes(&self.state.lock().unwrap_or_else(PoisonError::into_inner));
        terminals.iter().any(|surface| surface.kind() == SurfaceKind::Pty)
    }

    /// Checkpoint every terminal's screen at shutdown. Runs once the terminal
    /// readers drained and the journal is fenced: while a terminal still
    /// writes, every capture is rejected as racing the journal. A failure
    /// only costs the screen.
    pub(super) fn capture_shutdown_checkpoint(&self) {
        let key = format!(
            "shutdown:{}:{}",
            std::process::id(),
            crate::workspace_registry::unix_epoch_ms().unwrap_or(0)
        );
        let deadline = Instant::now() + SHUTDOWN_CAPTURE_BUDGET;
        loop {
            let captured = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                self.create_journal_checkpoint(SHUTDOWN_CHECKPOINT_ORIGIN, &key)
            }))
            .unwrap_or_else(|_| Err(anyhow::anyhow!("checkpoint capture panicked")));
            let error = match captured {
                Ok(_) => return,
                Err(error) => error,
            };
            if Instant::now() + SHUTDOWN_CAPTURE_RETRY >= deadline {
                eprintln!("cmux-tui: no terminal screen checkpoint at shutdown: {error:#}");
                return;
            }
            std::thread::sleep(SHUTDOWN_CAPTURE_RETRY);
        }
    }
}

=======
>>>>>>> theirs
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
<<<<<<< ours
            CaptureOutcome::Skipped => {}
            CaptureOutcome::Deferred => schedule.requeue(batch, Instant::now()),
=======
            CaptureOutcome::NothingLive => {}
>>>>>>> theirs
            CaptureOutcome::Failed => schedule.failed(batch, Instant::now()),
        }
    }
}

#[cfg(test)]
<<<<<<< ours
#[path = "journal_retention_tests.rs"]
mod tests;
=======
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
>>>>>>> theirs
