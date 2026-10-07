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

fn parked_builder() -> Machine {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: false });
    run(&mut m, obs(Some("b"), None, None), &ob(Some("b"), None, Some("b")));
    run(&mut m, obs(Some("b"), Some("b"), Some("b")), &ob(Some("b"), Some("b"), Some("b")));
    m.step(Input::DaemonExited { lived_ms: 60_000 });
    m.step(Input::AnnounceDone);
    assert!(m.is_parked());
    assert_eq!(m.daemon(), &DaemonState::Down);
    m
}

#[test]
fn clone_of_parked_snapshot_binds_in_order() {
    let mut m = parked_builder();
    let group = m.step(obs(Some("c1"), Some("b"), None));
    assert_eq!(
        names(&group),
        ["reseed", "mark-clone-started", "drop-remote-identity", "write-bound", "commit-bind"]
    );
    assert!(m.is_parked(), "nothing changes before the commit");
    let rest = m.step(Input::BindCommitted("c1".to_owned()));
    assert_eq!(
        names(&rest),
        [
            "spawn-daemon",
            "announce",
            "rekey",
            "restart-prompt-sync",
            "arm-rearm",
            "start-roles",
            "notify"
        ]
    );
    assert!(!m.is_parked());
    // The same id again (any number of wakes) never rebinds.
    let again = m.step(obs(Some("c1"), Some("b"), Some("c1")));
    assert!(again.is_empty(), "{again:?}");
}

/// Review P1: a failed reseed, drop or write discards the rest of the
/// bind; nothing spawns and a bounded retry is armed.
#[test]
fn failed_identity_group_never_spawns_and_retries() {
    let mut m = parked_builder();
    m.step(obs(Some("c1"), Some("b"), None));
    let failed = m.step(Input::BindFailed("c1".to_owned()));
    assert_eq!(failed, [Action::ArmRetry(RETRY_FIRST_MS)]);
    assert_eq!(m.daemon(), &DaemonState::Down);
    assert!(m.step(Input::BindCommitted("c1".to_owned())).is_empty(), "stale commit");
    m.step(Input::RetryElapsed);
    let again = m.step(obs(Some("c1"), Some("b"), None));
    assert_eq!(again[0], Action::Reseed("c1".to_owned()));
}

#[test]
fn fork_of_running_machine_stops_old_host_before_identity_work() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: true });
    let first = m.step(obs(Some("parent"), None, Some("parent")));
    assert_eq!(names(&first), ["start-roles", "arm-announce", "ready"]);
    let actions = m.step(obs(Some("child"), None, Some("parent")));
    assert_eq!(names(&actions), ["stop-roles", "terminate-daemon"]);
    // A wake during the stop is deferred, not a second bind.
    assert!(m.step(obs(Some("child"), None, Some("parent"))).is_empty());
    assert_eq!(names(&m.step(Input::StopDeadline)), ["kill-daemon"]);
    let rest = m.step(Input::DaemonExited { lived_ms: 1 });
    assert_eq!(
        names(&rest),
        [
            "disarm-stop-deadline",
            "reseed",
            "mark-clone-started",
            "drop-remote-identity",
            "write-bound",
            "commit-bind"
        ]
    );
}

#[test]
fn bake_id_parks_and_stops_terminal_hosts_after_the_host_exits() {
    let mut m = Machine::new();
    let world = ob(Some("b"), None, Some("b"));
    run(&mut m, obs(Some("b"), None, Some("b")), &world);
    assert_eq!(names(&m.step(obs(Some("b"), Some("b"), Some("b")))), ["park-roles"]);
    let park = m.step(Input::RolesParked { ok: true });
    assert_eq!(
        names(&park),
        [
            "park-housekeeping",
            "disarm-rearm",
            "disarm-announce",
            "remove-driver-file",
            "terminate-daemon"
        ]
    );
    let exited = m.step(Input::DaemonExited { lived_ms: 1 });
    assert_eq!(names(&exited), ["disarm-stop-deadline", "stop-terminal-hosts"]);
    for input in [
        obs(Some("b"), Some("b"), None),
        obs(None, Some("b"), None),
        Input::ResumeSignal,
        Input::BackoffElapsed,
        Input::RearmElapsed,
        Input::AnnounceTick,
        Input::AnnounceDone,
    ] {
        let actions = m.step(input);
        assert!(!actions.contains(&Action::SpawnDaemon), "{actions:?}");
        assert!(!actions.contains(&Action::Announce), "{actions:?}");
    }
}

#[test]
fn container_without_metadata_runs_unbound() {
    let mut m = Machine::new();
    let actions = m.step(obs(None, None, None));
    assert_eq!(names(&actions), ["spawn-daemon", "start-roles", "ready"]);
    let actions = m.step(obs(Some(""), None, None));
    assert!(actions.is_empty(), "{actions:?}");
}

