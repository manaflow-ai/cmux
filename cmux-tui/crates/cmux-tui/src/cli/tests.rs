use super::*;

// The app fallback and the app scopes exist on unix only (cli.rs).
#[cfg(unix)]
mod action_surface_parity;
#[cfg(unix)]
mod cli_name_hints;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[cfg(unix)]
mod remote_cli_docs {
    use super::*;
    use std::collections::HashSet;

    const DOCUMENTS: &[(&str, &str)] = &[
        (
            "docs/remote-agents-and-cloud.md",
            include_str!("../../../../../docs/remote-agents-and-cloud.md"),
        ),
        ("acpmux README", include_str!("../../../acpmux/README.md")),
        ("acpmux skill", include_str!("../../../acpmux/skills/acpmux/SKILL.md")),
    ];

    fn command_lines(text: &str, binary: &str) -> Vec<Vec<String>> {
        fn shell_words(text: &str) -> Vec<String> {
            let mut words = Vec::new();
            let mut word = String::new();
            let mut quote = None;
            let mut escaped = false;
            for character in text.chars() {
                if escaped {
                    word.push(character);
                    escaped = false;
                    continue;
                }
                if character == '\\' && quote != Some('\'') {
                    escaped = true;
                    continue;
                }
                if let Some(closing) = quote {
                    if character == closing {
                        quote = None;
                    } else {
                        word.push(character);
                    }
                    continue;
                }
                match character {
                    '\'' | '"' => quote = Some(character),
                    ';' | '#' => break,
                    character if character.is_whitespace() => {
                        if !word.is_empty() {
                            words.push(std::mem::take(&mut word));
                        }
                    }
                    character => word.push(character),
                }
            }
            if !word.is_empty() {
                words.push(word);
            }
            words
                .into_iter()
                .map(|word| {
                    word.trim_matches(|character| "`[]()<>.,:".contains(character)).to_owned()
                })
                .collect()
        }

        let mut snippets = Vec::new();
        let mut in_fence = false;
        for line in text.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("```") {
                in_fence = !in_fence;
                continue;
            }
            if in_fence && (trimmed == binary || trimmed.starts_with(&format!("{binary} "))) {
                snippets.push(trimmed.to_owned());
            }
            let mut rest = line;
            while let Some(open) = rest.find('`') {
                let after_open = &rest[open + 1..];
                let Some(close) = after_open.find('`') else { break };
                let snippet = &after_open[..close];
                if snippet.trim_start() == binary
                    || snippet.trim_start().starts_with(&format!("{binary} "))
                {
                    snippets.push(snippet.trim().to_owned());
                }
                rest = &after_open[close + 1..];
            }
        }
        snippets
            .into_iter()
            .flat_map(|snippet| {
                snippet
                    .split(';')
                    .filter_map(|part| {
                        let words = shell_words(part.trim_start_matches("$ "));
                        (words.first().is_some_and(|word| word == binary) && words.len() > 1)
                            .then_some(words)
                    })
                    .collect::<Vec<_>>()
            })
            .collect()
    }

    fn action_names() -> HashSet<String> {
        let catalog: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../../plans/cmux-next/action-surfaces.json"
        ))
        .expect("action-surfaces.json is valid JSON");
        catalog["actions"]
            .as_array()
            .expect("actions array")
            .iter()
            .filter(|action| action["cli"] == "offered")
            .filter_map(|action| action["cli_name"].as_str().map(str::to_owned))
            .collect()
    }

    fn action_name(words: &[String], names: &HashSet<String>) -> Option<String> {
        let words = words
            .iter()
            .skip(1)
            .filter(|word| !matches!(word.as_str(), "--json" | "--jsonl" | "--quiet"))
            .take_while(|word| !word.starts_with('-'))
            .map(String::as_str)
            .collect::<Vec<_>>();
        (1..=words.len())
            .rev()
            .map(|count| words[..count].join(" "))
            .find(|name| names.contains(name))
    }

    fn action_flag_allowed(action: &str, flag: &str) -> bool {
        let common =
            matches!(flag, "--target" | "--wait" | "--no-wait" | "--interactive" | "--focus");
        match action {
            "agent open" => {
                common || matches!(flag, "--name" | "--key" | "--cwd" | "--host" | "--group")
            }
            "agent open-tab" => common || matches!(flag, "--host"),
            "cloud exec" => common || matches!(flag, "--command" | "--arg"),
            _ => true,
        }
    }

    fn missing_commands(text: &str, names: &HashSet<String>) -> Vec<String> {
        let mut missing = Vec::new();
        for words in command_lines(text, "cmux") {
            let parser_words = words[1..]
                .iter()
                .filter(|word| !matches!(word.as_str(), "--json" | "--jsonl" | "--quiet"))
                .cloned()
                .collect::<Vec<_>>();
            // A bare scope reference in prose (`cmux vm`, `cmux harness`) is
            // not a noun/verb command and has no action to resolve.
            if parser_words.len() < 2 {
                continue;
            }
            let action = action_name(&words, names);
            // Cloud verbs are app actions whose existence is checked by the
            // socket. Require a catalog match rather than generic parsing.
            // Resource commands still resolve through the CLI parser.
            let parser = builtin_command(&parser_words)
                || (parser_words[0] != "cloud" && parse(&parser_words, Surface::Cmux).is_ok());
            if action.is_none() && !parser {
                missing.push(words.join(" "));
            } else if let Some(action) = action {
                let command_words = action.split_whitespace().count();
                for flag in words
                    .iter()
                    .skip(1 + command_words)
                    .filter(|word| word.starts_with("--"))
                    .map(|word| word.split('=').next().unwrap_or(word))
                {
                    if !action_flag_allowed(&action, flag) {
                        missing.push(format!("{} (flag {flag})", words.join(" ")));
                    }
                }
            }
        }
        missing
    }

    fn builtin_command(words: &[String]) -> bool {
        let words = words.iter().map(String::as_str).collect::<Vec<_>>();
        matches!(
            words.as_slice(),
            ["action", "list", ..]
                | ["action", "describe", ..]
                | ["action", "run", ..]
                | ["harness", "add", ..]
                | ["harness", "secret", "set", ..]
                | ["harness", "doctor", ..]
                | ["link", "machine", "update", ..]
                | ["docs", "search", ..]
        )
    }

    #[test]
    fn documented_cmux_commands_resolve_in_the_parser_or_action_catalog() {
        let names = action_names();
        let missing = DOCUMENTS
            .iter()
            .flat_map(|(source, text)| {
                missing_commands(text, &names)
                    .into_iter()
                    .map(move |command| format!("{source}: {command}"))
            })
            .collect::<Vec<_>>();
        assert!(missing.is_empty(), "documented cmux command drifted:\n{}", missing.join("\n"));
    }

    #[test]
    fn a_deliberately_stale_cmux_line_is_rejected() {
        let names = action_names();
        let missing = missing_commands("`cmux cloud deliberately-stale-action`", &names);
        assert_eq!(missing, vec!["cmux cloud deliberately-stale-action"]);
    }

    #[test]
    fn cloud_help_lists_every_offered_cloud_action() {
        let missing = action_names()
            .into_iter()
            .filter_map(|name| name.strip_prefix("cloud ").map(str::to_owned))
            .filter(|name| !CLOUD_HELP.contains(name))
            .collect::<Vec<_>>();
        assert!(missing.is_empty(), "cloud help omitted catalog actions: {missing:?}");
    }

    #[test]
    fn cloud_exec_without_command_returns_actionable_usage() {
        let args = strings(&["cloud", "exec", "--target", "machine:builder"]);
        assert!(app::parse(&args).is_err());
        let args =
            strings(&["cloud", "exec", "--target", "machine:builder", "--arg", "command=uname -a"]);
        assert!(app::parse(&args).is_ok());
        assert!(CLOUD_HELP.contains("cloud <action>"));
        assert!(AGENT_HELP.contains("agent open-tab"));
        assert!(AGENT_HELP.contains("agent open <session id> [--name NAME] [--key UUID] [--cwd DIR] [--host HOST] [--group GROUP] [--focus]"));
    }

    #[test]
    fn documented_action_flag_typos_are_rejected() {
        let names = action_names();
        let missing = missing_commands(
            "```sh\ncmux cloud exec --target machine:builder --comand uname\n```",
            &names,
        );
        assert_eq!(
            missing,
            vec!["cmux cloud exec --target machine:builder --comand uname (flag --comand)"]
        );
    }
}

