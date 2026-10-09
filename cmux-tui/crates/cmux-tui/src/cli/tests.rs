use super::*;

// The app fallback and the app scopes exist on unix only (cli.rs).
#[cfg(unix)]
mod action_surface_parity;
#[cfg(unix)]
mod cli_name_hints;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[test]
fn global_value_options_accept_inline_equals_values() {
    let (global, command) = parse_globals(&strings(&[
        "--socket=/tmp/review.sock",
        "--session=review-session",
        "--machine=builder",
        "workspace",
        "list",
    ]))
    .unwrap();
    assert_eq!(global.socket, Some(PathBuf::from("/tmp/review.sock")));
    assert_eq!(global.session.as_deref(), Some("review-session"));
    assert_eq!(global.machine.as_deref(), Some("builder"));
    assert_eq!(command, strings(&["workspace", "list"]));
}

#[test]
fn global_value_options_reject_empty_inline_values() {
    let error = parse_globals(&strings(&["--socket=", "workspace", "list"])).unwrap_err();
    assert!(error.0.0.contains("--socket needs a value"));
}

#[test]
fn global_value_options_accept_hyphen_prefixed_values() {
    let (global, command) =
        parse_globals(&strings(&["--session", "-1", "--socket", "-tmp/socket"])).unwrap();
    assert_eq!(global.session.as_deref(), Some("-1"));
    assert_eq!(global.socket, Some(PathBuf::from("-tmp/socket")));
    assert!(command.is_empty());
}

#[test]
fn server_lifecycle_routing_flags_follow_action() {
    let ParsedCommand::Command { global, plan: CommandPlan::Server(plan) } =
        parse(&strings(&["server", "status", "--session", "review-session"]), Surface::CmuxTui)
            .unwrap()
    else {
        panic!("server status must produce a server plan");
    };
    assert_eq!(global.session.as_deref(), Some("review-session"));
    assert!(global.socket.is_none());
    assert!(matches!(plan.action, lifecycle::ServerAction::Status));

    let ParsedCommand::Command { global, plan: CommandPlan::Server(plan) } = parse(
        &strings(&["server", "stop", "--socket", "/tmp/review.sock", "--force"]),
        Surface::CmuxTui,
    )
    .unwrap() else {
        panic!("server stop must produce a server plan");
    };
    assert_eq!(global.socket, Some(PathBuf::from("/tmp/review.sock")));
    assert!(global.session.is_none());
    assert!(matches!(
        plan.action,
        lifecycle::ServerAction::Stop { force: true, end_terminals: false }
    ));

    let ParsedCommand::Command { plan: CommandPlan::Server(plan), .. } =
        parse(&strings(&["server", "stop", "--end-terminals"]), Surface::CmuxTui).unwrap()
    else {
        panic!("server stop --end-terminals must produce a server plan");
    };
    assert!(matches!(
        plan.action,
        lifecycle::ServerAction::Stop { force: false, end_terminals: true }
    ));

    let ParsedCommand::Command { global, plan: CommandPlan::Server(plan) } = parse(
        &strings(&[
            "server",
            "reload-config",
            "--session",
            "review-session",
            "--socket",
            "/tmp/review.sock",
        ]),
        Surface::CmuxTui,
    )
    .unwrap() else {
        panic!("server reload-config must produce a server plan");
    };
    assert_eq!(global.session.as_deref(), Some("review-session"));
    assert_eq!(global.socket, Some(PathBuf::from("/tmp/review.sock")));
    assert!(matches!(plan.action, lifecycle::ServerAction::ReloadConfig));
}

/// Review P2 (17011): `main` sets SIGTERM, SIGINT and SIGHUP to a handler
/// that only requests a mux shutdown, which `cmux_server` never reads. The
/// mount must give them back their default action so a signal ends it.
#[cfg(unix)]
#[test]
fn cmux_server_runs_with_default_termination_signals() {
    extern "C" fn only_flag(_: libc::c_int) {}
    let disposition = |signal| unsafe {
        let mut current = std::mem::zeroed::<libc::sigaction>();
        assert_eq!(libc::sigaction(signal, std::ptr::null(), &mut current), 0);
        current.sa_sigaction
    };
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        unsafe { libc::signal(signal, only_flag as *const () as libc::sighandler_t) };
        assert_ne!(disposition(signal), libc::SIG_DFL);
    }
    assert_eq!(machine_server::end_on_termination_signals(), Ok(()));
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        assert_eq!(disposition(signal), libc::SIG_DFL, "signal {signal}");
    }
}

/// Review P3 (17011): an option value is not the noun. The old
/// `--session NAME server status` spelling is the daemon lifecycle,
/// rewritten to `daemon` (compatibility, with a deprecation hint).
#[test]
fn cmux_server_option_values_and_old_lifecycle_routing() {
    let route = |line: &[&str]| match machine_server::args_for(&strings(line), Surface::Cmux) {
        Some(Ok(route)) => route,
        other => panic!("{line:?}: {other:?}"),
    };
    assert_eq!(
        route(&["--session", "agents", "server", "status"]),
        ServerRoute::DeprecatedLifecycle {
            args: strings(&["--session", "agents", "daemon", "status"]),
            verb: "status".to_owned(),
        }
    );
    assert_eq!(
        route(&["server", "status", "--session", "agents", "--json"]),
        ServerRoute::DeprecatedLifecycle {
            args: strings(&["daemon", "status", "--session", "agents", "--json"]),
            verb: "status".to_owned(),
        }
    );
    assert_eq!(
        route(&["--socket", "/tmp/s.sock", "server", "stop"]),
        ServerRoute::DeprecatedLifecycle {
            args: strings(&["--socket", "/tmp/s.sock", "daemon", "stop"]),
            verb: "stop".to_owned(),
        }
    );
    // A machine server verb with --session is refused, without a daemon hint.
    let Some(Err((error, _))) = machine_server::args_for(
        &strings(&["--session", "agents", "server", "install"]),
        Surface::Cmux,
    ) else {
        panic!("server install with --session was accepted");
    };
    assert!(error.0.contains("--session") && !error.0.contains("cmux daemon"), "{}", error.0);
    // `server` here is the value of --session, not the noun.
    assert!(
        machine_server::args_for(&strings(&["--session", "server", "--bogus"]), Surface::Cmux)
            .is_none()
    );
}

