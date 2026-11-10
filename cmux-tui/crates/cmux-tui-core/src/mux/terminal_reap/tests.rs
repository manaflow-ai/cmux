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

/// The terminal runtime view of the hosted terminal `terminal_id`.
fn runtime_view(mux: &Arc<Mux>, terminal_id: &str) -> SurfaceId {
    let state = mux.state.lock().unwrap();
    state
        .terminal_catalog
        .values()
        .find(|runtime| {
            mux.resource_terminal_host_identity(runtime)
                .is_some_and(|identity| identity.terminal_id == terminal_id)
        })
        .map(|runtime| runtime.id)
        .expect("the terminal has a runtime")
}

/// The grace cap counted attached closed terminals, which the reaper cannot end: next to 16
/// detached ones, an attached terminal made the reaper end the longest-closed detached terminal
/// inside its grace, and an attached one was picked first and tried again on every pass.
#[test]
fn terminal_reap_attached_terminals_do_not_count_toward_the_grace_cap() {
    let mut reapable: HashMap<String, Duration> = (0..MAX_TERMINALS_IN_REAP_GRACE)
        .map(|index| (format!("detached-{index:02}"), Duration::from_millis(1_000 - index as u64)))
        .collect();
    reapable.insert("attached-new".to_string(), Duration::from_millis(1));
    reapable.insert("attached-old".to_string(), Duration::from_secs(60));
    let attached = set(&["attached-new", "attached-old"]);
    assert_eq!(
        over_grace_cap(&reapable, &attached),
        Vec::<String>::new(),
        "{MAX_TERMINALS_IN_REAP_GRACE} detached closed terminals are within the cap, but attached \
         ones counted toward it and a detached terminal was picked to end inside its grace"
    );
    reapable.insert("detached-16".to_string(), Duration::from_millis(500));
    assert_eq!(
        over_grace_cap(&reapable, &attached),
        vec!["detached-00".to_string()],
        "past the cap the longest-closed detached terminal ends, never an attached one"
    );
}

/// The reaper checked attach streams before its close, outside the close's locks (the screen
/// archive capture sits in between): a client that attached in that gap lost the terminal it had
/// just attached to. The reap close checks attach streams under the same locks as the close.
#[test]
fn terminal_reap_attached_terminal_survives_the_guarded_reap_close() {
    let mux = Mux::new_for_test("terminal-reap-attach-guard", SurfaceOptions::default());
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let closed = mux.new_workspace(Some("closed".into()), Some((80, 24))).unwrap();
    let terminal_id = host_id(&mux, &closed);
    close_workspace_of(&mux, &closed);
    mux.control_clients.attach_test_stream(runtime_view(&mux, &terminal_id));
    let result = mux.close_terminal_guarded(
        &terminal_id,
        None,
        None,
        None,
        &WorkspaceMutation::local(TERMINAL_REAP_MUTATION_ORIGIN),
        TerminalCloseGuard::UnplacedAndDetached,
    );
    assert_eq!(
        lifecycle(&mux, &terminal_id),
        TerminalLifecycle::Running,
        "the guarded reap close ended a terminal a client is attached to: {result:?}"
    );
    let failure =
        result.err().and_then(|error| error.downcast_ref::<TerminalCloseGuardFailed>().copied());
    assert_eq!(failure, Some(TerminalCloseGuardFailed::Attached), "the guard names the attach");
    mux.close_terminal_with_mutation(
        &terminal_id,
        None,
        None,
        None,
        &WorkspaceMutation::local("test-cleanup"),
    )
    .unwrap();
    mux.close_surface(placed.id).unwrap();
}

