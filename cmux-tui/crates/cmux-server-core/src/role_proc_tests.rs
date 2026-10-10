use super::*;

fn role(restart: RestartPolicy, ready: Readiness) -> RoleProc {
    RoleProc::new("chief", restart, ready, Duration::from_secs(10))
}

fn up(proc: &mut RoleProc, pid: u32, now: Instant) {
    assert_eq!(proc.step(Input::Start, now), [Action::Spawn]);
    assert!(proc.step(Input::Spawned { pid }, now).is_empty());
}

#[test]
fn started_role_is_ready_at_spawn() {
    let now = Instant::now();
    let mut p = role(RestartPolicy::Always, Readiness::Started);
    assert_eq!(p.health().state, RoleState::Stopped);
    up(&mut p, 7, now);
    let h = p.health();
    assert_eq!((h.state, h.pid), (RoleState::Ready, Some(7)));
}

#[test]
fn notify_role_waits_for_ready_and_keeps_status_text() {
    let now = Instant::now();
    let mut p = role(RestartPolicy::Always, Readiness::Notify);
    up(&mut p, 7, now);
    assert_eq!(p.health().state, RoleState::Starting);
    p.step(Input::StatusText("loading memory".to_owned()), now);
    p.step(Input::Ready, now);
    let h = p.health();
    assert_eq!(h.state, RoleState::Ready);
    assert_eq!(h.status_text.as_deref(), Some("loading memory"));
}

#[test]
fn failures_back_off_doubling_then_crash_loop() {
    let t0 = Instant::now();
    let mut p = role(RestartPolicy::Always, Readiness::Started);
    up(&mut p, 1, t0);
    let mut now = t0;
    let mut delays = Vec::new();
    for pid in 1..=4 {
        let actions = p.step(Input::Exited { pid, code: Some(1) }, now);
        let [Action::WakeAt(at)] = actions.as_slice() else { panic!("{actions:?}") };
        delays.push(at.duration_since(now));
        assert_eq!(p.health().state, RoleState::Backoff);
        // Early wake re-arms, the due wake spawns.
        assert_eq!(p.step(Input::Due, now), [Action::WakeAt(*at)]);
        now = *at;
        assert_eq!(p.step(Input::Due, now), [Action::Spawn]);
        p.step(Input::Spawned { pid: pid + 1 }, now);
    }
    assert_eq!(delays, [1, 2, 4, 8].map(Duration::from_secs));
    assert!(p.step(Input::Exited { pid: 5, code: None }, now).is_empty());
    let h = p.health();
    assert_eq!(h.state, RoleState::CrashLoop);
    assert_eq!(h.last_exit.as_deref(), Some("signal"));
    assert!(h.last_error.unwrap().contains("crash loop"));
    assert!(p.is_down());
    // A new start (config change) clears the window.
    assert_eq!(p.step(Input::Start, now), [Action::Spawn]);
}

#[test]
fn old_failures_leave_the_window() {
    let mut now = Instant::now();
    let mut p = role(RestartPolicy::Always, Readiness::Started);
    up(&mut p, 1, now);
    for pid in 1..=10 {
        now += FAILURE_WINDOW + Duration::from_secs(1);
        let actions = p.step(Input::Exited { pid, code: Some(2) }, now);
        assert_eq!(actions, [Action::WakeAt(now + BACKOFF_FIRST)], "run {pid}");
        now += BACKOFF_FIRST;
        assert_eq!(p.step(Input::Due, now), [Action::Spawn]);
        p.step(Input::Spawned { pid: pid + 1 }, now);
    }
    assert_eq!(p.health().restarts, 10);
}

#[test]
fn restart_policies_on_clean_exit() {
    let now = Instant::now();
    let mut always = role(RestartPolicy::Always, Readiness::Started);
    up(&mut always, 1, now);
    assert_eq!(
        always.step(Input::Exited { pid: 1, code: Some(0) }, now),
        [Action::WakeAt(now + BACKOFF_FIRST)]
    );
    let mut on_failure = role(RestartPolicy::OnFailure, Readiness::Started);
    up(&mut on_failure, 1, now);
    assert!(on_failure.step(Input::Exited { pid: 1, code: Some(0) }, now).is_empty());
    assert_eq!(on_failure.health().state, RoleState::Exited);
    let mut never = role(RestartPolicy::Never, Readiness::Started);
    up(&mut never, 1, now);
    assert!(never.step(Input::Exited { pid: 1, code: Some(3) }, now).is_empty());
    assert_eq!(never.health().state, RoleState::Exited);
}

