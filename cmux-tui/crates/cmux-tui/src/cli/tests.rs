use super::*;

// The app fallback and the app scopes exist on unix only (cli.rs).
#[cfg(unix)]
mod action_surface_parity;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[test]
fn global_modes_are_mutually_exclusive() {
    let error = parse_globals(&strings(&["--json", "--quiet", "workspace", "list"])).unwrap_err();
    assert!(error.0.0.contains("another output mode"));
    assert_eq!(error.1, OutputMode::Json);
}

#[test]
fn separator_stops_global_flag_extraction() {
    let (global, command) = parse_globals(&strings(&[
        "--json",
        "workspace",
        "current",
        "run",
        "--",
        "tool",
        "--session",
        "literal",
    ]))
    .unwrap();
    assert_eq!(global.output, OutputMode::Json);
    assert_eq!(
        command,
        strings(&["workspace", "current", "run", "--", "tool", "--session", "literal",])
    );
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
fn global_value_options_reject_following_option() {
    let error = parse_globals(&strings(&["--session", "--json", "workspace", "list"])).unwrap_err();
    assert!(error.0.0.contains("--session needs a value"));
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

#[test]
fn server_stats_parses_with_routing_options() {
    let ParsedCommand::Command { global, plan: CommandPlan::Server(plan) } =
        parse(&strings(&["server", "stats", "--session", "review-session"]), Surface::CmuxTui)
            .unwrap()
    else {
        panic!("server stats must produce a server plan");
    };
    assert_eq!(global.session.as_deref(), Some("review-session"));
    assert!(matches!(plan.action, lifecycle::ServerAction::Stats));
    assert!(
        scope_help_for("server stats", crate::localization::catalog()).contains("server stats")
    );
}

#[test]
fn server_stats_help_routes_to_the_stats_topic() {
    let ParsedCommand::Help(Some(topic)) =
        parse(&strings(&["server", "stats", "--help"]), Surface::CmuxTui).unwrap()
    else {
        panic!("server stats help must produce a scoped help topic");
    };
    assert_eq!(topic, "server stats");
    assert!(scope_help_for(&topic, crate::localization::catalog()).contains("--json"));
}

#[test]
fn every_scope_has_dedicated_help() {
    let english_catalog = crate::localization::catalog_for_locale("en_US.UTF-8");
    for scope in PUBLIC_SCOPES {
        let help = scope_help_for(scope, english_catalog);
        assert!(help.contains("USAGE"));
        assert!(help.contains(scope));
    }
    let japanese_catalog = crate::localization::catalog_for_locale("ja_JP.UTF-8");
    let english = session_help(&english_catalog.session_reset, &english_catalog.local_server);
    let japanese = session_help(&japanese_catalog.session_reset, &japanese_catalog.local_server);
    assert!(english.contains("creation <correlation-key> resolve"));
    assert!(english.contains("session <name> reset-state"));
    assert!(japanese.contains("session <name> reset-state"));
    assert!(japanese.contains("保存状態のリセット"));
    assert!(TERMINAL_HELP.contains("screen wait --pattern <regex>"));
    assert!(TERMINAL_HELP.contains("process wait [--timeout-ms <n>]"));
    assert!(TERMINAL_HELP.contains("move|project|attach|close"));
}

#[test]
fn startup_help_is_explicitly_discoverable() {
    let help = root_help(&crate::localization::catalog_for_locale("en_US.UTF-8").local_server);
    assert!(help.contains("cmux help start"));
    assert!(help.starts_with("cmux - "));
    assert!(!help.contains("cmux-tui"));
    assert!(matches!(
        parse(&strings(&["help", "start"]), Surface::CmuxTui).unwrap(),
        ParsedCommand::Help(Some(scope)) if scope == "start"
    ));
}

#[test]
fn the_cmux_name_selects_the_curated_surface() {
    use std::ffi::OsStr;
    for name in ["cmux", "/Applications/cmux.app/Contents/Resources/bin/cmux", "cmux.exe"] {
        assert_eq!(Surface::for_program(Some(OsStr::new(name))), Surface::Cmux, "{name}");
    }
    for name in ["cmux-tui", "/usr/local/bin/cmux-tui", "cmux-tui-4f2a", "acpmux"] {
        assert_eq!(Surface::for_program(Some(OsStr::new(name))), Surface::CmuxTui, "{name}");
    }
    assert_eq!(Surface::for_program(None), Surface::CmuxTui);
}

#[test]
fn cmux_refuses_cmux_tui_only_scopes_by_name_in_every_spelling() {
    let catalog = crate::localization::catalog_for_locale("en_US.UTF-8");
    for scope in CMUX_TUI_ONLY_SCOPES {
        assert!(PUBLIC_SCOPES.contains(scope));
        assert!(!surface::CMUX_SCOPES.contains(scope));
        for args in [vec![*scope, "list"], vec!["help", scope], vec![*scope, "--help"]] {
            let Err(failure) = parse(&strings(&args), Surface::Cmux) else {
                panic!("cmux accepted {args:?}");
            };
            assert!(failure.error.0.contains("is not part of cmux"), "{args:?}: {}", failure.error);
        }
    }
    // Shorthands lower first, so `ls` (session list) is refused too.
    assert!(parse(&strings(&["ls"]), Surface::Cmux).is_err());
    assert!(!catalog.local_server.cmux_root_help.contains("raw"));
    // A typo suggests only a scope cmux shows.
    let Err(failure) = parse(&strings(&["sesion", "list"]), Surface::Cmux) else {
        panic!("accepted a typo");
    };
    assert!(!failure.error.0.contains("session"), "{}", failure.error);
}

#[test]
fn cmux_tui_keeps_the_scopes_its_own_tooling_calls() {
    // Cloud VM guest scripts (web/services/vms) run these as `cmux-tui`.
    for args in [
        vec!["raw", "command", "--request-json", r#"{"cmd":"url-open"}"#],
        vec!["session", "current", "snapshot"],
        vec!["ls"],
    ] {
        assert!(parse(&strings(&args), Surface::CmuxTui).is_ok(), "{args:?}");
    }
}

#[test]
fn cmux_accepts_what_its_own_processes_send_through_the_parser() {
    for args in [
        // The Claude `--settings` hook fallback (agent_hook_install.rs).
        vec!["agent", "hook", "emit", "--source", "claude", "--event", "Stop"],
        // `cmux acp open` (acp.rs).
        vec!["pane", "current", "run", "--", "/bin/cmux", "acp", "attach", "review"],
        // The app's daemon launcher and iOS remotes.
        vec!["--session", "cmux-app", "--json", "server", "ensure"],
        vec!["--session", "cmux-app", "--json", "server", "status"],
    ] {
        assert!(parse(&strings(&args), Surface::Cmux).is_ok(), "{args:?}");
    }
}

#[test]
fn workspace_group_verbs_use_the_personal_operations() {
    for surface in [Surface::Cmux, Surface::CmuxTui] {
        for args in [
            vec!["workspace", "group", "list"],
            vec!["workspace", "group", "create", "--name", "Work"],
        ] {
            assert!(parse(&strings(&args), surface).is_ok(), "{args:?}");
        }
    }
    assert!(WORKSPACE_HELP.contains("workspace group create"));
}

#[test]
fn cmux_shows_and_accepts_the_state_scopes() {
    for args in [
        vec!["room", "list"],
        vec!["closed", "list"],
        vec!["help", "room"],
        vec!["closed", "--help"],
        vec!["tab", "group", "list"],
        vec!["screen", "group", "list"],
        vec!["workspace", "current", "status", "list"],
    ] {
        assert!(parse(&strings(&args), Surface::Cmux).is_ok(), "{args:?}");
    }
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let help = crate::localization::catalog_for_locale(locale).local_server.cmux_root_help;
        assert!(help.contains("  room "), "{locale}");
        assert!(help.contains("  closed "), "{locale}");
    }
    assert!(TAB_HELP.contains("tab group saved list"));
    assert!(SCREEN_HELP.contains("screen group create"));
    assert!(WORKSPACE_HELP.contains("progress set <0..1>"));
}

#[test]
fn global_idempotency_key_reaches_the_mutation_and_only_a_mutation() {
    let ParsedCommand::Command { plan: CommandPlan::Protocol(request), .. } = parse(
        &strings(&["--idempotency-key", "mutation-retry-1", "workspace", "create"]),
        Surface::Cmux,
    )
    .unwrap() else {
        panic!("expected a request")
    };
    assert_eq!(request.idempotency_key.as_deref(), Some("mutation-retry-1"));
    let ParsedCommand::Command { plan: CommandPlan::Protocol(request), .. } = parse(
        &strings(&["workspace", "create", "--idempotency-key=mutation-retry-2"]),
        Surface::Cmux,
    )
    .unwrap() else {
        panic!("expected a request")
    };
    assert_eq!(request.idempotency_key.as_deref(), Some("mutation-retry-2"));
    assert!(
        parse(&strings(&["--idempotency-key", "k1", "workspace", "list"]), Surface::Cmux).is_err()
    );
    assert!(
        parse(&strings(&["--idempotency-key", "", "workspace", "create"]), Surface::Cmux).is_err()
    );
}

#[test]
fn all_sessions_runs_only_lists_and_never_with_a_named_session() {
    let ParsedCommand::Command { global, plan: CommandPlan::Protocol(request) } =
        parse(&strings(&["workspace", "list", "--all-sessions"]), Surface::Cmux).unwrap()
    else {
        panic!("expected a request")
    };
    assert!(global.all_sessions);
    assert_eq!(request.operation.name().unwrap(), "workspace.list");
    // Without the flag a list stays on the one session the CLI addresses.
    let ParsedCommand::Command { global, .. } =
        parse(&strings(&["workspace", "list"]), Surface::Cmux).unwrap()
    else {
        panic!("expected a request")
    };
    assert!(!global.all_sessions && global.session.is_none());
    for refused in [
        &["--all-sessions", "workspace", "create"][..],
        &["--all-sessions", "workspace", "current", "show"],
        &["--all-sessions", "--session", "build", "workspace", "list"],
    ] {
        assert!(parse(&strings(refused), Surface::Cmux).is_err(), "{refused:?}");
    }
}

#[test]
fn a_session_qualified_id_routes_the_request_to_that_session() {
    let ParsedCommand::Command { global, plan: CommandPlan::Protocol(request) } = parse(
        &strings(&["workspace", "build-box:ws_00000000000000000000000000000004", "show"]),
        Surface::Cmux,
    )
    .unwrap() else {
        panic!("expected a request")
    };
    assert_eq!(global.session.as_deref(), Some("build-box"));
    assert_eq!(request.params["workspace"], "ws_00000000000000000000000000000004");
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
fn shorthand_resource_paths_preserve_selectors_and_payloads() {
    for (short, canonical) in [
        (vec!["ws", "ls"], vec!["workspace", "list"]),
        (vec!["ws", "new", "--name", "term"], vec!["workspace", "create", "--name", "term"]),
        (vec!["pane", "split", "--down"], vec!["pane", "current", "split", "--down"]),
        (
            vec!["ws", "name:ls", "win", "current", "p", "current", "get"],
            vec!["workspace", "name:ls", "screen", "current", "pane", "current", "show"],
        ),
        (
            vec!["term", "current", "write", "--text", "--json"],
            vec!["terminal", "current", "write", "--text=--json"],
        ),
        (
            vec!["term", "current", "write", "--text", "--help"],
            vec!["terminal", "current", "write", "--text=--help"],
        ),
        (
            vec!["ws", "current", "run", "--", "echo", "--json", "neww"],
            vec!["workspace", "current", "run", "--", "echo", "--json", "neww"],
        ),
    ] {
        let plan = |args: Vec<&str>| {
            let ParsedCommand::Command { global, plan: CommandPlan::Protocol(request) } =
                parse(&strings(&args), Surface::CmuxTui).unwrap()
            else {
                panic!("expected typed request")
            };
            (global.output, request.operation.name().unwrap(), request.params)
        };
        assert_eq!(plan(short), plan(canonical));
    }
}

#[test]
fn shorthand_tmux_commands_share_canonical_operations() {
    for (short, canonical) in [
        (vec!["ls"], vec!["session", "list"]),
        (vec!["lsw"], vec!["screen", "list"]),
        (vec!["lsp"], vec!["pane", "list"]),
        (vec!["neww", "-n", "api"], vec!["screen", "create", "--name", "api"]),
        (vec!["splitw", "-h"], vec!["pane", "current", "split", "--right"]),
        (vec!["splitw"], vec!["pane", "current", "split", "--down"]),
        (vec!["selectp", "-L"], vec!["pane", "current", "focus", "direction", "left"]),
        (vec!["selectw", "-t", "api"], vec!["screen", "api", "focus"]),
        (
            vec!["renamew", "-t", "api", "backend"],
            vec!["screen", "api", "rename", "--name", "backend"],
        ),
        (vec!["capturep"], vec!["terminal", "current", "screen", "read"]),
        (vec!["send-keys", "C-c", "Enter"], vec!["terminal", "current", "keys", "ctrl+c", "enter"]),
        (
            vec!["send-keys", "-l", "hello", "世界"],
            vec!["terminal", "current", "write", "--text", "hello世界"],
        ),
    ] {
        let plan = |args: Vec<&str>| {
            let ParsedCommand::Command { plan: CommandPlan::Protocol(request), .. } =
                parse(&strings(&args), Surface::CmuxTui).unwrap()
            else {
                panic!("expected typed request")
            };
            (request.operation.name().unwrap(), request.params)
        };
        assert_eq!(plan(short), plan(canonical));
    }
}

#[test]
fn shorthand_rejects_unsupported_or_conflicting_flags_before_execution() {
    for args in [
        vec!["splitw", "-h", "-v"],
        vec!["splitw", "-d"],
        vec!["selectp", "-L", "-R"],
        vec!["neww", "-n", "one", "--name", "two"],
        vec!["selectw", "-t"],
        vec!["capturep", "-t", "one", "--target", "two"],
        vec!["send-keys", "hello world"],
        vec!["new-session"],
    ] {
        assert!(parse(&strings(&args), Surface::CmuxTui).is_err(), "accepted {args:?}");
    }
}
