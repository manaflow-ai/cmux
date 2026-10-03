use super::*;

fn obs(id: Option<&str>, bake: Option<&str>, bound: Option<&str>) -> Input {
    Input::Observed(Observation {
        instance_id: id.map(str::to_owned),
        bake_id: bake.map(str::to_owned),
        bound_id: bound.map(str::to_owned),
    })
}

fn names(actions: &[Action]) -> Vec<&'static str> {
    actions.iter().map(Action::name).collect()
}

fn parked_builder() -> Machine {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: false });
    m.step(obs(Some("b"), None, None));
    m.step(Input::DaemonExited { lived_ms: 0 }); // nothing: Running -> immediate respawn
    m.step(obs(Some("b"), Some("b"), Some("b")));
    m.step(Input::DaemonExited { lived_ms: 60_000 });
    m.step(Input::AnnounceDone);
    assert!(m.is_parked());
    assert_eq!(m.daemon(), &DaemonState::Down);
    m
}

#[test]
fn clone_of_parked_snapshot_binds_in_order() {
    let mut m = parked_builder();
    let actions = m.step(obs(Some("c1"), Some("b"), None));
    assert_eq!(
        names(&actions),
        [
            "reseed",
            "mark-clone-started",
            "drop-remote-identity",
            "write-bound",
            "spawn-daemon",
            "announce",
            "rekey",
            "restart-prompt-sync",
            "arm-rearm",
            "start-roles",
            "notify",
        ]
    );
    assert_eq!(actions[0], Action::Reseed("c1".to_owned()));
    assert!(!m.is_parked());
    // The same id again (any number of wakes) never rebinds.
    let again = m.step(obs(Some("c1"), Some("b"), Some("c1")));
    assert!(again.is_empty(), "{again:?}");
}

#[test]
fn fork_of_running_machine_stops_old_host_before_dropping_identity() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: true });
    let first = m.step(obs(Some("parent"), None, Some("parent")));
    assert_eq!(names(&first), ["start-roles", "ready"]);
    let actions = m.step(obs(Some("child"), None, Some("parent")));
    assert_eq!(names(&actions), ["reseed", "mark-clone-started", "terminate-daemon"]);
    // A wake during the stop is deferred, not a second bind.
    assert!(m.step(obs(Some("child"), None, Some("parent"))).is_empty());
    assert_eq!(names(&m.step(Input::StopDeadline)), ["kill-daemon"]);
    let rest = m.step(Input::DaemonExited { lived_ms: 1 });
    let rest_names = names(&rest);
    assert_eq!(&rest_names[..5], ["disarm-stop-deadline", "drop-remote-identity", "write-bound", "spawn-daemon", "announce"]);
    // The deferred observation read bound=parent before the bind wrote
    // the file; it must not start a second bind.
    assert!(!rest.iter().any(|a| matches!(a, Action::Reseed(_))), "{rest:?}");
}

#[test]
fn bake_id_parks_and_stops_terminal_hosts_after_the_host_exits() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: false });
    m.step(obs(Some("b"), None, Some("b")));
    let park = m.step(obs(Some("b"), Some("b"), Some("b")));
    assert_eq!(
        names(&park),
        ["notify", "stop-roles", "park-housekeeping", "disarm-rearm", "remove-driver-file", "terminate-daemon"]
    );
    let exited = m.step(Input::DaemonExited { lived_ms: 1 });
    assert_eq!(names(&exited), ["disarm-stop-deadline", "stop-terminal-hosts"]);
    // Parked: wakes, exits, backoff and resume never spawn.
    for input in [
        obs(Some("b"), Some("b"), None),
        obs(None, Some("b"), None),
        Input::ResumeSignal,
        Input::BackoffElapsed,
        Input::RearmElapsed,
    ] {
        let actions = m.step(input);
        assert!(!actions.contains(&Action::SpawnDaemon), "{actions:?}");
    }
}

#[test]
fn empty_metadata_never_binds_and_runs_unbound_daemon() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: false });
    let actions = m.step(obs(None, None, None));
    assert_eq!(names(&actions), ["spawn-daemon", "start-roles", "ready"]);
    let actions = m.step(obs(Some(""), None, None));
    assert!(actions.is_empty(), "{actions:?}");
}

#[test]
fn adopted_daemon_is_not_respawned() {
    let mut m = Machine::new();
    m.step(Input::Boot { adopted_daemon: true });
    let actions = m.step(obs(Some("x"), None, Some("x")));
    assert!(!actions.contains(&Action::SpawnDaemon));
}

#[test]
fn crash_loop_backs_off_and_healthy_run_resets() {
    let mut m = Machine::new();
    m.step(obs(None, None, None));
    assert_eq!(m.step(Input::DaemonExited { lived_ms: 5 }), [Action::SpawnDaemon]);
    assert_eq!(m.step(Input::DaemonExited { lived_ms: 5 }), [Action::ArmBackoff(500)]);
    assert!(m.step(Input::DaemonExited { lived_ms: 5 }).is_empty(), "no host is running in backoff");
    assert_eq!(m.step(Input::BackoffElapsed), [Action::SpawnDaemon]);
    assert_eq!(m.step(Input::DaemonExited { lived_ms: 5 }), [Action::ArmBackoff(1_000)]);
    m.step(Input::BackoffElapsed);
    assert_eq!(m.step(Input::DaemonExited { lived_ms: HEALTHY_RUN_MS }), [Action::SpawnDaemon]);
    assert_eq!(m.fast_exits(), 1);
}

#[test]
fn resume_announces_once_until_done() {
    let mut m = Machine::new();
    m.step(obs(Some("x"), None, None));
    m.step(Input::AnnounceDone);
    assert_eq!(names(&m.step(Input::ResumeSignal)), ["notify", "announce"]);
    assert_eq!(names(&m.step(Input::ResumeSignal)), ["notify"]);
    m.step(Input::AnnounceDone);
    assert_eq!(names(&m.step(Input::ResumeSignal)), ["notify", "announce"]);
}

#[test]
fn shutdown_leaves_the_daemon_running() {
    let mut m = Machine::new();
    m.step(obs(Some("x"), None, Some("x")));
    let actions = m.step(Input::Shutdown);
    assert_eq!(names(&actions), ["notify", "stop-roles", "exit"]);
    assert!(!actions.contains(&Action::TerminateDaemon));
    assert!(m.step(obs(Some("y"), None, Some("x"))).is_empty());
}

#[test]
fn removed_bake_file_unparks_and_rearms() {
    let mut m = parked_builder();
    let actions = m.step(obs(Some("b"), None, Some("b")));
    assert_eq!(names(&actions), ["arm-rearm", "spawn-daemon", "start-roles"]);
    assert!(!m.is_parked());
}
