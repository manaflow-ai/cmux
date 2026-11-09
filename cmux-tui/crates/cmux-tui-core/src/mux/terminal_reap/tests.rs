//! Unit tests for `terminal_reap` (ported from feat-cmux-next
//! `mux/terminal_reap/tests.rs`; the keep, archive and PTY-reclaim cases
//! come with those features).

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

/// An attached terminal is tried again a full grace later, not on the next
/// wake: its detach emits no topology event.
#[test]
fn terminal_reap_schedule_retries_an_attached_terminal_a_grace_later() {
    let start = Instant::now();
    let mut schedule = ReapSchedule::default();
    schedule.observe(start, GRACE, &set(&["watched"]));
    assert_eq!(schedule.due(start + GRACE), vec!["watched".to_string()]);
    schedule.tried("watched", Some(ReapOutcome::Attached), start + GRACE, GRACE);
    assert!(schedule.due(start + 2 * GRACE - Duration::from_millis(1)).is_empty());
    assert_eq!(schedule.due(start + 2 * GRACE), vec!["watched".to_string()]);
}

/// A terminal unplaced for longer than the grace (its time is durable across
/// restarts) that a reap attempt leaves running, because the close guard
/// still sees it placed or it stayed listed after its close, is still
/// reapable at the next scan. That scan must not find it due again: it was
/// re-added at its durable unplaced time, due at once, so every wake (and the
/// zero wait to its own deadline) ran another attempt (feat #33173: a
/// headless owner at 150% CPU).
#[test]
fn terminal_reap_schedule_waits_after_an_attempt_that_left_the_terminal_reapable() {
    for outcome in [ReapOutcome::Retained, ReapOutcome::Reaped] {
        let start = Instant::now();
        let reapable: HashMap<String, Duration> = [("stuck".to_string(), 3 * GRACE)].into();
        let mut schedule = ReapSchedule::default();

        // A scan on every wake, one a millisecond for a second, as the
        // reaper thread runs one per topology or registry event.
        let mut attempts = 0;
        for ms in 0..1000 {
            let now = start + Duration::from_millis(ms);
            schedule.observe_unplaced(now, GRACE, &reapable);
            for terminal_id in schedule.due(now) {
                schedule.tried(&terminal_id, Some(outcome), now, GRACE);
                attempts += 1;
            }
            assert!(
                schedule.next_deadline().is_none_or(|at| at > now),
                "{outcome:?}: the reaper's next wait is zero"
            );
        }
        assert_eq!(attempts, 1, "{outcome:?}: {attempts} reap attempts within a second");
        assert_eq!(schedule.deadline("stuck"), Some(start + GRACE), "{outcome:?}");
    }
}

/// The deadline an attempt leaves is dropped as soon as a scan no longer
/// lists the terminal (closed or placed again), as a forget did.
#[test]
fn terminal_reap_schedule_drops_a_settled_terminal_once_it_is_no_longer_reapable() {
    let start = Instant::now();
    let reapable: HashMap<String, Duration> = [("gone".to_string(), GRACE)].into();
    let mut schedule = ReapSchedule::default();
    schedule.observe_unplaced(start, GRACE, &reapable);
    schedule.tried("gone", Some(ReapOutcome::Reaped), start, GRACE);
    schedule.observe_unplaced(start, GRACE, &HashMap::new());
    assert_eq!(schedule.next_deadline(), None);
}

/// A terminal placed again during its attempt (`Retained`) and closed again
/// before the next scan gets a full grace from its new unplaced time, not the
/// retry deadline of the attempt.
#[test]
fn terminal_reap_schedule_gives_a_terminal_closed_again_after_a_retained_attempt_a_fresh_grace() {
    let start = Instant::now();
    let mut schedule = ReapSchedule::default();
    schedule.observe_unplaced(start, GRACE, &[("undo".to_string(), GRACE)].into());
    schedule.tried("undo", Some(ReapOutcome::Retained), start, GRACE);
    // Closed again 5 s later; the placement cleared its unplaced time.
    let closed_again = start + Duration::from_secs(5);
    schedule.observe_unplaced(closed_again, GRACE, &[("undo".to_string(), Duration::ZERO)].into());
    assert_eq!(schedule.deadline("undo"), Some(closed_again + GRACE));
}

