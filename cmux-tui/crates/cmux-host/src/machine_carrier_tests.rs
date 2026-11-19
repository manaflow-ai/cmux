//! A changed relay carrier route, or an adopted host of an older build,
//! restarts the session host (`carrier.json`, `ReplaceWhy`).

use super::*;

fn bound(id: &str) -> Observation {
    Observation {
        instance_id: Some(id.into()),
        bake_id: None,
        bound_id: Some(id.into()),
        clone_signal: false,
    }
}

fn running() -> Machine {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: false });
    let out = m.step(Input::Observed(bound("a")));
    assert!(out.contains(&Action::SpawnDaemon), "{out:?}");
    m
}

#[test]
fn a_changed_route_stops_the_host_and_starts_it_through_a_fresh_read() {
    let mut m = running();
    assert_eq!(m.step(Input::CarrierChanged), [Action::TerminateDaemon]);
    assert_eq!(m.daemon(), &DaemonState::Stopping(StopReason::Respawn));
    // A second change while it stops changes nothing.
    assert_eq!(m.step(Input::CarrierChanged), []);
    let out = m.step(Input::DaemonExited { lived_ms: 60_000 });
    assert_eq!(out, [Action::DisarmStopDeadline, Action::Recheck]);
    assert!(!out.contains(&Action::StopTerminalHosts));
    let out = m.step(Input::Observed(bound("a")));
    assert_eq!(out, [Action::SpawnDaemon]);
    assert_eq!(m.daemon(), &DaemonState::Running);
    assert_eq!(m.fast_exits(), 0, "a respawn is no crash");
}

#[test]
fn an_observation_during_the_stop_decides_the_restart() {
    let mut m = running();
    m.step(Input::CarrierChanged);
    assert_eq!(m.step(Input::Observed(bound("a"))), []);
    let out = m.step(Input::DaemonExited { lived_ms: 60_000 });
    assert_eq!(out, [Action::DisarmStopDeadline, Action::SpawnDaemon]);
    // A new id seen during the stop binds instead (the bind spawns).
    let mut m = running();
    m.step(Input::CarrierChanged);
    m.step(Input::Observed(Observation { bound_id: Some("a".into()), ..bound("b") }));
    let out = m.step(Input::DaemonExited { lived_ms: 60_000 });
    assert!(out.contains(&Action::WriteBound("b".into())), "{out:?}");
    assert!(!out.contains(&Action::SpawnDaemon), "{out:?}");
}

#[test]
fn no_host_running_or_a_parked_machine_ignores_a_route_change() {
    let mut down = Machine::new();
    assert_eq!(down.step(Input::CarrierChanged), []);
    let mut parked = running();
    parked.step(Input::Observed(Observation { bake_id: Some("a".into()), ..bound("a") }));
    parked.step(Input::RolesParked { ok: true });
    parked.step(Input::DaemonExited { lived_ms: 60_000 });
    assert!(parked.is_parked());
    assert_eq!(parked.step(Input::CarrierChanged), []);
    let mut stopping = running();
    stopping.step(Input::Observed(Observation { bound_id: Some("a".into()), ..bound("b") }));
    assert_eq!(stopping.daemon(), &DaemonState::Stopping(StopReason::Bind("b".into())));
    assert_eq!(stopping.step(Input::CarrierChanged), []);
}

/// An old-build host with `n` attached sessions whose least input idle time
/// is `idle_ms`, `since_ms` after the build changed.
fn look(n: Option<usize>, idle_ms: Option<u64>, since_ms: u64) -> HostLook {
    HostLook { attached: n, input_idle_ms: idle_ms, since_changed_ms: since_ms }
}

/// The adopted old-build host with one session attached, deferred.
fn deferred() -> Machine {
    let mut m = running();
    assert_eq!(m.step(Input::BuildChanged), [Action::LookHost]);
    let out = m.step(Input::HostLooked(look(Some(1), Some(1_000), 0)));
    assert_eq!(out, [Action::MarkHostDeferred, Action::ArmHostLook(HOST_LOOK_MS)]);
    m
}

fn replaced(why: ReplaceWhy) -> [Action; 2] {
    [Action::ReplaceOldHost(why), Action::TerminateDaemon]
}