/// Review P2-2 and P2-3: on a metadata machine a failed read never spawns
/// and arms a bounded retry (50 ms doubling, at most RETRY_ATTEMPTS).
#[test]
fn failed_read_on_metadata_machine_retries_bounded_and_never_spawns() {
    let mut m = parked_builder();
    let mut delays = Vec::new();
    for _ in 0..20 {
        let actions = m.step(obs(None, Some("b"), None));
        assert!(!actions.contains(&Action::SpawnDaemon));
        for action in actions {
            if let Action::ArmRetry(ms) = action {
                delays.push(ms);
            }
        }
        m.step(Input::RetryElapsed);
    }
    assert_eq!(delays.len(), RETRY_ATTEMPTS as usize);
    assert_eq!(delays[0], RETRY_FIRST_MS);
    assert_eq!(delays[1], 2 * RETRY_FIRST_MS);
    // An unparked machine whose host died also never spawns on None.
    let mut m = Machine::new();
    run(&mut m, obs(Some("x"), None, None), &ob(Some("x"), None, Some("x")));
    assert_eq!(m.step(Input::DaemonExited { lived_ms: 60_000 }), [Action::Recheck]);
    let none = m.step(obs(None, None, Some("x")));
    assert!(!none.contains(&Action::SpawnDaemon), "{none:?}");
}

#[test]
fn adopted_daemon_is_not_respawned() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: true });
    let actions = m.step(obs(Some("x"), None, Some("x")));
    assert!(!actions.contains(&Action::SpawnDaemon));
}

/// Review P2-2: restarts go through a fresh observation, so a backoff from
/// before a snapshot binds the clone instead of spawning the old identity.
#[test]
fn restarts_go_through_a_fresh_observation() {
    let mut m = Machine::new();
    let world = ob(Some("x"), None, Some("x"));
    run(&mut m, obs(Some("x"), None, None), &world);
    assert_eq!(m.step(Input::DaemonExited { lived_ms: 5 }), [Action::Recheck]);
    run(&mut m, Input::Observed(world.clone()), &world);
    assert_eq!(m.step(Input::DaemonExited { lived_ms: 5 }), [Action::ArmBackoff(500)]);
    assert!(m.step(Input::DaemonExited { lived_ms: 5 }).is_empty(), "no host in backoff");
    assert_eq!(m.step(Input::BackoffElapsed), [Action::Recheck]);
    // The machine was cloned while the timer ran.
    let clone = run(&mut m, Input::BackoffElapsed, &world);
    assert!(clone.is_empty());
    let after = m.step(obs(Some("y"), None, Some("x")));
    assert_eq!(names(&after)[..2], ["stop-roles", "reseed"], "{after:?}");
    assert_eq!(after[1], Action::Reseed("y".to_owned()));
}

#[test]
fn healthy_run_resets_the_backoff() {
    let mut m = Machine::new();
    let world = ob(None, None, None);
    run(&mut m, obs(None, None, None), &world);
    run(&mut m, Input::DaemonExited { lived_ms: 5 }, &world);
    assert_eq!(m.step(Input::DaemonExited { lived_ms: 5 }), [Action::ArmBackoff(500)]);
    run(&mut m, Input::BackoffElapsed, &world);
    let healthy = run(&mut m, Input::DaemonExited { lived_ms: HEALTHY_RUN_MS }, &world);
    assert_eq!(names(&healthy), ["recheck", "spawn-daemon"]);
    assert_eq!(m.fast_exits(), 1);
}

#[test]
fn resume_announces_once_until_done() {
    let mut m = Machine::new();
    run(&mut m, obs(Some("x"), None, None), &ob(Some("x"), None, Some("x")));
    assert_eq!(names(&m.step(Input::AnnounceDone)), ["arm-announce"]);
    assert_eq!(names(&m.step(Input::ResumeSignal)), ["notify", "announce"]);
    assert_eq!(names(&m.step(Input::ResumeSignal)), ["notify"]);
    m.step(Input::AnnounceDone);
    assert_eq!(names(&m.step(Input::ResumeSignal)), ["notify", "announce"]);
}

/// Review P2-6: the periodic announce re-arms after each announce and
/// stops while parked.
#[test]
fn periodic_announce_rearms_and_stops_while_parked() {
    let mut m = Machine::new();
    run(&mut m, obs(Some("x"), None, Some("x")), &ob(Some("x"), None, Some("x")));
    assert_eq!(names(&m.step(Input::AnnounceTick)), ["announce"]);
    assert_eq!(names(&m.step(Input::AnnounceDone)), ["arm-announce"]);
    let park = run(&mut m, obs(Some("x"), Some("x"), Some("x")), &ob(Some("x"), Some("x"), None));
    assert!(park.contains(&Action::DisarmAnnounce));
    assert!(m.step(Input::AnnounceTick).is_empty());
}