#[test]
fn terminal_reap_grace_is_bounded() {
    assert!(validate_terminal_reap_grace(Duration::ZERO).is_ok());
    assert!(validate_terminal_reap_grace(MAX_TERMINAL_REAP_GRACE).is_ok());
    assert!(
        validate_terminal_reap_grace(MAX_TERMINAL_REAP_GRACE + Duration::from_secs(1)).is_err()
    );
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

/// A closed workspace's terminal (no tab shows it) ends once the grace
/// passed; a placed terminal keeps running.
#[test]
fn terminal_reap_ends_an_unplaced_terminal_after_the_grace() {
    let mux = Mux::new_for_test("terminal-reap", SurfaceOptions::default());
    let grace = mux.terminal_reap_grace();
    assert_eq!(grace, DEFAULT_TERMINAL_REAP_GRACE);
    let scratch = mux.new_workspace(Some("scratch".into()), Some((80, 24))).unwrap();
    let doomed = mux.new_workspace(Some("doomed".into()), Some((80, 24))).unwrap();
    let doomed_id = host_id(&mux, &doomed);

    let mut schedule = ReapSchedule::default();
    let start = Instant::now();
    assert!(mux.reap_unplaced_terminals(&mut schedule, start).is_empty());
    assert_eq!(schedule.next_deadline(), None, "placed terminals have no deadline");

    close_workspace_of(&mux, &doomed);
    let (reapable, retained) = mux.reapable_and_retained_terminals().unwrap();
    assert!(reapable.contains(&doomed_id), "a closed workspace's terminal is reapable");
    assert!(retained.contains(&host_id(&mux, &scratch)), "a placed terminal is retained");
    assert!(mux.reap_unplaced_terminals(&mut schedule, start).is_empty());
    let almost = start + grace - Duration::from_millis(1);
    assert!(mux.reap_unplaced_terminals(&mut schedule, almost).is_empty());
    assert_eq!(lifecycle(&mux, &doomed_id), TerminalLifecycle::Running);

    assert_eq!(
        mux.reap_unplaced_terminals(&mut schedule, start + grace),
        vec![doomed_id.clone()],
        "the closed workspace's terminal was not ended after the reap grace"
    );
    assert_eq!(lifecycle(&mux, &doomed_id), TerminalLifecycle::Tombstoned);
    assert!(mux.reap_unplaced_terminals(&mut schedule, start + 100 * grace).is_empty());
    assert_eq!(lifecycle(&mux, &host_id(&mux, &scratch)), TerminalLifecycle::Running);
    mux.close_surface(scratch.id).unwrap();
}

/// P0 TERMINAL-HOST LEAK (feat #29476): the grace runs across an owner
/// restart. The restarted owner's schedule starts empty, but the registry
/// keeps when the terminal was closed: closed a full grace ago, it is reaped
/// on the first pass, and the placed terminal is not.
#[test]
fn terminal_reap_grace_runs_across_an_owner_restart() {
    let mux = Mux::new_for_test("terminal-reap-restart", SurfaceOptions::default());
    let grace = mux.terminal_reap_grace();
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let closed = mux.new_workspace(Some("closed".into()), Some((80, 24))).unwrap();
    let closed_id = host_id(&mux, &closed);
    close_workspace_of(&mux, &closed);
    let mut schedule = ReapSchedule::default();
    assert!(mux.reap_unplaced_terminals(&mut schedule, Instant::now()).is_empty());
    // A restart: a new schedule; the terminal was closed a grace ago.
    mux.workspace_registry.lock().unwrap().backdate_terminal_unplaced(&closed_id, grace).unwrap();
    let mut restarted = ReapSchedule::default();
    assert_eq!(
        mux.reap_unplaced_terminals(&mut restarted, Instant::now()),
        vec![closed_id.clone()],
        "a restart must not count the grace again from zero"
    );
    assert_eq!(lifecycle(&mux, &closed_id), TerminalLifecycle::Tombstoned);
    assert_eq!(lifecycle(&mux, &host_id(&mux, &placed)), TerminalLifecycle::Running);
    mux.close_surface(placed.id).unwrap();
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
    assert_eq!(
        schedule.next_deadline(),
        Some(start + grace),
        "a closed workspace's terminal gets a reap deadline one grace away"
    );

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
    assert!(mux.terminal_reaper_running(), "the started reaper is not reported as running");
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
    assert!(!mux.terminal_reaper_running(), "a stopped reaper is still reported as running");
    mux.close_surface(scratch.id).unwrap();
}

/// PTY HOLD (feat STATUS 7998): every closed tab's terminal lived out the
/// whole reap grace with its PTY. A script closing about 5 tabs a second
/// piled up closed-but-held PTYs and reached the machine's limit (511) in
/// 48 s. Past [`MAX_TERMINALS_IN_REAP_GRACE`] closed terminals, the reaper
/// ends the longest-closed at once.
#[test]
fn terminal_reap_ends_closed_terminals_past_the_grace_cap_at_once() {
    let mux = Mux::new_for_test("terminal-reap-cap", SurfaceOptions::default());
    let extra = 2;
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let surfaces: Vec<_> = (0..MAX_TERMINALS_IN_REAP_GRACE + extra)
        .map(|index| mux.new_workspace(Some(format!("closed-{index}")), Some((80, 24))).unwrap())
        .collect();
    let mut schedule = ReapSchedule::default();
    let mut closed = Vec::new();
    let mut reaped = Vec::new();
    // A burst of closes, the reaper woken after each (a topology change wakes it).
    for (index, surface) in surfaces.iter().enumerate() {
        let terminal_id = host_id(&mux, surface);
        close_workspace_of(&mux, surface);
        reaped.extend(mux.reap_unplaced_terminals(&mut schedule, Instant::now()));
        // Distinct close times: the first closed is the longest closed.
        mux.workspace_registry
            .lock()
            .unwrap()
            .backdate_terminal_unplaced(&terminal_id, Duration::from_millis(1_000 - index as u64))
            .unwrap();
        closed.push(terminal_id);
    }
    reaped.extend(mux.reap_unplaced_terminals(&mut schedule, Instant::now()));
    reaped.sort();
    let mut oldest = closed[..extra].to_vec();
    oldest.sort();
    assert_eq!(
        reaped, oldest,
        "inside the grace, only the closed terminals past the cap end, oldest first"
    );
    for terminal_id in &closed[extra..] {
        assert_eq!(
            lifecycle(&mux, terminal_id),
            TerminalLifecycle::Running,
            "a recent close stays undoable"
        );
    }
    assert_eq!(lifecycle(&mux, &host_id(&mux, &placed)), TerminalLifecycle::Running);
    mux.close_surface(placed.id).unwrap();
}