#[test]
fn cmux_server_refuses_global_options_that_do_not_apply() {
    // CLI owner condition: refused with a usage error, never dropped.
    for (line, option) in [
        (vec!["--session", "build", "server", "install"], "--session"),
        (vec!["--socket", "/tmp/x.sock", "server", "uninstall"], "--socket"),
        (vec!["server", "status", "--quiet"], "--quiet"),
        (vec!["--jsonl", "server", "status"], "--jsonl"),
        (vec!["--all-sessions", "server", "status"], "--all-sessions"),
        (vec!["--app-socket", "/tmp/a.sock", "server", "install"], "--app-socket"),
    ] {
        let Some(Err((error, _))) = machine_server::args_for(&strings(&line), Surface::Cmux) else {
            panic!("{line:?} was accepted");
        };
        assert!(error.0.contains(option) && error.0.contains("--json"), "{line:?}: {}", error.0);
    }
    // The ones that apply pass through.
    let routed = machine_server::args_for(
        &strings(&["--idempotency-key", "k1", "server", "pin", "1.2.3"]),
        Surface::Cmux,
    );
    assert_eq!(
        routed.map(|r| r.ok()),
        Some(Some(ServerRoute::Machine(strings(&["pin", "1.2.3", "--idempotency-key=k1"]))))
    );
}

#[test]
fn old_lifecycle_verbs_under_cmux_server_still_run_the_daemon_lifecycle() {
    // Released `uvx cmux server stop|start|stats|reload-config|ensure` and
    // pre-D1 scripts: the words are rewritten to `cmux daemon <verb>` and
    // run, with a deprecation hint. `status` alone is the machine server's.
    for verb in ["start", "ensure", "stats", "stop", "reload-config"] {
        let routed = machine_server::args_for(&strings(&["--json", "server", verb]), Surface::Cmux);
        assert_eq!(
            routed.map(|r| r.map_err(|(e, _)| e.0)),
            Some(Ok(ServerRoute::DeprecatedLifecycle {
                args: strings(&["--json", "daemon", verb]),
                verb: verb.to_owned(),
            })),
            "server {verb}"
        );
        // The rewritten words parse as the daemon lifecycle on `cmux`
        // (`daemon start` is the headless startup, routed by main.rs).
        if verb == "start" {
            continue;
        }
        let parsed = parse(&strings(&["--session", "s", "daemon", verb]), Surface::Cmux);
        assert!(
            matches!(parsed, Ok(ParsedCommand::Command { plan: CommandPlan::Server(_), .. })),
            "daemon {verb} did not parse as the daemon lifecycle"
        );
    }
    assert!(matches!(
        machine_server::args_for(&strings(&["server", "status"]), Surface::Cmux),
        Some(Ok(ServerRoute::Machine(_)))
    ));
    let hint = crate::localization::server_mount().daemon_lifecycle_deprecated;
    assert!(hint.contains("{verb}") && hint.contains("cmux daemon"), "{hint}");
}

#[test]
fn remote_invocation_allows_leading_global_options() {
    assert!(is_remote_invocation(&strings(&["remote", "connect"])));
    assert!(is_remote_invocation(&strings(&["--json", "remote", "connect"])));
    assert!(is_remote_invocation(&strings(&["--session", "-1", "remote", "connect"])));
    assert!(is_remote_invocation(&strings(&["--socket", "-tmp/socket", "remote", "connect"])));
    assert!(is_remote_invocation(&strings(&["--session=dev", "remote", "connect"])));
    assert!(is_remote_invocation(&strings(&[
        "--session",
        "dev",
        "--socket",
        "/tmp/cmux.sock",
        "remote",
        "rpc",
    ])));
    assert!(!is_remote_invocation(&strings(&["--session", "remote", "workspace", "list"])));
}

#[test]
fn remote_invocation_rejects_missing_global_option_values_and_terminator() {
    assert!(!is_remote_invocation(&strings(&["--session"])));
    assert!(!is_remote_invocation(&strings(&["--socket"])));
    assert!(!is_remote_invocation(&strings(&["--session", "--json", "remote", "connect",])));
    assert!(!is_remote_invocation(&strings(&["--socket", "--session=dev", "remote", "connect",])));
    assert!(!is_remote_invocation(&strings(&["--session=", "remote", "connect",])));
    assert!(!is_remote_invocation(&strings(&["--session", "--", "remote", "connect",])));
    assert!(!is_remote_invocation(&strings(&["--session", "dev", "--", "remote", "connect",])));
    assert!(!is_remote_invocation(&strings(&["--", "remote", "connect"])));
}

#[test]
fn agent_hook_emit_rejects_a_bad_terminal_like_every_other_terminal_flag() {
    let args = strings(&[
        "agent",
        "hook",
        "emit",
        "--source",
        "claude",
        "--event",
        "Stop",
        "--payload-json",
        "{}",
        "--terminal",
        "term_x",
    ]);
    let Err(error) = command::parse(&args, Surface::Cmux) else { panic!("parsed a bad terminal") };
    assert_eq!(error.0, "terminal ID must contain exactly 32 lowercase hexadecimal digits");
}
