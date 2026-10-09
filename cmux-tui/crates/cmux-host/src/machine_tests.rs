use super::*;

fn ob(id: Option<&str>, bake: Option<&str>, bound: Option<&str>) -> Observation {
    Observation {
        instance_id: id.map(str::to_owned),
        bake_id: bake.map(str::to_owned),
        bound_id: bound.map(str::to_owned),
        clone_signal: false,
    }
}

fn obs(id: Option<&str>, bake: Option<&str>, bound: Option<&str>) -> Input {
    Input::Observed(ob(id, bake, bound))
}

fn names(actions: &[Action]) -> Vec<&'static str> {
    actions.iter().map(Action::name).collect()
}

/// Steps like the agent: answers CommitBind (success), ParkRoles (ok) and
/// Recheck (with `world`), and returns every action in order.
fn run(m: &mut Machine, input: Input, world: &Observation) -> Vec<Action> {
    let mut all = Vec::new();
    let mut queue = vec![input];
    while let Some(input) = queue.pop() {
        let actions = m.step(input);
        for action in &actions {
            match action {
                Action::CommitBind(id) => queue.push(Input::BindCommitted(id.clone())),
                Action::ParkRoles => queue.push(Input::RolesParked { ok: true }),
                Action::Recheck => queue.push(Input::Observed(world.clone())),
                _ => {}
            }
        }
        all.extend(actions);
    }
    all
}

/// Security review P2-2: roles are stopped before the identity changes,
/// hear nothing (no Resumed, no announce) while it changes, stay stopped
/// after a failed bind, and start again with the new id at the commit.
#[test]
fn roles_stay_stopped_through_a_rebind_and_after_a_failed_bind() {
    let mut m = Machine::new();
    run(&mut m, obs(Some("p"), None, Some("p")), &ob(Some("p"), None, Some("p")));
    let fork = m.step(obs(Some("x"), None, Some("p")));
    assert_eq!(names(&fork), ["stop-roles", "terminate-daemon"]);
    assert!(m.step(Input::ResumeSignal).is_empty(), "no Resumed or announce during the stop");
    assert!(m.step(Input::AnnounceTick).is_empty(), "no announce during the stop");
    let group = m.step(Input::DaemonExited { lived_ms: 1 });
    assert!(names(&group).contains(&"commit-bind"), "{group:?}");
    assert!(m.step(Input::ResumeSignal).is_empty(), "nor while the identity group is out");
    assert_eq!(names(&m.step(Input::BindFailed("x".to_owned()))), ["arm-retry"]);
    assert_eq!(m.daemon(), &DaemonState::Down);
    for input in [
        Input::ResumeSignal,
        Input::AnnounceTick,
        Input::AddressesChanged,
        Input::ConfigChanged,
        Input::ChannelChanged,
    ] {
        let actions = m.step(input);
        let leaked = actions.iter().any(|a| matches!(a, Action::Notify(_) | Action::Announce));
        assert!(!leaked, "roles keep the old identity after a failed bind: {actions:?}");
    }
    // The retry binds: roles start with the new id, then hear Bound.
    m.step(Input::RetryElapsed);
    let rest = run(&mut m, obs(Some("x"), None, Some("p")), &ob(Some("x"), None, Some("x")));
    let start = names(&rest).iter().position(|a| *a == "start-roles").expect("roles start");
    assert_eq!(rest[start], Action::StartRoles(Some("x".to_owned())));
    assert_eq!(rest[start + 1], Action::Notify(Lifecycle::Bound("x".to_owned())));
}

/// Security review P2-1: a failed read after a clone signal arms the
/// bounded retry while the session host runs, keeps retrying until a read
/// gives an id, and holds `Resumed` until the id is confirmed.
#[test]
fn failed_read_after_a_clone_signal_retries_while_running() {
    let mut m = Machine::new();
    run(&mut m, obs(Some("p"), None, Some("p")), &ob(Some("p"), None, Some("p")));
    let routine = m.step(obs(None, None, Some("p")));
    assert!(routine.is_empty(), "a routine failed read leaves a running host alone: {routine:?}");
    let signal = Observation { clone_signal: true, ..ob(None, None, Some("p")) };
    assert_eq!(m.step(Input::Observed(signal)), [Action::ArmRetry(RETRY_FIRST_MS)]);
    assert!(m.step(Input::ResumeSignal).is_empty(), "Resumed waits for the id");
    m.step(Input::AnnounceDone);
    let tick = m.step(Input::AnnounceTick);
    assert!(!tick.contains(&Action::Announce), "no announce before the id is confirmed: {tick:?}");
    m.step(Input::RetryElapsed);
    assert_eq!(m.step(obs(None, None, Some("p"))), [Action::ArmRetry(2 * RETRY_FIRST_MS)]);
    m.step(Input::RetryElapsed);
    let same = m.step(obs(Some("p"), None, Some("p")));
    // The skipped tick's loop is armed again once the id is confirmed.
    assert_eq!(same, [Action::ArmAnnounce, Action::Notify(Lifecycle::Resumed), Action::Announce]);
    assert!(m.step(obs(None, None, Some("p"))).is_empty(), "confirmed: no more retries");
    // A changed id after the signal binds instead of resuming.
    let signal = Observation { clone_signal: true, ..ob(None, None, Some("p")) };
    m.step(Input::Observed(signal));
    m.step(Input::ResumeSignal);
    m.step(Input::RetryElapsed);
    let fork = m.step(obs(Some("q"), None, Some("p")));
    assert_eq!(names(&fork), ["stop-roles", "terminate-daemon"]);
}
