use super::*;

fn role(restart: RestartPolicy, ready: Readiness) -> RoleProc {
    RoleProc::new("chief", restart, ready, Duration::from_secs(10))
}

fn up(proc: &mut RoleProc, pid: u32, now: Instant) {
    assert_eq!(proc.step(Input::Start, now), [Action::Spawn]);
    assert!(proc.step(Input::Spawned { pid }, now).is_empty());
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