#[test]
fn each_of_the_three_caps_replaces_a_busy_old_host_and_names_itself() {
    // The last detach.
    let mut m = deferred();
    assert_eq!(m.step(Input::HostLookElapsed), [Action::LookHost]);
    assert_eq!(
        m.step(Input::HostLooked(look(Some(0), None, 60_000))),
        replaced(ReplaceWhy::Detached)
    );
    assert_eq!(m.daemon(), &DaemonState::Stopping(StopReason::Respawn));
    // 10 min with no input on the attached sessions (just short of it keeps it).
    let mut m = deferred();
    let short = look(Some(2), Some(HOST_INPUT_IDLE_MS - 1), 60_000);
    assert_eq!(m.step(Input::HostLooked(short)), [Action::ArmHostLook(HOST_LOOK_MS)]);
    let idle = look(Some(2), Some(HOST_INPUT_IDLE_MS), 60_000);
    assert_eq!(m.step(Input::HostLooked(idle)), replaced(ReplaceWhy::InputIdle));
    // 24 h after the build changed, sessions busy or unknown.
    let mut m = deferred();
    let day = look(Some(1), Some(1_000), HOST_MAX_DEFER_MS);
    assert_eq!(m.step(Input::HostLooked(day)), replaced(ReplaceWhy::MaxDefer));
    let mut m = deferred();
    let unknown_day = look(None, None, HOST_MAX_DEFER_MS);
    assert_eq!(m.step(Input::HostLooked(unknown_day)), replaced(ReplaceWhy::MaxDefer));
    // The first to fire wins: a detach beats the day cap.
    let mut m = deferred();
    let both = look(Some(0), None, HOST_MAX_DEFER_MS);
    assert_eq!(m.step(Input::HostLooked(both)), replaced(ReplaceWhy::Detached));
}

#[test]
fn an_unreadable_list_or_a_host_without_the_idle_field_keeps_the_old_host() {
    let mut m = deferred();
    assert_eq!(
        m.step(Input::HostLooked(look(None, None, 60_000))),
        [Action::ArmHostLook(HOST_LOOK_MS)]
    );
    // An older session host reports no input idle time: only the detach or the day cap.
    let out = m.step(Input::HostLooked(look(Some(1), None, HOST_MAX_DEFER_MS - 1)));
    assert_eq!(out, [Action::ArmHostLook(HOST_LOOK_MS)]);
    assert_eq!(m.daemon(), &DaemonState::Running);
}

#[test]
fn an_old_host_that_ends_another_way_is_not_replaced_again() {
    let mut m = deferred();
    // It crashed: the restart runs the installed build, and the look timer
    // that fires later does nothing.
    m.step(Input::DaemonExited { lived_ms: 60_000 });
    m.step(Input::Observed(bound("a")));
    assert_eq!(m.daemon(), &DaemonState::Running);
    assert_eq!(m.step(Input::HostLookElapsed), []);
    assert_eq!(m.step(Input::HostLooked(look(Some(0), None, 0))), []);
    // A route change during the deferral replaces it through its own path.
    let mut m = deferred();
    assert_eq!(m.step(Input::CarrierChanged), [Action::TerminateDaemon]);
    assert_eq!(m.step(Input::HostLookElapsed), []);
}

#[test]
fn a_build_change_on_a_parked_or_hostless_machine_does_nothing() {
    assert_eq!(Machine::new().step(Input::BuildChanged), []);
    let mut parked = running();
    parked.step(Input::Observed(Observation { bake_id: Some("a".into()), ..bound("a") }));
    parked.step(Input::RolesParked { ok: true });
    parked.step(Input::DaemonExited { lived_ms: 60_000 });
    assert_eq!(parked.step(Input::BuildChanged), []);
}

/// Past the restart budget a crash holds an hour instead of restarting at once (the agent
/// counted it on the supervisor contract); back within it, the usual backoff returns.
#[test]
fn a_crash_past_the_restart_budget_holds_an_hour_and_within_it_restarts_at_once() {
    let mut m = running();
    m.step(Input::RestartBudget { exceeded: true });
    let out = m.step(Input::DaemonExited { lived_ms: 60_000 });
    assert_eq!(out, [Action::ArmBackoff(BUDGET_HOLD_RETRY_MS)]);
    assert_eq!(m.daemon(), &DaemonState::Backoff);

    let mut m = running();
    m.step(Input::RestartBudget { exceeded: false });
    let out = m.step(Input::DaemonExited { lived_ms: 60_000 });
    assert_eq!(out, [Action::Recheck], "a first crash within the budget restarts at once");
}
