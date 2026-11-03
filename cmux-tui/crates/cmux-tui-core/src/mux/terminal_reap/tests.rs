//! Unit tests for `terminal_reap`.

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

/// A terminal unplaced for longer than the grace (its time is durable across
/// restarts) that a reap attempt leaves running, because the close guard
/// still sees it placed or it stayed listed after its close, is still
/// reapable at the next scan. That scan must not find it due again: it was
/// re-added at its durable unplaced time, due at once, so every wake (and the
/// zero wait to its own deadline) ran another attempt (a registry prune and
/// write, a screen capture and a guarded close), and the app's headless owner
/// sat at 150% CPU.
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
/// lists the terminal (closed, placed again or kept), as a forget did.
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
fn a_tabless_terminal_keeps_its_lifecycle_when_the_tree_is_republished() {
    let mux = Mux::new_for_test("terminal-tabless-lifecycle", SurfaceOptions::default());
    let scratch = mux.new_workspace(Some("scratch".into()), Some((80, 24))).unwrap();
    let detached = mux.new_workspace(Some("detached".into()), Some((80, 24))).unwrap();
    let detached_id = host_id(&mux, &detached);
    let public_id = detached.terminal_public_id().cloned().unwrap().to_string();
    close_workspace_of(&mux, &detached);
    // Any later full projection (a tab drag, a docked column) republishes
    // the terminal whose last tab closed; clients decode `lifecycle` as
    // required on every terminal record.
    let projection = mux.resource_effect_projection().unwrap();
    let records = format!("{:?}", projection.patch);
    assert!(records.contains(&public_id), "the projection publishes the tab-less terminal");
    for change in projection.changes.as_array().unwrap() {
        if change["resource"] == "terminal" && change["kind"] != "delete" {
            assert!(
                change["value"]["lifecycle"].is_string(),
                "terminal record without lifecycle: {change}"
            );
        }
    }
    mux.close_terminal_with_mutation(
        &detached_id,
        None,
        None,
        None,
        &WorkspaceMutation::daemon_local("test-cleanup"),
    )
    .unwrap();
    mux.close_surface(scratch.id).unwrap();
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
    let (reapable, retained) = mux.reapable_and_retained_terminals().unwrap();
    assert!(reapable.contains(&doomed_id));
    assert!(!reapable.contains(&kept_id));
    assert!(retained.contains(&kept_id), "a kept terminal is retained");
    assert!(mux.reap_unplaced_terminals(&mut schedule, start).is_empty());
    let almost = start + grace - Duration::from_millis(1);
    assert!(mux.reap_unplaced_terminals(&mut schedule, almost).is_empty());
    assert_eq!(lifecycle(&mux, &doomed_id), TerminalLifecycle::Running);

    let events = mux.subscribe();
    assert_eq!(mux.reap_unplaced_terminals(&mut schedule, start + grace), vec![doomed_id.clone()]);
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

/// P0 TERMINAL-HOST LEAK: the grace runs across an owner restart. The
/// restarted owner's schedule starts empty, but the registry keeps when the
/// terminal was closed: closed a full grace ago, it is reaped on the first
/// pass, and the placed terminal is not.
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
        &WorkspaceMutation::daemon_local("test-terminal-reap-projection"),
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
        &WorkspaceMutation::daemon_local("test-cleanup"),
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
fn end_all_terminals_keeps_emptied_workspaces() {
    let mux = Mux::new_for_test("terminal-end-all-layout", SurfaceOptions::default());
    let first = mux.new_workspace(Some("first".into()), Some((80, 24))).unwrap();
    let second = mux.new_workspace(Some("second".into()), Some((80, 24))).unwrap();
    // The host identity is read before the end: an ended terminal's surface has none.
    let (first_id, second_id) = (host_id(&mux, &first), host_id(&mux, &second));

    mux.end_all_terminals().unwrap();

    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 2);
        assert!(state.workspaces.iter().all(|workspace| workspace.screens.is_empty()));
    });
    assert_eq!(lifecycle(&mux, &first_id), TerminalLifecycle::Tombstoned);
    assert_eq!(lifecycle(&mux, &second_id), TerminalLifecycle::Tombstoned);
}

#[test]
fn terminal_reap_grace_is_bounded() {
    assert!(validate_terminal_reap_grace(Duration::ZERO).is_ok());
    assert!(validate_terminal_reap_grace(MAX_TERMINAL_REAP_GRACE).is_ok());
    assert!(
        validate_terminal_reap_grace(MAX_TERMINAL_REAP_GRACE + Duration::from_secs(1)).is_err()
    );
}

/// PTY LEAK (STATUS 7938): a closed tab's terminal lives out the reap grace (30 s in the app) so the
/// tab can come back, and holds its PTY meanwhile. A burst of tab closes then left the machine's PTYs
/// (511 on macOS) held by terminals no tab shows, and every new tab was refused ("PTY capacity
/// exhausted"): the PTY reclaim parked only idle shells that a tab still shows. When PTYs are low,
/// a reclaim pass ends the closed terminals waiting out their grace first, oldest close first; a
/// placed terminal keeps running.
#[test]
fn a_reclaim_pass_ends_closed_terminals_waiting_out_the_grace_when_ptys_are_low() {
    let mux = Mux::new_for_test("pty-reclaim-unplaced", SurfaceOptions::default());
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let closed = mux.new_workspace(Some("closed".into()), Some((80, 24))).unwrap();
    let closed_id = host_id(&mux, &closed);
    close_workspace_of(&mux, &closed);
    // Inside its grace: the reaper alone would keep it.
    let mut schedule = ReapSchedule::default();
    assert!(mux.reap_unplaced_terminals(&mut schedule, Instant::now()).is_empty());
    assert_eq!(lifecycle(&mux, &closed_id), TerminalLifecycle::Running);

    pty_reclaim::set_pty_usage_for_test(Some((500, 511)));
    let mut clock = pty_reclaim::ReclaimClock::default();
    mux.note_pty_exhausted();
    let _ = mux.reclaim_ptys_if_low(&mut clock);
    pty_reclaim::set_pty_usage_for_test(None);

    assert_eq!(
        lifecycle(&mux, &closed_id),
        TerminalLifecycle::Tombstoned,
        "PTYs were low and a closed tab's terminal still held one"
    );
    assert_eq!(lifecycle(&mux, &host_id(&mux, &placed)), TerminalLifecycle::Running);
    mux.close_surface(placed.id).unwrap();
}

/// PTY HOLD (VIDEO EXTRA, STATUS 7998): every closed tab's terminal lived out the whole reap grace
/// (30 s in the app) with its PTY. A script closing about 5 tabs a second (the L6 storm) piled up
/// closed-but-held PTYs and reached the machine's limit (511) in 48 s. The grace keeps a recent close
/// undoable; it must not hold an unbounded number of PTYs: past
/// [`MAX_TERMINALS_IN_REAP_GRACE`] closed terminals, the reaper ends the longest-closed at once.
#[test]
fn closed_terminals_past_the_grace_cap_end_at_once() {
    let mux = Mux::new_for_test("terminal-reap-cap", SurfaceOptions::default());
    let extra = 2;
    // Every workspace first: a create after a reap trips the scoped-projection cross-check on the
    // base as well (a separate defect, see the PR), so this test closes and reaps only.
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
