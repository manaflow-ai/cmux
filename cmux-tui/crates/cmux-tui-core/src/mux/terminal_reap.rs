//! Reaping of unplaced terminals (`terminal-reap-v1`).
//!
//! Closing a tab, pane, screen, or workspace detaches a PTY terminal without
//! ending it, because terminals are session-owned. The owner therefore ends
//! a terminal once it has had zero tab placements for the reap grace period,
//! unless the terminal is marked `keep` (`set-terminal-keep`, or `keep` on
//! the creating command). The grace period keeps a daemon restart, a
//! frontend quit and relaunch, and layout undo safe: a placement restored
//! within the period cancels the reap.
//!
//! The reaper is event-driven. It sleeps until the next deadline or until a
//! topology, terminal-registry, or keep change wakes it; it never polls.
//! Deadlines are measured by this owner process only, so an owner restart
//! starts every pending grace period again: a restart can delay a reap but
//! never make it early.

use std::sync::mpsc::RecvTimeoutError;
use std::thread::JoinHandle;

use super::*;

/// Default reap grace period for a terminal with no placement.
pub const DEFAULT_TERMINAL_REAP_GRACE: Duration = Duration::from_secs(30);

/// Largest accepted reap grace period: one week.
pub const MAX_TERMINAL_REAP_GRACE: Duration = Duration::from_secs(7 * 24 * 60 * 60);

const TERMINAL_REAP_MUTATION_ORIGIN: &str = "cmux-tui-terminal-reap";
const END_TERMINALS_MUTATION_ORIGIN: &str = "cmux-tui-end-terminals";

/// Result of one reap attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ReapOutcome {
    /// The terminal was ended.
    Reaped,
    /// A client holds an attach stream on the unplaced terminal.
    Attached,
    /// The terminal gained a placement, was marked `keep`, or is gone.
    Retained,
}

/// Per-terminal reap deadlines, driven by an injected clock.
#[derive(Debug, Default)]
pub(crate) struct ReapSchedule {
    deadlines: HashMap<String, Instant>,
}

impl ReapSchedule {
    /// Reconcile with the current set of reapable terminals. A terminal that
    /// becomes reapable gets `now + grace`; a terminal that is no longer
    /// reapable (placed again, kept, or closed) loses its deadline.
    pub(crate) fn observe(&mut self, now: Instant, grace: Duration, reapable: &HashSet<String>) {
        self.deadlines.retain(|terminal_id, _| reapable.contains(terminal_id));
        let deadline = deadline_after(now, grace);
        for terminal_id in reapable {
            self.deadlines.entry(terminal_id.clone()).or_insert(deadline);
        }
    }

    /// Terminals whose deadline is at or before `now`, in a stable order.
    pub(crate) fn due(&self, now: Instant) -> Vec<String> {
        let mut due: Vec<String> = self
            .deadlines
            .iter()
            .filter(|(_, deadline)| **deadline <= now)
            .map(|(terminal_id, _)| terminal_id.clone())
            .collect();
        due.sort_unstable();
        due
    }

    pub(crate) fn postpone(&mut self, terminal_id: &str, until: Instant) {
        if let Some(deadline) = self.deadlines.get_mut(terminal_id) {
            *deadline = until;
        }
    }

    pub(crate) fn forget(&mut self, terminal_id: &str) {
        self.deadlines.remove(terminal_id);
    }

    pub(crate) fn next_deadline(&self) -> Option<Instant> {
        self.deadlines.values().min().copied()
    }

    #[cfg(test)]
    pub(crate) fn deadline(&self, terminal_id: &str) -> Option<Instant> {
        self.deadlines.get(terminal_id).copied()
    }
}

fn deadline_after(now: Instant, grace: Duration) -> Instant {
    now.checked_add(grace).unwrap_or_else(|| now + MAX_TERMINAL_REAP_GRACE)
}

/// Validate a reap grace period supplied by a command line or a caller.
pub fn validate_terminal_reap_grace(grace: Duration) -> anyhow::Result<Duration> {
    anyhow::ensure!(
        grace <= MAX_TERMINAL_REAP_GRACE,
        "terminal reap grace must be at most {} seconds",
        MAX_TERMINAL_REAP_GRACE.as_secs()
    );
    Ok(grace)
}

impl Mux {
    /// The grace period an unplaced terminal survives before it is reaped.
    pub fn terminal_reap_grace(&self) -> Duration {
        Duration::from_millis(self.terminal_reap_grace_ms.load(Ordering::Acquire))
    }

