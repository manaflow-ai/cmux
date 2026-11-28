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
    assert!(mux.reapable_terminals().unwrap().contains(&doomed_id));
    assert!(!mux.reapable_terminals().unwrap().contains(&kept_id));
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
