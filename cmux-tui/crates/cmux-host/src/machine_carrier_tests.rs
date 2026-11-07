//! A changed relay carrier route restarts the session host (`carrier.json`).

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