    /// Change the reap grace period. Zero reaps an unplaced terminal at once.
    /// Pending deadlines keep their original grace period.
    pub fn set_terminal_reap_grace(&self, grace: Duration) -> anyhow::Result<()> {
        let grace = validate_terminal_reap_grace(grace)?;
        let millis = u64::try_from(grace.as_millis()).unwrap_or(u64::MAX);
        self.terminal_reap_grace_ms.store(millis, Ordering::Release);
        self.wake_terminal_reaper();
        Ok(())
    }

    /// Mark (`true`) or unmark (`false`) one hosted terminal as `keep`.
    /// `terminal_id` is the stable host id. A kept terminal survives with
    /// zero placements until `terminal.close` or `close-terminal`.
    pub fn set_terminal_keep(&self, terminal_id: &str, keep: bool) -> anyhow::Result<()> {
        self.workspace_registry.lock().unwrap().set_terminal_keep(terminal_id, keep)?;
        if !keep {
            self.wake_terminal_reaper();
        }
        Ok(())
    }

    /// Whether one hosted terminal is marked `keep`.
    pub fn terminal_keep(&self, terminal_id: &str) -> anyhow::Result<bool> {
        self.workspace_registry.lock().unwrap().terminal_keep(terminal_id)
    }

    fn wake_terminal_reaper(&self) {
        if let Some(events) = self.terminal_reaper_events.lock().unwrap().as_ref() {
            events.wake();
        }
    }

    /// Host ids of every live hosted terminal that has no tab placement and
    /// is not marked `keep`.
    pub(crate) fn reapable_terminals(&self) -> anyhow::Result<HashSet<String>> {
        let mut unplaced = {
            let state = self.state.lock().unwrap();
            let placed_runtimes: HashSet<SurfaceId> =
                state.surfaces.values().filter_map(|view| view.terminal_runtime_id()).collect();
            let mut unplaced = HashSet::new();
            for (public_id, runtime) in &state.terminal_catalog {
                if runtime.terminal_runtime_id().is_some_and(|id| placed_runtimes.contains(&id)) {
                    continue;
                }
                let content_id = ContentPublicId::Terminal(public_id.clone());
                if !state.placements_of_content(&content_id).is_empty() {
                    continue;
                }
                if let Some(identity) = self.resource_terminal_host_identity(runtime) {
                    unplaced.insert(identity.terminal_id);
                }
            }
            unplaced
        };
        if unplaced.is_empty() {
            return Ok(unplaced);
        }
        let kept = {
            let mut registry = self.workspace_registry.lock().unwrap();
            if let Err(error) = registry.prune_terminal_keep() {
                self.report_internal_diagnostic(format!("terminal keep prune failed: {error}"));
            }
            registry.kept_terminals()?
        };
        unplaced.retain(|terminal_id| !kept.contains(terminal_id));
        Ok(unplaced)
    }

    /// End one unplaced terminal. The placement and `keep` checks are
    /// repeated atomically with the close, so a terminal that gained a view
    /// or was kept since the caller looked is retained.
    pub(crate) fn reap_unplaced_terminal(&self, terminal_id: &str) -> anyhow::Result<ReapOutcome> {
        let (runtime_view, public_id) = {
            let state = self.state.lock().unwrap();
            let found = state.terminal_catalog.iter().find(|(_, runtime)| {
                self.resource_terminal_host_identity(runtime)
                    .is_some_and(|identity| identity.terminal_id == terminal_id)
            });
            match found {
                Some((public_id, runtime)) => (Some(runtime.id), Some(public_id.clone())),
                None => (None, None),
            }
        };
        let Some(runtime_view) = runtime_view else { return Ok(ReapOutcome::Retained) };
        if self.control_clients.attach_observation(&[runtime_view]).0 {
            return Ok(ReapOutcome::Attached);
        }
        match self.close_terminal_guarded(
            terminal_id,
            None,
            None,
            None,
            &WorkspaceMutation::local(TERMINAL_REAP_MUTATION_ORIGIN),
            TerminalCloseGuard::UnplacedAndNotKept,
        ) {
            Ok(result) => {
                if !result.already_closed {
                    self.emit(MuxEvent::TerminalReaped {
                        terminal_id: terminal_id.to_string(),
                        terminal: public_id.map(|public_id| public_id.as_str().to_string()),
                        grace_ms: u64::try_from(self.terminal_reap_grace().as_millis())
                            .unwrap_or(u64::MAX),
                    });
                }
                Ok(ReapOutcome::Reaped)
            }
            Err(error) if error.downcast_ref::<TerminalCloseGuardFailed>().is_some() => {
                Ok(ReapOutcome::Retained)
            }
            Err(error) => Err(error),
        }
    }