/// The owner binds its socket after it starts the reaper thread, so a second
/// owner that loses the bind must not reap: a held reaper runs no pass, even
/// with a zero grace and a detached terminal, until the owner releases it.
#[test]
fn terminal_reap_a_held_reaper_does_not_reap_until_released() {
    let mux = Mux::new_for_test("terminal-reap-held", SurfaceOptions::default());
    mux.set_terminal_reap_grace(Duration::ZERO).unwrap();
    let scratch = mux.new_workspace(Some("scratch".into()), Some((80, 24))).unwrap();
    let detached = mux.new_workspace(Some("detached".into()), Some((80, 24))).unwrap();
    let detached_id = host_id(&mux, &detached);
    close_workspace_of(&mux, &detached);
    let held = prepare_terminal_reaper(&mux).unwrap();
    assert!(mux.terminal_reaper_advertised(), "identify does not list a held reaper");
    // A running reaper with a zero grace ends the detached terminal on its
    // first pass, at once; a held one never does.
    let watch_until = Instant::now() + Duration::from_millis(500);
    while Instant::now() < watch_until {
        assert_eq!(
            lifecycle(&mux, &detached_id),
            TerminalLifecycle::Running,
            "the held reaper ended a terminal before the owner released it"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let reaper = held.release();
    let deadline = Instant::now() + Duration::from_secs(10);
    while lifecycle(&mux, &detached_id) != TerminalLifecycle::Tombstoned {
        assert!(Instant::now() < deadline, "the released reaper did not end the detached terminal");
        std::thread::sleep(Duration::from_millis(10));
    }
    reaper.stop();
    mux.close_surface(scratch.id).unwrap();
}

/// A cancelled held reaper ends its thread, and `identify` no longer lists
/// the reaper when `cancel` returns.
#[test]
fn terminal_reap_a_cancelled_held_reaper_is_no_longer_advertised() {
    let mux = Mux::new_for_test("terminal-reap-held-cancel", SurfaceOptions::default());
    let held = prepare_terminal_reaper(&mux).unwrap();
    assert!(mux.terminal_reaper_advertised());
    held.cancel();
    assert!(!mux.terminal_reaper_advertised(), "a cancelled held reaper is still advertised");
}

/// A bind or a later startup step that fails drops the held reaper without a
/// join: the thread still ends, and `identify` stops listing the reaper.
#[test]
fn terminal_reap_a_dropped_held_reaper_is_no_longer_advertised() {
    let mux = Mux::new_for_test("terminal-reap-held-drop", SurfaceOptions::default());
    let held = prepare_terminal_reaper(&mux).unwrap();
    assert!(mux.terminal_reaper_advertised());
    drop(held);
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.terminal_reaper_advertised() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!mux.terminal_reaper_advertised(), "a dropped held reaper is still advertised");
}

/// A reaper that ends late clears only its own subscription, never that of a
/// reaper started after it.
#[test]
fn terminal_reap_an_ended_reaper_does_not_clear_a_newer_reapers_advertisement() {
    let mux = Mux::new_for_test("terminal-reap-held-newer", SurfaceOptions::default());
    let older = prepare_terminal_reaper(&mux).unwrap();
    let newer = start_terminal_reaper(&mux).unwrap();
    older.cancel();
    assert!(mux.terminal_reaper_advertised(), "an ended older reaper cleared the newer one");
    newer.stop();
    assert!(!mux.terminal_reaper_advertised());
}

/// A daemon in a shutdown handoff gives its terminals to the next owner: the
/// reaper must not end one on the way out, neither in a pass nor through the
/// guarded close. (The handoff also flushes its acknowledgement under the
/// client registry's lock, so a reap close that waited for that lock under
/// the mux locks stalled the whole mux for up to 5 s.)
#[test]
fn terminal_reap_ends_no_terminal_during_a_daemon_handoff() {
    let mux = Mux::new_for_test("terminal-reap-handoff", SurfaceOptions::default());
    mux.set_terminal_reap_grace(Duration::ZERO).unwrap();
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let closed = mux.new_workspace(Some("closed".into()), Some((80, 24))).unwrap();
    let terminal_id = host_id(&mux, &closed);
    close_workspace_of(&mux, &closed);
    let requester = mux.control_clients.attach_test_stream(placed.id);
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(true)).unwrap();
    let mut schedule = ReapSchedule::default();
    let reaped = mux.reap_unplaced_terminals(&mut schedule, Instant::now());
    assert!(reaped.is_empty(), "a daemon in a handoff reaped {reaped:?}");
    let guarded = mux.close_terminal_guarded(
        &terminal_id,
        None,
        None,
        None,
        &WorkspaceMutation::local(TERMINAL_REAP_MUTATION_ORIGIN),
        TerminalCloseGuard::UnplacedAndDetached,
    );
    assert_eq!(
        lifecycle(&mux, &terminal_id),
        TerminalLifecycle::Running,
        "the guarded reap close ended a terminal during a daemon handoff: {guarded:?}"
    );
    let failure = guarded
        .as_ref()
        .err()
        .and_then(|error| error.downcast_ref::<TerminalCloseGuardFailed>().copied());
    assert_eq!(failure, Some(TerminalCloseGuardFailed::HandingOff), "the guard names the handoff");
    // A cancelled handoff reaps again, one grace (at least a second) later.
    mux.cancel_daemon_handoff(requester);
    let later = Instant::now() + MIN_RETRY;
    assert_eq!(mux.reap_unplaced_terminals(&mut schedule, later), vec![terminal_id.clone()]);
    assert_eq!(lifecycle(&mux, &terminal_id), TerminalLifecycle::Tombstoned);
    mux.close_surface(placed.id).unwrap();
}