#[test]
fn removed_route_is_detected_after_global_options() {
    assert!(removed_route_requested(&strings(&["route", "list"])));
    assert!(removed_route_requested(&strings(&["--json", "route", "list"])));
    assert!(removed_route_requested(&strings(&["--socket", "/tmp/cmux.sock", "route", "list"])));
    assert!(removed_route_requested(&strings(&["--headless", "route", "list"])));
    assert!(removed_route_requested(&strings(&["help", "route"])));
    assert!(removed_route_requested(&strings(&["--headless", "help", "route"])));
    assert!(removed_route_requested(&strings(&["--state", "/tmp/state", "route", "list"])));
    assert!(removed_route_requested(&strings(&["--json", "acp", "route"])));
    assert!(!removed_route_requested(&strings(&[
        "--machine-provider-command",
        "/bin/foo",
        "route",
        "list",
        "--"
    ])));
    assert!(removed_route_requested(&strings(&[
        "route",
        "list",
        "--machine-provider-command",
        "foo",
        "--"
    ])));
    assert!(removed_route_requested(&strings(&["--owner-ready-fd", "5", "route", "list"])));
    assert!(!removed_route_requested(&strings(&["--socket", "route", "workspace", "list"])));
    assert!(!removed_route_requested(&strings(&["--", "route", "list"])));
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

/// `cmux workspace new-on-machine --machine m`: an app action run by its CLI
/// name keeps a `--machine` after its words as its own argument (the global
/// option swallowed it, so the app answered "requires --machine"). Before
/// the first command word it stays the global option, and the mux grammar's
/// routing (`workspace list --machine m`) is unchanged.
#[cfg(unix)]
#[test]
fn an_app_actions_own_machine_flag_follows_its_words() {
    for (line, own) in [
        (&["workspace", "new-on-machine", "--machine", "vm-1"][..], &["--machine", "vm-1"][..]),
        (&["workspace", "new-on-machine", "--machine=vm-1"][..], &["--machine=vm-1"][..]),
        (
            &["--json", "workspace", "new-on-machine", "--machine", "vm-1", "--focus"][..],
            &["--machine", "vm-1", "--focus"][..],
        ),
    ] {
        let (global, command) = parse_action_globals(&strings(line)).unwrap();
        assert_eq!(global.machine, None, "{line:?}");
        let mut expected = strings(&["workspace", "new-on-machine"]);
        expected.extend(strings(own));
        assert_eq!(command, expected, "{line:?}");
        let words = command.iter().take_while(|arg| !arg.starts_with('-')).count();
        let app::AppCommand::Call { params, .. } =
            app::run_action(&command[..words].join(" "), &command[words..], app::ActionName::Cli)
                .unwrap()
        else {
            panic!("expected a call")
        };
        assert_eq!(params["action"], "workspace new-on-machine", "{line:?}");
        assert_eq!(params["args"]["machine"], "vm-1", "{line:?}: {params}");
    }
    // Before the action's words `--machine` is the global option.
    for line in [
        &["--machine", "vm-1", "workspace", "new-on-machine"][..],
        &["--machine=vm-1", "workspace", "new-on-machine"][..],
    ] {
        let (global, command) = parse_action_globals(&strings(line)).unwrap();
        assert_eq!(global.machine.as_deref(), Some("vm-1"), "{line:?}");
        assert_eq!(command, strings(&["workspace", "new-on-machine"]), "{line:?}");
    }
    // The mux grammar keeps routing a `--machine` anywhere before `--`.
    let (global, command) =
        parse_globals(&strings(&["workspace", "list", "--machine", "vm-1"])).unwrap();
    assert_eq!(global.machine.as_deref(), Some("vm-1"));
    assert_eq!(command, strings(&["workspace", "list"]));
    // After `--` it is a payload word for both.
    let line = strings(&["workspace", "current", "run", "--", "tool", "--machine", "x"]);
    assert_eq!(parse_action_globals(&line).unwrap().1, line);
    assert_eq!(parse_globals(&line).unwrap().1, line);
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
        lifecycle::ServerAction::Stop { force: true, end_terminals: false, .. }
    ));

    let ParsedCommand::Command { plan: CommandPlan::Server(plan), .. } =
        parse(&strings(&["server", "stop", "--end-terminals"]), Surface::CmuxTui).unwrap()
    else {
        panic!("server stop --end-terminals must produce a server plan");
    };
    assert!(matches!(
        plan.action,
        lifecycle::ServerAction::Stop { force: false, end_terminals: true, .. }
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
        scope_help_for("server stats", crate::localization::catalog()).contains("daemon stats")
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
    assert!(TERMINAL_HELP.contains("move|project --workspace <selector>"));
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
    // `cmux` has no session scope, so its `ls` shorthand lists workspaces.
    assert!(matches!(parse(&strings(&["ls"]), Surface::Cmux), Ok(ParsedCommand::Command { .. })));
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
        // `cmux harness run ID --tab` (acp.rs).
        vec!["pane", "current", "run", "--", "/bin/cmux", "harness", "run", "aider", "--cwd", "/r"],
        // The daemon lifecycle on `cmux` (decision D1).
        vec!["--session", "cmux-app", "--json", "daemon", "ensure"],
        vec!["--session", "cmux-app", "--json", "daemon", "status"],
    ] {
        assert!(parse(&strings(&args), Surface::Cmux).is_ok(), "{args:?}");
    }
    // The app's daemon launcher and iOS remotes run the binary as
    // `cmux-tui`, where `server` stays the lifecycle.
    for args in [
        vec!["--session", "cmux-app", "--json", "server", "ensure"],
        vec!["--session", "cmux-app", "--json", "server", "status"],
    ] {
        assert!(parse(&strings(&args), Surface::CmuxTui).is_ok(), "{args:?}");
    }
}