    /// One reaper step at `now`: reconcile `schedule` with the current
    /// reapable set and end every terminal whose deadline passed. Returns
    /// the host ids it ended.
    pub(crate) fn reap_unplaced_terminals(
        &self,
        schedule: &mut ReapSchedule,
        now: Instant,
    ) -> Vec<String> {
        let grace = self.terminal_reap_grace();
        match self.reapable_terminals() {
            Ok(reapable) => schedule.observe(now, grace, &reapable),
            Err(error) => {
                self.report_internal_diagnostic(format!("terminal reap scan failed: {error}"));
                return Vec::new();
            }
        }
        let mut reaped = Vec::new();
        for terminal_id in schedule.due(now) {
            match self.reap_unplaced_terminal(&terminal_id) {
                Ok(ReapOutcome::Reaped) => {
                    schedule.forget(&terminal_id);
                    reaped.push(terminal_id);
                }
                Ok(ReapOutcome::Retained) => schedule.forget(&terminal_id),
                // An attached client keeps the terminal for another full
                // grace period; its detach does not emit a topology event.
                Ok(ReapOutcome::Attached) => {
                    schedule.postpone(&terminal_id, deadline_after(now, grace.max(MIN_RETRY)))
                }
                Err(error) => {
                    self.report_internal_diagnostic(format!(
                        "reap of unplaced terminal {terminal_id} failed: {error}"
                    ));
                    schedule.postpone(&terminal_id, deadline_after(now, grace.max(MIN_RETRY)));
                }
            }
        }
        reaped
    }

    /// End every live hosted terminal and remove its placements. Used by
    /// `shutdown-daemon` with `end_terminals` for test teardown; a normal
    /// shutdown keeps hosts alive for the next owner. Returns the host ids
    /// it ended.
    pub fn end_all_terminals(&self) -> anyhow::Result<Vec<String>> {
        let terminals = self.workspace_registry.lock().unwrap().terminal_snapshot()?.terminals;
        let mut ended = Vec::new();
        let mut failures = Vec::new();
        for terminal in terminals {
            if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                continue;
            }
            match self.close_terminal_with_mutation(
                &terminal.terminal_id,
                None,
                None,
                None,
                &WorkspaceMutation::local(END_TERMINALS_MUTATION_ORIGIN),
            ) {
                Ok(_) => ended.push(terminal.terminal_id),
                Err(error) => failures.push(format!("{}: {error}", terminal.terminal_id)),
            }
        }
        // Every host was asked to exit in parallel; wait for them so the
        // caller can rely on no host outliving this call.
        let drained = self.wait_for_terminal_host_closes(Instant::now() + TERMINAL_HOST_CLOSE_WAIT);
        anyhow::ensure!(
            failures.is_empty(),
            "could not end {} terminal(s): {}",
            failures.len(),
            failures.join("; ")
        );
        if !drained {
            // Each remaining host record is already under retrying cleanup.
            eprintln!("cmux-tui: some ended terminal hosts had not exited by the close deadline");
        }
        Ok(ended)
    }
}

/// Retry delay for an attached or failed reap when the grace period is zero.
const MIN_RETRY: Duration = Duration::from_secs(1);

/// Owner-side reaper thread. `stop` wakes and joins it; dropping the handle
/// wakes it without joining.
pub struct TerminalReaper {
    stop: Arc<AtomicBool>,
    /// The receiver the thread currently waits on; it changes when an
    /// overflowed subscription is replaced.
    events: Arc<Mutex<MuxEventReceiver>>,
    thread: Option<JoinHandle<()>>,
}

impl TerminalReaper {
    pub fn stop(mut self) {
        self.signal_stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }

    fn signal_stop(&self) {
        self.stop.store(true, Ordering::Release);
        self.events.lock().unwrap().close();
    }
}

impl Drop for TerminalReaper {
    fn drop(&mut self) {
        self.signal_stop();
    }
}

