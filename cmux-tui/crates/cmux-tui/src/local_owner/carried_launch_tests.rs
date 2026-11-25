use super::*;

fn argv(args: &[&str]) -> Vec<String> {
    args.iter().map(|arg| (*arg).to_owned()).collect()
}

#[test]
fn the_vm_daemons_flags_are_carried() {
    let launch = CarriedLaunch::from_launch(
        &argv(&[
            "/proc/self/exe",
            "--headless",
            "--session",
            "main",
            "--socket",
            "/run/user/1001/cmux-tui-1001/main.sock",
            "--term",
            "xterm-ghostty",
            "--owner-host-fg",
            "#fdfff1",
            "--owner-host-bg",
            "#272822",
        ]),
        Vec::new(),
    );
    assert_eq!(
        launch.flags(),
        ["--term", "xterm-ghostty", "--owner-host-fg", "#fdfff1", "--owner-host-bg", "#272822"]
    );
    assert!(launch.state.is_none() && launch.websocket.is_none());
}

#[test]
fn state_grace_listener_and_env_are_carried_and_the_rest_is_not() {
    let launch = CarriedLaunch::from_launch(
        &argv(&[
            "cmux-tui",
            "--headless",
            "--state",
            "/tmp/state",
            "--terminal-reap-grace-seconds",
            "30",
            "--ws",
            "127.0.0.1:0",
            "--ws-allow-origin",
            "cmux-page://cmux.home",
            "--owner-ready-fd",
            "8",
        ]),
        vec![("CMUX_APPS_DIRS".into(), "/apps".into())],
    );
    assert_eq!(launch.state, Some(PathBuf::from("/tmp/state")));
    assert_eq!(launch.terminal_reap_grace, Some(Duration::from_secs(30)));
    assert_eq!(
        launch.websocket,
        Some(EnsureWebSocket { allow_origins: vec!["cmux-page://cmux.home".into()] })
    );
    assert_eq!(launch.env, [("CMUX_APPS_DIRS".to_string(), "/apps".to_string())]);
}

#[test]
fn a_process_that_is_no_headless_owner_carries_nothing() {
    let launch = CarriedLaunch::from_launch(
        &argv(&["cmux-tui", "--term", "xterm-ghostty"]),
        vec![("CMUX_APPS_DIRS".into(), "/apps".into())],
    );
    assert_eq!(launch, CarriedLaunch::default());
}

#[test]
fn a_flag_without_its_value_is_left_out_and_the_next_flag_still_counts() {
    // `--state ""` as the OS lists it: the empty value is gone.
    let launch = CarriedLaunch::from_launch(
        &argv(&["cmux-tui", "--headless", "--state", "--term", "xterm-ghostty", "--ws"]),
        Vec::new(),
    );
    assert_eq!(launch.state, None);
    assert_eq!(launch.term.as_deref(), Some("xterm-ghostty"));
    assert_eq!(launch.websocket, None);
}

#[test]
fn the_callers_own_values_win_and_the_rest_is_filled() {
    let launch = CarriedLaunch::from_launch(
        &argv(&[
            "cmux-tui",
            "--headless",
            "--term",
            "xterm-ghostty",
            "--owner-host-bg",
            "#272822",
            "--terminal-reap-grace-seconds",
            "30",
        ]),
        vec![("CMUX_APPS_DIRS".into(), "/apps".into())],
    );
    let mut spec = OwnerSpec {
        session: "main".into(),
        socket: PathBuf::from("/tmp/main.sock"),
        socket_is_derived: false,
        state: None,
        term: Some("xterm-256color".into()),
        initial_host_colors: None,
        terminal_reap_grace: None,
        exit_with_pid: None,
        install_key: None,
        chief_tools_socket: None,
        chief_brains: None,
        websocket: None,
        carried_env: Vec::new(),
    };
    launch.apply(&mut spec);
    assert_eq!(spec.term.as_deref(), Some("xterm-256color"));
    assert_eq!(spec.terminal_reap_grace, Some(Duration::from_secs(30)));
    assert!(spec.initial_host_colors.is_some_and(|colors| colors.bg.is_some()));
    assert_eq!(spec.carried_env, [("CMUX_APPS_DIRS".to_string(), "/apps".to_string())]);
}

#[test]
fn a_bad_color_is_left_out() {
    let launch = CarriedLaunch::from_launch(
        &argv(&["cmux-tui", "--headless", "--owner-host-fg", "red", "--owner-host-bg", "#000000"]),
        Vec::new(),
    );
    assert_eq!(launch.flags(), ["--owner-host-bg", "#000000"]);
}