/// The cap's attach read (`attached_reap_candidates`) runs in a real pass:
/// with 17 closed terminals and one of them attached, the 16 detached ones
/// are within the cap, so no terminal ends before its grace.
#[test]
fn terminal_reap_pass_past_the_cap_skips_an_attached_terminal() {
    let mux = Mux::new_for_test("terminal-reap-cap-attach-pass", SurfaceOptions::default());
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let closed: Vec<String> = (0..=MAX_TERMINALS_IN_REAP_GRACE)
        .map(|index| {
            let surface =
                mux.new_workspace(Some(format!("closed-{index}")), Some((80, 24))).unwrap();
            let terminal_id = host_id(&mux, &surface);
            close_workspace_of(&mux, &surface);
            terminal_id
        })
        .collect();
    mux.control_clients.attach_test_stream(runtime_view(&mux, &closed[0]));
    let mut schedule = ReapSchedule::default();
    let reaped = mux.reap_unplaced_terminals(&mut schedule, Instant::now());
    assert!(reaped.is_empty(), "an attached terminal counted toward the cap: {reaped:?}");
    for terminal_id in &closed {
        assert_eq!(lifecycle(&mux, terminal_id), TerminalLifecycle::Running);
        mux.close_terminal_with_mutation(
            terminal_id,
            None,
            None,
            None,
            &WorkspaceMutation::local("test-cleanup"),
        )
        .unwrap();
    }
    mux.close_surface(placed.id).unwrap();
}

/// A terminal without a resource id closes through the legacy path in
/// `close_terminal_guarded`; its guard also keeps an attached terminal.
#[test]
fn terminal_reap_legacy_close_keeps_an_attached_terminal() {
    let mux = Mux::new_for_test("terminal-reap-legacy-attach", SurfaceOptions::default());
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let closed = mux.new_workspace(Some("closed".into()), Some((80, 24))).unwrap();
    let terminal_id = host_id(&mux, &closed);
    close_workspace_of(&mux, &closed);
    mux.control_clients.attach_test_stream(runtime_view(&mux, &terminal_id));
    mux.workspace_registry
        .lock()
        .unwrap()
        .set_terminal_resource_hidden_for_test(&terminal_id, true)
        .unwrap();
    let result = mux.close_terminal_guarded(
        &terminal_id,
        None,
        None,
        None,
        &WorkspaceMutation::local(TERMINAL_REAP_MUTATION_ORIGIN),
        TerminalCloseGuard::UnplacedAndDetached,
    );
    mux.workspace_registry
        .lock()
        .unwrap()
        .set_terminal_resource_hidden_for_test(&terminal_id, false)
        .unwrap();
    let failure = result
        .as_ref()
        .err()
        .and_then(|error| error.downcast_ref::<TerminalCloseGuardFailed>().copied());
    assert_eq!(
        failure,
        Some(TerminalCloseGuardFailed::Attached),
        "the legacy guarded close did not keep an attached terminal: {result:?}"
    );
    assert_eq!(lifecycle(&mux, &terminal_id), TerminalLifecycle::Running);
    mux.close_terminal_with_mutation(
        &terminal_id,
        None,
        None,
        None,
        &WorkspaceMutation::local("test-cleanup"),
    )
    .unwrap();
    mux.close_surface(placed.id).unwrap();
}

/// The legacy close path (a terminal without a resource id) also keeps every
/// terminal during a daemon handoff.
#[test]
fn terminal_reap_legacy_close_ends_no_terminal_during_a_daemon_handoff() {
    let mux = Mux::new_for_test("terminal-reap-legacy-handoff", SurfaceOptions::default());
    let placed = mux.new_workspace(Some("placed".into()), Some((80, 24))).unwrap();
    let closed = mux.new_workspace(Some("closed".into()), Some((80, 24))).unwrap();
    let terminal_id = host_id(&mux, &closed);
    close_workspace_of(&mux, &closed);
    let requester = mux.control_clients.attach_test_stream(placed.id);
    mux.begin_daemon_handoff(requester, DaemonHandoffRequest::unfenced(true)).unwrap();
    mux.workspace_registry
        .lock()
        .unwrap()
        .set_terminal_resource_hidden_for_test(&terminal_id, true)
        .unwrap();
    let result = mux.close_terminal_guarded(
        &terminal_id,
        None,
        None,
        None,
        &WorkspaceMutation::local(TERMINAL_REAP_MUTATION_ORIGIN),
        TerminalCloseGuard::UnplacedAndDetached,
    );
    mux.workspace_registry
        .lock()
        .unwrap()
        .set_terminal_resource_hidden_for_test(&terminal_id, false)
        .unwrap();
    let failure = result
        .as_ref()
        .err()
        .and_then(|error| error.downcast_ref::<TerminalCloseGuardFailed>().copied());
    assert_eq!(
        failure,
        Some(TerminalCloseGuardFailed::HandingOff),
        "the legacy guarded close did not keep a terminal during a handoff: {result:?}"
    );
    assert_eq!(lifecycle(&mux, &terminal_id), TerminalLifecycle::Running);
    mux.cancel_daemon_handoff(requester);
    mux.close_terminal_with_mutation(
        &terminal_id,
        None,
        None,
        None,
        &WorkspaceMutation::local("test-cleanup"),
    )
    .unwrap();
    mux.close_surface(placed.id).unwrap();
}