/// Start the unplaced-terminal reaper for an owner with the mux's current
/// grace period. It runs until stopped or the mux is gone.
pub fn start_terminal_reaper(mux: &Arc<Mux>) -> std::io::Result<TerminalReaper> {
    let stop = Arc::new(AtomicBool::new(false));
    let events = Arc::new(Mutex::new(mux.subscribe_terminal_reaper()));
    let weak = Arc::downgrade(mux);
    let thread_stop = stop.clone();
    let shared_events = events.clone();
    let mut thread_events = events.lock().unwrap().clone();
    let thread = std::thread::Builder::new().name("mux-terminal-reap".into()).spawn(move || {
        let mut schedule = ReapSchedule::default();
        loop {
            if thread_stop.load(Ordering::Acquire) {
                break;
            }
            let Some(mux) = weak.upgrade() else { break };
            mux.reap_unplaced_terminals(&mut schedule, Instant::now());
            let wait =
                schedule.next_deadline().map(|at| at.saturating_duration_since(Instant::now()));
            let event = match wait {
                Some(wait) => thread_events.recv_timeout(wait),
                None => thread_events.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match event {
                Ok(_) | Err(RecvTimeoutError::Timeout) => {
                    // Coalesce a burst of topology events into one scan. A
                    // disconnect surfaces at the next wait.
                    while thread_events.try_recv().is_ok() {}
                }
                Err(RecvTimeoutError::Disconnected) => {
                    if thread_stop.load(Ordering::Acquire) {
                        break;
                    }
                    // The mailbox overflowed: resubscribe, then rescan. The
                    // loop checks `stop` again before it next waits.
                    thread_events = mux.subscribe_terminal_reaper();
                    *shared_events.lock().unwrap() = thread_events.clone();
                }
            }
            drop(mux);
        }
    });
    let thread = match thread {
        Ok(thread) => thread,
        Err(error) => {
            mux.terminal_reaper_events.lock().unwrap().take();
            return Err(error);
        }
    };
    Ok(TerminalReaper { stop, events, thread: Some(thread) })
}

impl Mux {
    /// Subscribe the reaper to the events that can change the reapable set,
    /// and keep a handle so keep and grace changes can wake it.
    fn subscribe_terminal_reaper(&self) -> MuxEventReceiver {
        let events = self.subscribers.subscribe_terminal_topology();
        *self.terminal_reaper_events.lock().unwrap() = Some(events.clone());
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GRACE: Duration = Duration::from_secs(30);

    fn set(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|id| id.to_string()).collect()
    }

    #[test]
    fn terminal_reap_schedule_is_due_only_after_the_grace_period() {
        let start = Instant::now();
        let mut schedule = ReapSchedule::default();
        schedule.observe(start, GRACE, &set(&["a"]));
        assert!(schedule.due(start).is_empty());
        assert!(schedule.due(start + GRACE - Duration::from_millis(1)).is_empty());
        assert_eq!(schedule.due(start + GRACE), vec!["a".to_string()]);
        assert_eq!(schedule.next_deadline(), Some(start + GRACE));
    }

    #[test]
    fn terminal_reap_schedule_keeps_the_first_deadline_across_rescans() {
        let start = Instant::now();
        let mut schedule = ReapSchedule::default();
        schedule.observe(start, GRACE, &set(&["a"]));
        schedule.observe(start + Duration::from_secs(20), GRACE, &set(&["a", "b"]));
        assert_eq!(schedule.deadline("a"), Some(start + GRACE));
        assert_eq!(schedule.deadline("b"), Some(start + Duration::from_secs(50)));
        assert_eq!(schedule.due(start + GRACE), vec!["a".to_string()]);
    }

    #[test]
    fn terminal_reap_schedule_cancels_when_a_placement_returns() {
        let start = Instant::now();
        let mut schedule = ReapSchedule::default();
        schedule.observe(start, GRACE, &set(&["undo"]));
        // Layout undo restored a placement within the grace period.
        schedule.observe(start + Duration::from_secs(10), GRACE, &set(&[]));
        assert_eq!(schedule.next_deadline(), None);
        assert!(schedule.due(start + 10 * GRACE).is_empty());
        // Detaching again starts a fresh full grace period.
        let detached = start + Duration::from_secs(40);
        schedule.observe(detached, GRACE, &set(&["undo"]));
        assert!(schedule.due(detached + GRACE - Duration::from_millis(1)).is_empty());
        assert_eq!(schedule.due(detached + GRACE), vec!["undo".to_string()]);
    }

    #[test]
    fn terminal_reap_schedule_with_zero_grace_is_due_immediately() {
        let start = Instant::now();
        let mut schedule = ReapSchedule::default();
        schedule.observe(start, Duration::ZERO, &set(&["now"]));
        assert_eq!(schedule.due(start), vec!["now".to_string()]);
    }

    #[test]
    fn terminal_reap_schedule_postpone_and_forget() {
        let start = Instant::now();
        let mut schedule = ReapSchedule::default();
        schedule.observe(start, GRACE, &set(&["attached"]));
        schedule.postpone("attached", start + 2 * GRACE);
        assert!(schedule.due(start + GRACE).is_empty());
        assert_eq!(schedule.due(start + 2 * GRACE), vec!["attached".to_string()]);
        schedule.forget("attached");
        assert_eq!(schedule.next_deadline(), None);
    }

    fn host_id(mux: &Arc<Mux>, surface: &Arc<Surface>) -> String {
        mux.resource_terminal_host_identity(surface).expect("test terminal is hosted").terminal_id
    }

    fn lifecycle(mux: &Arc<Mux>, terminal_id: &str) -> TerminalLifecycle {
        mux.resolve_terminal(terminal_id).unwrap().unwrap().terminal.lifecycle
    }

    fn close_workspace_of(mux: &Arc<Mux>, surface: &Arc<Surface>) {
        let workspace = mux.surface_workspace(surface.id).expect("terminal has a workspace");
        assert!(mux.close_workspace_at_revision(workspace, None).unwrap().is_some());
    }

    #[test]
    fn terminal_reap_ends_unplaced_terminals_after_grace_but_not_kept_ones() {
        let mux = Mux::new_for_test("terminal-reap", SurfaceOptions::default());
        let grace = mux.terminal_reap_grace();
        assert_eq!(grace, DEFAULT_TERMINAL_REAP_GRACE);
        let scratch = mux.new_workspace(Some("scratch".into()), Some((80, 24))).unwrap();
        let doomed = mux.new_workspace(Some("doomed".into()), Some((80, 24))).unwrap();
        let kept = mux.new_workspace(Some("kept".into()), Some((80, 24))).unwrap();
        let doomed_id = host_id(&mux, &doomed);
        let kept_id = host_id(&mux, &kept);
        mux.set_terminal_keep(&kept_id, true).unwrap();
        assert!(mux.terminal_keep(&kept_id).unwrap());

        let mut schedule = ReapSchedule::default();
        let start = Instant::now();
        assert!(mux.reap_unplaced_terminals(&mut schedule, start).is_empty());
        assert_eq!(schedule.next_deadline(), None, "placed terminals have no deadline");

        close_workspace_of(&mux, &doomed);
        close_workspace_of(&mux, &kept);
        assert!(mux.reapable_terminals().unwrap().contains(&doomed_id));
        assert!(!mux.reapable_terminals().unwrap().contains(&kept_id));
        assert!(mux.reap_unplaced_terminals(&mut schedule, start).is_empty());
        let almost = start + grace - Duration::from_millis(1);
        assert!(mux.reap_unplaced_terminals(&mut schedule, almost).is_empty());
        assert_eq!(lifecycle(&mux, &doomed_id), TerminalLifecycle::Running);

        let events = mux.subscribe();
        assert_eq!(
            mux.reap_unplaced_terminals(&mut schedule, start + grace),
            vec![doomed_id.clone()]
        );
        assert_eq!(lifecycle(&mux, &doomed_id), TerminalLifecycle::Tombstoned);
        assert_eq!(lifecycle(&mux, &kept_id), TerminalLifecycle::Running);
        assert!(events.try_iter().any(|event| matches!(
            event,
            MuxEvent::TerminalReaped { terminal_id, terminal: Some(_), grace_ms }
                if terminal_id == doomed_id && grace_ms == 30_000
        )));
        assert!(mux.reap_unplaced_terminals(&mut schedule, start + 100 * grace).is_empty());

        // Unmarking keep makes the detached terminal reapable again.
        mux.set_terminal_keep(&kept_id, false).unwrap();
        let unkept = start + 101 * grace;
        assert!(mux.reap_unplaced_terminals(&mut schedule, unkept).is_empty());
        assert_eq!(mux.reap_unplaced_terminals(&mut schedule, unkept + grace), vec![kept_id]);
        assert_eq!(lifecycle(&mux, &host_id(&mux, &scratch)), TerminalLifecycle::Running);
        mux.close_surface(scratch.id).unwrap();
    }

    #[test]
    fn terminal_reap_is_cancelled_when_a_placement_returns_within_grace() {
        let mux = Mux::new_for_test("terminal-reap-undo", SurfaceOptions::default());
        let grace = mux.terminal_reap_grace();
        let scratch = mux.new_workspace(Some("scratch".into()), Some((80, 24))).unwrap();
        let detached = mux.new_workspace(Some("detached".into()), Some((80, 24))).unwrap();
        let detached_id = host_id(&mux, &detached);
        let public_id = detached.terminal_public_id().cloned().unwrap();
        close_workspace_of(&mux, &detached);

        let mut schedule = ReapSchedule::default();
        let start = Instant::now();
        assert!(mux.reap_unplaced_terminals(&mut schedule, start).is_empty());
        assert_eq!(schedule.next_deadline(), Some(start + grace));

        // Project the detached terminal into the scratch pane before the
        // grace period ends, as a layout undo or reattach would.
        let pane = mux.with_state(|state| state.pane_of(scratch.id).unwrap());
        mux.resource_project_terminal_selected(
            crate::ResourceSelectors {
                terminal: Some(public_id.to_string()),
                ..Mux::ordinary_resource_selectors()
            },
            mux.ordinary_pane_selectors(pane).unwrap(),
            usize::MAX,
            None,
            None,
            &WorkspaceMutation::local("test-terminal-reap-projection"),
        )
        .unwrap();
        assert!(mux.reap_unplaced_terminals(&mut schedule, start + grace).is_empty());
        assert_eq!(schedule.next_deadline(), None);
        assert_eq!(lifecycle(&mux, &detached_id), TerminalLifecycle::Running);

        // The atomic guard also refuses a stale due entry for a placed view.
        assert_eq!(mux.reap_unplaced_terminal(&detached_id).unwrap(), ReapOutcome::Retained);
        assert_eq!(lifecycle(&mux, &detached_id), TerminalLifecycle::Running);
        mux.close_terminal_with_mutation(
            &detached_id,
            None,
            None,
            None,
            &WorkspaceMutation::local("test-cleanup"),
        )
        .unwrap();
        mux.close_surface(scratch.id).unwrap();
    }

    #[test]
    fn terminal_reap_with_zero_grace_ends_a_detached_terminal_through_the_thread() {
        let mux = Mux::new_for_test("terminal-reap-thread", SurfaceOptions::default());
        mux.set_terminal_reap_grace(Duration::ZERO).unwrap();
        let reaper = start_terminal_reaper(&mux).unwrap();
        let scratch = mux.new_workspace(Some("scratch".into()), Some((80, 24))).unwrap();
        let detached = mux.new_workspace(Some("detached".into()), Some((80, 24))).unwrap();
        let detached_id = host_id(&mux, &detached);
        close_workspace_of(&mux, &detached);
        let deadline = Instant::now() + Duration::from_secs(10);
        while lifecycle(&mux, &detached_id) != TerminalLifecycle::Tombstoned {
            assert!(Instant::now() < deadline, "the reaper did not end the detached terminal");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(lifecycle(&mux, &host_id(&mux, &scratch)), TerminalLifecycle::Running);
        reaper.stop();
        mux.close_surface(scratch.id).unwrap();
    }

    #[test]
    fn end_all_terminals_ends_placed_and_detached_terminals() {
        let mux = Mux::new_for_test("terminal-end-all", SurfaceOptions::default());
        let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
        let detached = mux.new_workspace(Some("detached".into()), Some((80, 24))).unwrap();
        let placed_id = host_id(&mux, &placed);
        let detached_id = host_id(&mux, &detached);
        mux.set_terminal_keep(&detached_id, true).unwrap();
        close_workspace_of(&mux, &detached);
        let mut ended = mux.end_all_terminals().unwrap();
        ended.sort();
        let mut expected = vec![placed_id.clone(), detached_id.clone()];
        expected.sort();
        assert_eq!(ended, expected);
        assert_eq!(lifecycle(&mux, &placed_id), TerminalLifecycle::Tombstoned);
        assert_eq!(lifecycle(&mux, &detached_id), TerminalLifecycle::Tombstoned);
        assert_eq!(mux.terminal_host_closes.pending(), 0);
    }

    #[test]
    fn terminal_reap_grace_is_bounded() {
        assert!(validate_terminal_reap_grace(Duration::ZERO).is_ok());
        assert!(validate_terminal_reap_grace(MAX_TERMINAL_REAP_GRACE).is_ok());
        assert!(
            validate_terminal_reap_grace(MAX_TERMINAL_REAP_GRACE + Duration::from_secs(1)).is_err()
        );
    }
}