#[test]
fn stop_terminates_then_kills_after_grace() {
    let now = Instant::now();
    let mut p = role(RestartPolicy::Always, Readiness::Started);
    up(&mut p, 9, now);
    let grace = now + Duration::from_secs(10);
    assert_eq!(p.step(Input::Stop, now), [Action::Terminate { pid: 9 }, Action::WakeAt(grace)]);
    assert_eq!(p.health().state, RoleState::Stopping);
    assert_eq!(p.step(Input::Due, grace), [Action::Kill { pid: 9 }]);
    assert!(p.step(Input::Due, grace).is_empty());
    assert!(p.step(Input::Exited { pid: 9, code: None }, grace).is_empty());
    assert_eq!(p.health().state, RoleState::Stopped);
    assert_eq!(p.health().restarts, 0, "a requested stop is not a failure");
}

#[test]
fn stop_during_spawn_and_backoff() {
    let now = Instant::now();
    let mut p = role(RestartPolicy::Always, Readiness::Started);
    assert_eq!(p.step(Input::Start, now), [Action::Spawn]);
    assert!(p.step(Input::Stop, now).is_empty());
    let grace = now + Duration::from_secs(10);
    assert_eq!(
        p.step(Input::Spawned { pid: 4 }, now),
        [Action::Terminate { pid: 4 }, Action::WakeAt(grace)]
    );
    p.step(Input::Exited { pid: 4, code: None }, now);
    assert_eq!(p.health().state, RoleState::Stopped);

    up(&mut p, 5, now);
    p.step(Input::Exited { pid: 5, code: Some(1) }, now);
    assert_eq!(p.health().state, RoleState::Backoff);
    assert!(p.step(Input::Stop, now).is_empty());
    assert_eq!(p.health().state, RoleState::Stopped);
    assert!(p.step(Input::Due, now + BACKOFF_CAP).is_empty(), "a stale wake does nothing");

    assert_eq!(p.step(Input::Start, now), [Action::Spawn]);
    assert!(p.step(Input::Stop, now).is_empty());
    let spawn_failed = Input::SpawnFailed { error: "no such file".to_owned() };
    assert!(p.step(spawn_failed, now).is_empty());
    assert_eq!(p.health().state, RoleState::Stopped);
}

#[test]
fn start_while_stopping_restarts_after_exit() {
    let now = Instant::now();
    let mut p = role(RestartPolicy::Always, Readiness::Started);
    up(&mut p, 3, now);
    p.step(Input::Stop, now);
    assert!(p.step(Input::Start, now).is_empty());
    assert_eq!(p.step(Input::Exited { pid: 3, code: None }, now), [Action::Spawn]);
    assert_eq!(p.health().state, RoleState::Starting);
}

#[test]
fn spawn_failure_counts_as_a_failure_and_stale_exits_are_ignored() {
    let now = Instant::now();
    let mut p = role(RestartPolicy::Always, Readiness::Started);
    p.step(Input::Start, now);
    let actions = p.step(Input::SpawnFailed { error: "permission denied".to_owned() }, now);
    assert_eq!(actions, [Action::WakeAt(now + BACKOFF_FIRST)]);
    assert_eq!(p.health().last_error.as_deref(), Some("permission denied"));
    assert!(p.step(Input::Exited { pid: 99, code: Some(1) }, now).is_empty());
    assert_eq!(p.health().state, RoleState::Backoff);
}

#[test]
fn health_serializes_kebab_case() {
    let h = RoleHealth::invalid("chief", "`program` is required");
    let json = serde_json::to_value(&h).unwrap();
    assert_eq!(json["state"], "invalid");
    let mut p = role(RestartPolicy::Always, Readiness::Started);
    for _ in 0..CRASH_LOOP_FAILURES {
        p.step(Input::Start, Instant::now());
        p.step(Input::SpawnFailed { error: "x".to_owned() }, Instant::now());
        p.step(Input::Due, Instant::now() + BACKOFF_CAP);
    }
    assert_eq!(serde_json::to_value(p.health()).unwrap()["state"], "crash-loop");
}