#[test]
fn address_changes_are_not_resumes() {
    let mut m = Machine::new();
    assert!(m.step(Input::AddressesChanged).is_empty());
    run(&mut m, obs(Some("x"), None, Some("x")), &ob(Some("x"), None, Some("x")));
    assert_eq!(m.step(Input::AddressesChanged), [Action::Notify(Lifecycle::AddressesChanged)]);
    assert_eq!(m.step(Input::ConfigChanged), [Action::Notify(Lifecycle::ConfigChanged)]);
    assert_eq!(m.step(Input::ChannelChanged), [Action::Notify(Lifecycle::ChannelChanged)]);
}

#[test]
fn shutdown_leaves_the_daemon_running() {
    let mut m = Machine::new();
    run(&mut m, obs(Some("x"), None, Some("x")), &ob(Some("x"), None, Some("x")));
    let actions = m.step(Input::Shutdown);
    assert_eq!(names(&actions), ["shutdown-roles", "exit"]);
    assert!(m.step(obs(Some("y"), None, Some("x"))).is_empty());
}

#[test]
fn removed_bake_file_unparks_and_rearms() {
    let mut m = parked_builder();
    let actions = m.step(obs(Some("b"), None, Some("b")));
    assert_eq!(names(&actions), ["arm-rearm", "spawn-daemon", "start-roles", "arm-announce"]);
    assert!(!m.is_parked());
}

#[test]
fn bake_during_a_bind_stop_parks_without_spawning() {
    let mut m = Machine::new();
    run(&mut m, obs(Some("p"), None, Some("p")), &ob(Some("p"), None, Some("p")));
    m.step(obs(Some("x"), None, Some("p")));
    assert!(m.step(obs(Some("x"), Some("x"), Some("p"))).is_empty(), "deferred");
    let world = ob(Some("x"), Some("x"), Some("p"));
    let actions = run(&mut m, Input::DaemonExited { lived_ms: 1 }, &world);
    assert!(!actions.contains(&Action::SpawnDaemon), "{actions:?}");
    assert!(!actions.iter().any(|a| matches!(a, Action::WriteBound(_))), "{actions:?}");
    assert!(m.is_parked());
}

#[test]
fn a_role_refusing_the_park_keeps_the_machine_running() {
    let mut m = Machine::new();
    run(&mut m, obs(Some("b"), None, Some("b")), &ob(Some("b"), None, Some("b")));
    assert_eq!(names(&m.step(obs(Some("b"), Some("b"), Some("b")))), ["park-roles"]);
    let refused = m.step(Input::RolesParked { ok: false });
    assert_eq!(names(&refused), ["start-roles"]);
    assert!(!m.is_parked());
    assert_eq!(m.daemon(), &DaemonState::Running);
    assert_eq!(names(&m.step(obs(Some("b"), Some("b"), Some("b")))), ["park-roles"]);
}

/// Re-review P2-a: after the retry budget is spent, an address change
/// gives a fresh one (the agent reads the metadata again after it).
#[test]
fn address_change_restores_the_retry_budget() {
    let mut m = Machine::new();
    run(&mut m, obs(Some("x"), None, Some("x")), &ob(Some("x"), None, Some("x")));
    assert_eq!(m.step(Input::DaemonExited { lived_ms: 60_000 }), [Action::Recheck]);
    for _ in 0..RETRY_ATTEMPTS {
        m.step(obs(None, None, Some("x")));
        m.step(Input::RetryElapsed);
    }
    assert!(m.step(obs(None, None, Some("x"))).is_empty(), "budget spent");
    assert!(names(&m.step(Input::AddressesChanged)).iter().all(|n| *n == "notify"));
    assert_eq!(m.step(obs(None, None, Some("x"))), [Action::ArmRetry(RETRY_FIRST_MS)]);
    let back = m.step(obs(Some("x"), None, Some("x")));
    assert!(back.contains(&Action::SpawnDaemon), "{back:?}");
}

/// Re-review P3: a bound machine after an agent restart starts the
/// periodic announce once, not on every observation.
#[test]
fn agent_restart_on_bound_machine_starts_the_announce_loop_once() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: true });
    let first = m.step(obs(Some("x"), None, Some("x")));
    assert!(first.contains(&Action::ArmAnnounce));
    let second = m.step(obs(Some("x"), None, Some("x")));
    assert!(!second.contains(&Action::ArmAnnounce), "{second:?}");
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