/// The lifecycle action that `args` parse to on `surface`, or `None`.
fn lifecycle_action(args: &[&str], surface: Surface) -> Option<String> {
    match parse(&strings(args), surface) {
        Ok(ParsedCommand::Command { plan: CommandPlan::Server(plan), .. }) => {
            Some(format!("{:?}", plan.action))
        }
        _ => None,
    }
}

#[test]
fn cmux_daemon_and_cmux_tui_server_are_the_lifecycle() {
    // Decision D1: `cmux daemon …` on `cmux`; `server` (and the `daemon`
    // alias) on `cmux-tui`.
    for action in ["ensure", "status", "stop"] {
        let want = lifecycle_action(&["server", action], Surface::CmuxTui)
            .unwrap_or_else(|| panic!("cmux-tui server {action}"));
        assert_eq!(lifecycle_action(&["daemon", action], Surface::Cmux).as_ref(), Some(&want));
        assert_eq!(lifecycle_action(&["daemon", action], Surface::CmuxTui).as_ref(), Some(&want));
        assert_eq!(lifecycle_action(&["srv", action], Surface::CmuxTui).as_ref(), Some(&want));
        // `srv` is not a scope on `cmux`.
        assert_eq!(lifecycle_action(&["srv", action], Surface::Cmux), None, "{action}");
        // No hidden `server` alias of the lifecycle on `cmux`.
        assert_eq!(lifecycle_action(&["server", action], Surface::Cmux), None, "{action}");
    }
    // `start` is rewritten to the headless owner only where it names the
    // lifecycle.
    let lifecycle = machine_server::lifecycle_scope_for;
    assert!(lifecycle("daemon", Surface::Cmux));
    assert!(lifecycle("server", Surface::CmuxTui));
    assert!(lifecycle("daemon", Surface::CmuxTui));
    assert!(!lifecycle("server", Surface::Cmux));
    assert!(!lifecycle("srv", Surface::Cmux));
    assert!(lifecycle("srv", Surface::CmuxTui));
    // `cmux daemon --help` is the lifecycle help; `cmux help server` is the
    // machine server's.
    let Ok(ParsedCommand::Help(Some(topic))) =
        parse(&strings(&["daemon", "--help"]), Surface::Cmux)
    else {
        panic!("daemon --help");
    };
    assert_eq!(topic, "server");
    let Ok(ParsedCommand::Help(Some(topic))) = parse(&strings(&["help", "server"]), Surface::Cmux)
    else {
        panic!("help server");
    };
    assert!(scope_help(&topic).contains("cmux server: run this machine"), "{topic}");
    let catalog = crate::localization::catalog_for_locale("en_US.UTF-8");
    assert!(catalog.local_server.cmux_root_help.contains("\n  daemon "));
    assert!(catalog.local_server.help.contains("cmux daemon ensure"));
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
fn cmux_server_is_the_machine_server() {
    // Decision D1: on `cmux`, `server …` goes to cmux_server::cli.
    let args = |line: &[&str], surface| {
        machine_server::args_for(&strings(line), surface).map(|r| r.map_err(|(e, _)| e.0))
    };
    let machine = |line: &[&str]| Some(Ok(ServerRoute::Machine(strings(line))));
    assert_eq!(args(&["server", "status"], Surface::Cmux), machine(&["status"]));
    assert_eq!(
        args(&["--json", "server", "upgrade", "--channel-url", "https://c.example"], Surface::Cmux),
        machine(&["upgrade", "--channel-url", "https://c.example", "--json"])
    );
    assert_eq!(args(&["server", "--help"], Surface::Cmux), machine(&["--help"]));
    assert_eq!(args(&["server", "status"], Surface::CmuxTui), None, "cmux-tui keeps the lifecycle");
    assert_eq!(args(&["daemon", "status"], Surface::Cmux), None);
    assert_eq!(args(&["workspace", "list"], Surface::Cmux), None);
    // The routed words parse as the machine server's `status` verb.
    let Some(Ok(ServerRoute::Machine(routed))) = args(&["server", "status"], Surface::Cmux) else {
        panic!("server status was not routed to the machine server");
    };
    assert_eq!(cmux_server::cli::parse(&routed).unwrap().verb_str(), "status");
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
fn the_cmux_version_scale_is_one_number() {
    // min_cmux_version compares against the cmux binary's version; the
    // standalone cmux-server reports cmux_server_core's constant.
    assert_eq!(machine_server::release_version(), cmux_server_core::manifest::CMUX_VERSION);
    assert_eq!(cmux_server::cli::running_version(), machine_server::release_version());
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
fn remote_app_action_words_run_the_app_action_not_the_remote_family() {
    // `cmux remote new-group HOST` is the app's New Remote Group (remote.newGroup);
    // only the remote command family's own words stay with it.
    assert!(!is_remote_invocation(&strings(&["remote", "new-group", "--destination", "box"])));
    assert!(!is_remote_invocation(&strings(&["--json", "remote", "remove-group"])));
    assert!(!is_remote_invocation(&strings(&["--session", "dev", "remote", "reconnect"])));
    assert!(is_remote_invocation(&strings(&["remote"])));
    assert!(is_remote_invocation(&strings(&["remote", "--help"])));
    assert!(is_remote_invocation(&strings(&["remote", "help"])));
    assert!(is_remote_invocation(&strings(&["remote", "stop"])));
    assert!(is_remote_invocation(&strings(&["remote", "connect", "ssh://box"])));
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

mod machine_catalog;

#[test]
fn root_help_lists_every_scope_and_help_word_reaches_own_help_scopes() {
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let help = crate::localization::catalog_for_locale(locale).local_server.cmux_root_help;
        for scope in surface::CMUX_SCOPES.iter().chain(OWN_HELP_SCOPES) {
            assert!(
                help.lines().any(|line| line.starts_with(&format!("  {scope} "))),
                "{locale}: `cmux --help` does not list {scope}"
            );
        }
    }
    let rewritten = |words: &[&str]| {
        let mut args = strings(words);
        rewrite_help_word_on(&mut args, Surface::Cmux);
        args
    };
    for &scope in OWN_HELP_SCOPES {
        let own_help = if scope == "device" { "help" } else { "--help" };
        assert_eq!(rewritten(&["help", scope]), strings(&[scope, own_help]), "{scope}");
    }
    for with_globals in [
        vec!["--session", "s", "help", "agents", "--json"],
        vec!["help", "--json", "agents"],
        vec!["help", "--session", "s", "agents"],
        vec!["--session", "help", "help", "agents"],
    ] {
        assert_eq!(rewritten(&with_globals), strings(&["agents", "--help"]), "{with_globals:?}");
    }
    assert_eq!(rewritten(&["--session", "s", "help", "chats"]), strings(&["chats", "--help"]));
    for unchanged in [
        vec!["help", "workspace"],
        vec!["help", "agents", "chat"],
        vec!["agents", "help"],
        vec!["--session", "help", "agents"],
    ] {
        assert_eq!(rewritten(&unchanged), strings(&unchanged), "{unchanged:?}");
    }
    let os = |words: &[&str]| words.iter().map(std::ffi::OsString::from).collect::<Vec<_>>();
    assert_eq!(acp_scope_args(&strings(&["acp", "ls", "--json"])), os(&["ls", "--json"]));
    assert_eq!(acp_scope_args(&rewritten(&["help", "harness"])), os(&["harness", "--help"]));
    assert_eq!(acp_scope_args(&rewritten(&["help", "chats"])), os(&["chats", "--help"]));
}
