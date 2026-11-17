use super::*;

/// `cmux agent hook status` text output said only "One or more
/// coding-agent hook operations failed" (bench round 3); the cause was
/// in `--json` alone.
#[test]
fn w4j_a_hook_failure_message_names_each_cause() {
    let value = json!({"errors": ["copilot: ~/.copilot/config.json is not valid JSON"]});
    assert_eq!(
        agent_hooks_failure_message(&value),
        "coding-agent hook operations failed: copilot: ~/.copilot/config.json is not valid JSON"
    );
    assert_eq!(
        agent_hooks_failure_message(&json!({"errors": []})),
        "one or more coding-agent hook operations failed"
    );
}

fn raw_request(args: &[&str]) -> Value {
    match parse(&strings(args), super::super::Surface::CmuxTui).unwrap() {
        CommandPlan::RawCommand(plan) => plan.request,
        _ => panic!("group action did not produce a raw command"),
    }
}

#[test]
fn tab_group_moves_without_a_v2_operation_map_to_private_group_commands() {
    let split =
        raw_request(&["tab", "group", "tgrp_1", "split", "--pane", "pane_ab", "--edge", "right"]);
    assert_eq!(split["cmd"], "move-tab-group-to-split");
    assert_eq!(split["pane"], "pane_ab");
    let unsave = raw_request(&["tab", "group", "tgrp_1", "unsave"]);
    assert_eq!(unsave["cmd"], "unsave-tab-group");
    assert_eq!(unsave["group"], "tgrp_1");
    let created =
        protocol(&["tab", "group", "create", "--tabs", "tab_00000000000000000000000000000001"]);
    assert_eq!(operation(&created), "tab_group.create");
    let group = protocol(&["workspace", "group", "create", "--name", "Work"]);
    assert_eq!(operation(&group), "workspace_group.create");
    assert_eq!(group.params["name"], "Work");
    assert!(group.params.get("reuse").is_none(), "a plain create makes a group");
    let reuse = protocol(&["workspace", "group", "create", "--name", "Leads", "--reuse"]);
    assert_eq!(reuse.params["reuse"], true);
    let remove = protocol(&[
        "workspace",
        "group",
        "remove",
        "--workspace",
        "ws_0123456789abcdef0123456789abcdef",
    ]);
    assert_eq!(operation(&remove), "workspace.place");
    assert!(remove.params["group"].is_null());
    assert!(
        parse(&strings(&["tab", "group", "tgrp_1", "explode"]), super::super::Surface::CmuxTui)
            .is_err()
    );
    assert!(parse(&strings(&["tab", "group", "create"]), super::super::Surface::CmuxTui).is_err());
}

#[test]
fn browser_open_alias_maps_to_tab_create_browser() {
    let plan = protocol(&["browser", "open", "https://example.com"]);
    assert_eq!(operation(&plan), "tab.create_browser");
    assert_eq!(plan.params["url"], "https://example.com");

    let flagged = protocol(&["browser", "open", "--url", "https://example.com/docs"]);
    assert_eq!(operation(&flagged), "tab.create_browser");
    assert_eq!(flagged.params["url"], "https://example.com/docs");
}

#[test]
fn browser_open_and_tab_create_browser_take_an_engine() {
    let chromium = protocol(&["browser", "open", "https://a.test", "--engine", "chromium"]);
    assert_eq!(chromium.params["engine"], "cef");
    let chrome =
        protocol(&["tab", "create", "browser", "--url", "https://a.test", "--engine", "Chrome"]);
    assert_eq!(chrome.params["engine"], "cef");
    let webkit = protocol(&["browser", "open", "https://a.test", "--engine", "webkit"]);
    assert_eq!(webkit.params["engine"], "webkit");
    // No flag: no field, so `browser.defaultEngine` decides.
    assert!(protocol(&["browser", "open", "https://a.test"]).params.get("engine").is_none());
    let profile = protocol(&[
        "browser",
        "profile",
        "open",
        "https://a.test",
        "--profile",
        "p",
        "--engine",
        "chromium",
    ]);
    assert_eq!(profile.params["engine"], "cef");
    let unknown = strings(&["browser", "open", "https://a.test", "--engine", "gecko"]);
    assert!(parse(&unknown, super::super::Surface::CmuxTui).is_err());
}

#[test]
fn terminal_keep_maps_to_the_private_set_terminal_keep_command() {
    const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";
    let on = raw_request(&["terminal", TERMINAL, "keep", "on"]);
    assert_eq!(on["cmd"], "set-terminal-keep");
    assert_eq!(on["terminal_id"], TERMINAL);
    assert_eq!(on["keep"], true);
    let off = raw_request(&["terminal", TERMINAL, "keep", "off"]);
    assert_eq!(off["keep"], false);
    assert!(
        parse(&strings(&["terminal", "current", "keep", "on"]), super::super::Surface::CmuxTui)
            .is_err()
    );
    assert!(
        parse(&strings(&["terminal", TERMINAL, "keep", "maybe"]), super::super::Surface::CmuxTui)
            .is_err()
    );
    assert!(
        parse(&strings(&["terminal", "term_xyz", "keep", "on"]), super::super::Surface::CmuxTui)
            .is_err()
    );
}

#[test]
fn terminal_pin_tail_maps_to_set_terminal_tail_pin() {
    const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";
    let on = raw_request(&["terminal", TERMINAL, "pin-tail", "on"]);
    assert_eq!(on["cmd"], "set-terminal-tail-pin");
    assert_eq!(on["terminal"], TERMINAL);
    assert_eq!(on["pinned"], true);
    let off = raw_request(&["terminal", TERMINAL, "pin-tail", "off"]);
    assert_eq!(off["pinned"], false);
    for bad in [["terminal", "@2", "pin-tail", "on"], ["terminal", TERMINAL, "pin-tail", "maybe"]] {
        assert!(parse(&strings(&bad), super::super::Surface::CmuxTui).is_err());
    }
}

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

#[test]
fn boolean_flag_metadata_matches_tokenizer_contract() {
    for name in BOOLEAN_FLAGS {
        assert!(is_boolean_flag(name));
        let args = vec!["workspace".into(), "create".into(), format!("--{name}")];
        let tokens = tokenize(&args).expect("metadata flag must tokenize");
        assert!(tokens.flags.values.contains_key(*name));
        assert_eq!(tokens.flags.values[*name], None);
    }
}

#[test]
fn confirm_takes_no_value() {
    let tokens = tokenize(&strings(&["workspace", "create", "--confirm", "--name", "v"]))
        .expect("--confirm must tokenize as a switch");
    assert_eq!(tokens.flags.values.get("confirm"), Some(&None));
    assert_eq!(tokens.flags.values.get("name"), Some(&Some("v".to_string())));
}

#[test]
fn non_boolean_flags_still_consume_the_next_token() {
    let tokens = tokenize(&strings(&["workspace", "create", "--name", "value"]))
        .expect("value flag must tokenize");
    assert_eq!(tokens.flags.values.get("name"), Some(&Some("value".to_string())));
}

#[test]
fn server_stats_typo_suggests_stats_action() {
    let error = match parse(&strings(&["server", "stat"]), super::super::Surface::CmuxTui) {
        Err(error) => error,
        Ok(_) => panic!("unknown server action must be rejected"),
    };
    assert!(error.0.contains("Did you mean `stats`?"), "{error}");
}

#[test]
fn bounded_text_validation_has_shared_limits() {
    assert!(validate_bounded_text("--name", "ok").is_ok());
    assert!(validate_bounded_text("--name", "").is_err());
    assert!(validate_bounded_text("--name", &"x".repeat(129)).is_err());
    assert!(validate_bounded_text("--name", &"x".repeat(128)).is_ok());
}

fn protocol(values: &[&str]) -> RequestPlan {
    match parse(&strings(values), super::super::Surface::CmuxTui).unwrap() {
        CommandPlan::Protocol(plan) => *plan,
        _ => panic!("expected protocol plan"),
    }
}

#[test]
fn settings_crud_routes_to_daemon_operations() {
    let get = protocol(&["settings", "get", "appearance.theme"]);
    assert_eq!(operation(&get), "settings.get");
    assert_eq!(
        get.params,
        serde_json::json!({"key": "appearance.theme", "machine": "current", "session": "current"})
    );

    let set = protocol(&["settings", "set", "appearance.theme", "dark"]);
    assert_eq!(operation(&set), "settings.set");
    assert_eq!(
        set.params,
        serde_json::json!({"key": "appearance.theme", "value": "dark", "machine": "current", "session": "current"})
    );

    let reset = protocol(&["settings", "reset", "appearance.theme"]);
    assert_eq!(operation(&reset), "settings.reset");
    assert_eq!(
        reset.params,
        serde_json::json!({"key": "appearance.theme", "machine": "current", "session": "current"})
    );

    let unset = protocol(&["settings", "unset", "appearance.theme"]);
    assert_eq!(operation(&unset), "settings.reset");
    assert_eq!(
        unset.params,
        serde_json::json!({"key": "appearance.theme", "machine": "current", "session": "current"})
    );

    let negative = protocol(&["settings", "set", "custom.counter", "-1"]);
    assert_eq!(negative.params["value"], -1);

    let literal = protocol(&["settings", "set", "--", "custom.label", "--literal"]);
    assert_eq!(literal.params["key"], "custom.label");
    assert_eq!(literal.params["value"], "--literal");
}

/// `cmux config set on cloud` sets `chat.on` through the daemon, the route CRUD takes.
#[cfg(unix)]
#[test]
fn settings_crud_reads_a_key_alias_as_its_key() {
    assert!(super::super::daemon_settings_scope(&strings(&["config", "set", "on", "cloud"])));
    let set = protocol(&["config", "set", "on", "cloud"]);
    assert_eq!(operation(&set), "settings.set");
    assert_eq!(
        set.params,
        serde_json::json!({"key": "chat.on", "value": "cloud", "machine": "current", "session": "current"})
    );
    for verb in ["get", "reset", "unset"] {
        assert_eq!(protocol(&["settings", verb, "on"]).params["key"], "chat.on", "{verb}");
    }
}

#[test]
fn coding_agent_hook_management_stays_local() {
    let CommandPlan::AgentHooks(plan) = parse(
        &strings(&["agent", "hook", "install", "codex", "claude-code"]),
        super::super::Surface::CmuxTui,
    )
    .unwrap() else {
        panic!("expected local agent hook plan");
    };
    assert_eq!(plan.action, crate::agent_hook_install::Action::Install);
    assert_eq!(plan.providers, ["codex", "claude-code"]);
}

fn operation(plan: &RequestPlan) -> String {
    plan.operation.name().unwrap()
}

fn operation_catalog() -> Value {
    serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../spec/resource-operations-v2.json"
    )))
    .expect("canonical operation catalog")
}

fn assert_plan_matches_catalog(plan: &RequestPlan, expected: &str, catalog: &Value) {
    let descriptor = &catalog["operations"][expected];
    assert!(descriptor.is_object(), "catalog omitted {expected}");
    let params = plan.params.as_object().expect("CLI params object");
    let selectors = descriptor["params"]["selectors"].as_object().expect("catalog selectors");
    let fields = descriptor["params"]["fields"].as_object().expect("catalog fields");

    for key in params.keys() {
        assert!(
            selectors.contains_key(key) || fields.contains_key(key),
            "{expected} emitted forbidden catalog parameter {key:?}: {params:?}"
        );
    }
    for (key, requiredness) in selectors {
        if requiredness == "required" {
            assert!(
                params.contains_key(key),
                "{expected} omitted required selector {key:?}: {params:?}"
            );
        }
    }
    for (key, field) in fields {
        if field["required"] == true {
            assert!(
                params.contains_key(key),
                "{expected} omitted required field {key:?}: {params:?}"
            );
        }
    }
    if let Some(alternatives) = descriptor["params"]["one_of"].as_array() {
        assert!(
            alternatives.iter().any(|alternative| {
                alternative["required"].as_array().is_none_or(|required| {
                    required.iter().filter_map(Value::as_str).all(|key| params.contains_key(key))
                }) && alternative["forbidden"].as_array().is_none_or(|forbidden| {
                    forbidden.iter().filter_map(Value::as_str).all(|key| !params.contains_key(key))
                })
            }),
            "{expected} violates its catalog one_of: {params:?}"
        );
    }

    let class = match plan.operation.class() {
        OperationClass::Read => "read",
        OperationClass::Mutation => "mutation",
        OperationClass::StreamOpen => "stream_open",
        OperationClass::ConnectionControl => "connection_control",
        OperationClass::Local => "local",
    };
    assert_eq!(descriptor["class"], class, "{expected} class drift");
    assert_eq!(plan.stream, class == "stream_open", "{expected} stream drift");
}

#[test]
fn direct_and_nested_paths_share_operations_and_flat_ancestors() {
    let direct = protocol(&["pane", "pane_33333333333333333333333333333333", "show"]);
    let nested = protocol(&[
        "workspace",
        "ws_11111111111111111111111111111111",
        "screen",
        "screen_22222222222222222222222222222222",
        "pane",
        "pane_33333333333333333333333333333333",
        "show",
    ]);
    assert_eq!(operation(&direct), "pane.get");
    assert_eq!(operation(&nested), "pane.get");
    assert_eq!(
        direct.params,
        json!({
            "machine":"current",
            "session":"current",
            "pane":"pane_33333333333333333333333333333333"
        })
    );
    assert_eq!(
        nested.params,
        json!({
            "machine":"current",
            "session":"current",
            "workspace":"ws_11111111111111111111111111111111",
            "screen":"screen_22222222222222222222222222222222",
            "pane":"pane_33333333333333333333333333333333"
        })
    );
}

#[test]
fn name_and_current_targets_fill_a_contiguous_structural_context() {
    let named = protocol(&["terminal", "name:build", "show"]);
    assert_eq!(
        named.params,
        json!({
            "machine": "current",
            "session": "current",
            "workspace": "current",
            "screen": "current",
            "pane": "current",
            "tab": "current",
            "terminal": "name:build",
        })
    );
}

#[test]
fn workspace_creation_has_explicit_initial_content() {
    let terminal = protocol(&["workspace", "create"]);
    assert_eq!(terminal.params["initial_content"], "terminal");
    let empty = protocol(&["workspace", "create", "--empty"]);
    assert_eq!(empty.params["initial_content"], "empty");
}

/// Agents pass `--no-focus` out of habit (`cmux open`, other CLIs).
/// Creating a workspace never moves focus, so the flag is accepted and
/// changes nothing.
#[test]
fn workspace_create_accepts_no_focus_as_a_no_op() {
    let plain = protocol(&["workspace", "create", "--name", "w"]);
    let quiet = protocol(&["workspace", "create", "--no-focus", "--name", "w"]);
    assert_eq!(quiet.params, plain.params);
}

#[test]
fn creation_correlation_is_bounded_and_scoped() {
    let correlated = protocol(&["workspace", "create", "--correlation-key", "creation-attempt-1"]);
    assert_eq!(correlated.params["correlation_key"], "creation-attempt-1");

    assert!(
        parse(
            &strings(&["workspace", "create", "--correlation-key="]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&["workspace", "create", "--correlation-key", &"x".repeat(129),]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&["workspace", "list", "--correlation-key", "creation-attempt-1",]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&["session", "current", "creation", &"x".repeat(129), "resolve",]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
}

#[test]
fn terminal_screen_and_process_wait_are_distinct_paths() {
    const TERMINAL: &str = "term_00000000000000000000000000000008";
    const BROWSER: &str = "browser_00000000000000000000000000000009";
    let screen = protocol(&[
        "terminal",
        TERMINAL,
        "screen",
        "wait",
        "--pattern",
        "ready",
        "--timeout-ms",
        "5000",
    ]);
    assert_eq!(operation(&screen), "terminal.wait");
    assert_eq!(screen.params["timeout_ms"], "5000");

    let process = protocol(&["terminal", TERMINAL, "process", "wait", "--timeout-ms", "5000"]);
    assert_eq!(operation(&process), "terminal.wait_exit");
    assert_eq!(process.params["timeout_ms"], "5000");

    for invalid in ["-1", "01", "18446744073709551616"] {
        assert!(
            parse(
                &strings(&["terminal", TERMINAL, "process", "wait", "--timeout-ms", invalid,]),
                super::super::Surface::CmuxTui
            )
            .is_err(),
            "accepted noncanonical timeout {invalid:?}"
        );
    }

    assert!(
        parse(
            &strings(&["terminal", TERMINAL, "wait", "--pattern", "ready"]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    for unreachable in [
        vec!["terminal", TERMINAL, "viewer", "resize", "--cols", "80", "--rows", "24"],
        vec!["terminal", TERMINAL, "viewer", "release"],
        vec!["browser", BROWSER, "viewer", "resize", "--width-px", "800", "--height-px", "600"],
        vec!["browser", BROWSER, "viewer", "release"],
        vec!["stream", "stream_0000000000000000000000000000000a", "cancel"],
    ] {
        assert!(
            parse(&strings(&unreachable), super::super::Surface::CmuxTui).is_err(),
            "{unreachable:?}"
        );
    }
}

#[test]
fn cloud_rename_authority_validates_name_source_and_revision() {
    const TAB: &str = "tab_00000000000000000000000000000007";
    for source in ["user", "auto"] {
        for revision in ["0", "18446744073709551615"] {
            let plan = protocol(&[
                "tab",
                TAB,
                "rename",
                "--name",
                "logs",
                "--source",
                source,
                "--expected-generation",
                "daemon",
                "--expected-name-revision",
                revision,
            ]);
            assert_eq!(operation(&plan), "tab.rename");
            assert_eq!(plan.params["source"], source);
            assert_eq!(plan.params["expected_generation"], "daemon");
            assert_eq!(plan.params["expected_name_revision"], revision);
        }
    }

    for invalid in ["", "01", "-1", "+1", "18446744073709551616"] {
        let args = ["tab", TAB, "rename", "--name", "logs", "--expected-name-revision", invalid];
        assert!(
            parse(&strings(&args), super::super::Surface::CmuxTui).is_err(),
            "accepted invalid revision {invalid:?}"
        );
    }

    for invalid in ["", "process", "USER"] {
        let args = ["tab", TAB, "rename", "--name", "logs", "--source", invalid];
        assert!(
            parse(&strings(&args), super::super::Surface::CmuxTui).is_err(),
            "accepted invalid source {invalid:?}"
        );
    }
}

/// `notify --workspace ws_…` and `notification create|clear --workspace`
/// scope the row to that workspace (`workspace_id`), never the session.
#[test]
fn notify_workspace_sends_the_workspace_scope() {
    const WS: &str = "ws_00000000000000000000000000000042";
    const TERMINAL: &str = "term_00000000000000000000000000000041";
    let create = protocol(&["notify", "--workspace", WS, "--title", "x"]);
    assert_eq!(create.operation.name().unwrap(), "notification.create");
    assert_eq!(create.params["workspace_id"], WS);
    assert!(create.params.get("terminal_id").is_none());
    let clear = protocol(&["notify", "--clear", "--workspace", WS]);
    assert_eq!(clear.operation.name().unwrap(), "notification.clear");
    assert_eq!(clear.params["workspace_id"], WS);
    // `current` keeps its session-level meaning.
    let session = protocol(&["notify", "--clear", "--workspace", "current"]);
    assert!(session.params.get("workspace_id").is_none());
    let resource =
        protocol(&["notification", "create", "--title", "t", "--body", "", "--workspace", WS]);
    assert_eq!(resource.params["workspace_id"], WS);
    let resource_clear = protocol(&["notification", "clear", "--workspace", WS]);
    assert_eq!(resource_clear.params["workspace_id"], WS);
    for both in [
        &["notify", "--workspace", WS, "--surface", TERMINAL][..],
        &["notification", "clear", "--workspace", WS, "--terminal", TERMINAL],
    ] {
        assert!(
            parse(&strings(both), super::super::Surface::CmuxTui).is_err(),
            "{both:?}: a workspace and a terminal scope together"
        );
    }
}

/// `notification clear --notification <id>` clears that one row (the
/// notifications panel's Clear on a row); it is one scope, never two.
#[test]
fn notification_clear_takes_one_notification_id() {
    const NOTIFICATION: &str = "notification_00000000000000000000000000000041";
    const WS: &str = "ws_00000000000000000000000000000042";
    let clear = protocol(&["notification", "clear", "--notification", NOTIFICATION]);
    assert_eq!(clear.operation.name().unwrap(), "notification.clear");
    assert_eq!(clear.params["notification_id"], NOTIFICATION);
    assert!(clear.params.get("terminal_id").is_none());
    assert!(clear.params.get("workspace_id").is_none());
    for bad in [
        &["notification", "clear", "--notification", NOTIFICATION, "--workspace", WS][..],
        &["notification", "clear", "--notification", "ws_00000000000000000000000000000042"],
    ] {
        assert!(parse(&strings(bad), super::super::Surface::CmuxTui).is_err(), "{bad:?}");
    }
}

/// The machine `notify` accepts the macOS flag set, ignores the Mac-only ones, and validates `--desktop`.
#[test]
fn notify_matches_the_local_cmux_notify_signature() {
    const TERMINAL: &str = "term_00000000000000000000000000000041";
    let plain = protocol(&[
        "notify",
        "--title",
        "Build done",
        "--subtitle",
        "api",
        "--body",
        "ok",
        "--surface",
        TERMINAL,
        "--id-format",
        "both",
        "--window",
        "1",
    ]);
    assert_eq!(plain.operation.name().unwrap(), "notification.create");
    assert_eq!(plain.params["title"], "Build done");
    assert_eq!(plain.params["subtitle"], "api");
    assert_eq!(plain.params["body"], "ok");
    assert_eq!(plain.params["terminal_id"], TERMINAL);

    // Defaults match the local CLI: title "Notification", empty body.
    let defaults = protocol(&["notify", "--workspace", "current"]);
    assert_eq!(defaults.params["title"], "Notification");
    assert_eq!(defaults.params["body"], "");
    assert!(defaults.params.get("terminal_id").is_none(), "a workspace notify has no terminal");

    let clear = protocol(&["notify", "--clear", "--surface", TERMINAL]);
    assert_eq!(clear.operation.name().unwrap(), "notification.clear");
    assert_eq!(clear.params["terminal_id"], TERMINAL);
    let clear_all = protocol(&["notify", "--clear", "--workspace", "current"]);
    assert!(clear_all.params.get("terminal_id").is_none());
    let clear_ignores_desktop =
        protocol(&["notify", "--clear", "--surface", TERMINAL, "--desktop", "maybe"]);
    assert_eq!(clear_ignores_desktop.operation.name().unwrap(), "notification.clear");

    let reply = protocol(&["notify", "--workspace", "current", "--reply", "--title", "x"]);
    assert_eq!(reply.params["reply"], true, "a reply banner, for the caller's terminal only");
    let no_reply = protocol(&["notify", "--workspace", "current", "--title", "x"]);
    assert!(no_reply.params.get("reply").is_none());
    // `--desktop false` is a plain `desktop` field (the e2e test reads it
    // on the event), never classic's `effects` object.
    for parity in [
        &["notify", "--workspace", "current", "--desktop", "false"][..],
        &["notify", "--workspace", "current", "--desktop=true"][..],
    ] {
        let plan = protocol(parity);
        assert_eq!(plan.operation.name().unwrap(), "notification.create");
        assert!(plan.params.get("effects").is_none(), "{parity:?}");
    }
    match parse(
        &strings(&["notify", "--workspace", "current", "--desktop", "maybe"]),
        super::super::Surface::CmuxTui,
    ) {
        Err(error) => assert_eq!(
            error.to_string(),
            "--desktop must be true|false",
            "--desktop is validated like the local flag, with the local error text"
        ),
        Ok(_) => panic!("--desktop maybe was accepted"),
    }
    if std::env::var_os("CMUX_TUI_TERMINAL_ID").is_none() {
        assert!(
            parse(&strings(&["notify", "--clear"]), super::super::Surface::CmuxTui).is_err(),
            "no implicit whole-session clear"
        );
        assert!(
            parse(&strings(&["notify", "--surface", "current"]), super::super::Surface::CmuxTui)
                .is_err()
        );
    }
    assert!(parse(&strings(&["notify", "--title", ""]), super::super::Surface::CmuxTui).is_err());
    assert!(
        parse(&strings(&["notify", "--surface", "not-a-terminal"]), super::super::Surface::CmuxTui)
            .is_err(),
        "only this session's terminal ids"
    );
    assert!(parse(&strings(&["notify", "extra"]), super::super::Surface::CmuxTui).is_err());
    let long = "x".repeat(4097);
    assert!(parse(&strings(&["notify", "--body", &long]), super::super::Surface::CmuxTui).is_err());
}

#[test]
fn journal_subscribe_builds_replay_cursor_and_filter_contracts() {
    const SESSION: &str = "session_00000000000000000000000000000002";
    const WORKSPACE: &str = "ws_00000000000000000000000000000004";

    let replay = protocol(&[
        "session",
        SESSION,
        "journal",
        "subscribe",
        "--from",
        "beginning",
        "--kinds",
        "pane.*,tab.focus",
        "--classes",
        "state,effect",
        "--subjects",
        &format!("workspace:{WORKSPACE}"),
        "--max-sensitivity",
        "metadata",
        "--regex",
        "journal|resumed",
        "--regex-field",
        "payload",
        "--ignore-case",
    ]);
    assert_eq!(operation(&replay), "session.journal.subscribe");
    assert!(replay.stream);
    assert_eq!(replay.params["start"], "beginning");
    assert_eq!(replay.params["filter"]["kinds"], json!(["pane.*", "tab.focus"]));
    assert_eq!(replay.params["filter"]["classes"], json!(["state", "effect"]));
    assert_eq!(replay.params["filter"]["subjects"], json!([{"kind":"workspace","id":WORKSPACE}]));
    assert_eq!(replay.params["filter"]["max_sensitivity"], "metadata");
    assert_eq!(
        replay.params["filter"]["regex"],
        json!({
            "pattern":"journal|resumed",
            "field":"payload",
            "case_sensitive":false,
        })
    );

    let resumed = protocol(&[
        "session",
        SESSION,
        "journal",
        "subscribe",
        "--cursor-session",
        SESSION,
        "--sequence",
        "42",
    ]);
    assert_eq!(resumed.params["cursor"], json!({"generation":SESSION,"revision":"42"}));
    assert!(resumed.params.get("start").is_none());

    let read = protocol(&["session", SESSION, "journal", "read", "--kinds", "agent.*"]);
    assert_eq!(operation(&read), "session.journal.subscribe");
    assert_eq!(read.params["start"], "beginning");
    assert_eq!(read.params["follow"], false);
    assert_eq!(read.params["filter"]["kinds"], json!(["agent.*"]));

    let read_from_cursor = protocol(&[
        "session",
        SESSION,
        "journal",
        "read",
        "--cursor-session",
        SESSION,
        "--sequence",
        "42",
    ]);
    assert!(read_from_cursor.params.get("start").is_none());
    assert_eq!(read_from_cursor.params["follow"], false);

    for invalid in [
        vec!["--from", "beginning", "--cursor-session", SESSION, "--sequence", "1"],
        vec!["--cursor-session", SESSION],
        vec!["--kinds", "pane*"],
        vec!["--classes", "unknown"],
        vec!["--subjects", "workspace"],
        vec!["--max-sensitivity", "secret"],
        vec!["--regex-field", "payload"],
        vec!["--ignore-case"],
        vec!["--regex", "value", "--regex-field", "unknown"],
    ] {
        let mut args = vec!["session", SESSION, "journal", "subscribe"];
        args.extend(invalid);
        assert!(
            parse(&strings(&args), super::super::Surface::CmuxTui).is_err(),
            "accepted {args:?}"
        );
    }

    let manifest = r#"{"producer_id":"demo","namespace":"plugin.demo"}"#;
    let producer = protocol(&[
        "session",
        SESSION,
        "journal",
        "producer",
        "put",
        "--manifest-json",
        manifest,
        "--idempotency-key",
        "producer-put-1",
    ]);
    assert_eq!(operation(&producer), "session.journal.producer.put");
    assert_eq!(producer.params["manifest"]["producer_id"], "demo");
    assert_eq!(producer.idempotency_key.as_deref(), Some("producer-put-1"));

    let append = protocol(&[
        "session",
        SESSION,
        "journal",
        "append",
        "--event-json",
        r#"{"producer_id":"demo","payload":{"ready":true}}"#,
        "--idempotency-key",
        "append-1",
    ]);
    assert_eq!(operation(&append), "session.journal.append");
    assert_eq!(append.params["event"]["payload"]["ready"], true);

    let hooks = protocol(&["session", SESSION, "journal", "hook", "list"]);
    assert_eq!(operation(&hooks), "session.journal.hook.list");

    let hook = protocol(&[
        "session",
        SESSION,
        "journal",
        "hook",
        "put",
        "--manifest-json",
        r#"{"hook_id":"demo_hook","manifest_version":1}"#,
        "--idempotency-key",
        "hook-put-1",
    ]);
    assert_eq!(operation(&hook), "session.journal.hook.put");
    assert_eq!(hook.params["manifest"]["hook_id"], "demo_hook");
    assert_eq!(hook.idempotency_key.as_deref(), Some("hook-put-1"));

    let checkpoint = protocol(&[
        "session",
        SESSION,
        "journal",
        "checkpoint",
        "create",
        "--idempotency-key",
        "checkpoint-1",
    ]);
    assert_eq!(operation(&checkpoint), "session.journal.checkpoint.create");
    let checkpoints = protocol(&["session", SESSION, "journal", "checkpoint", "list"]);
    assert_eq!(operation(&checkpoints), "session.journal.checkpoint.list");

    let restore =
        protocol(&["session", SESSION, "journal", "restore", "preview", "--checkpoint", "latest"]);
    assert_eq!(operation(&restore), "session.journal.restore.preview");
    assert_eq!(restore.params["checkpoint"], "latest");

    let segments = protocol(&["session", SESSION, "journal", "segment", "list"]);
    assert_eq!(operation(&segments), "session.journal.segment.list");
    let seal = protocol(&[
        "session",
        SESSION,
        "journal",
        "segment",
        "seal",
        "--through",
        "42",
        "--idempotency-key",
        "segment-1",
    ]);
    assert_eq!(operation(&seal), "session.journal.segment.seal");
    assert_eq!(seal.params["through_sequence"], "42");
}

#[test]
fn agent_hook_emit_normalizes_and_preserves_the_native_payload() {
    const TERMINAL: &str = "term_00000000000000000000000000000008";
    let payload = r#"{"session_id":"native-session","message":"done","opaque":{"v":42}}"#;
    let first = protocol(&[
        "agent",
        "hook",
        "emit",
        "--source",
        "codex",
        "--event",
        "Stop",
        "--terminal",
        TERMINAL,
        "--payload-json",
        payload,
    ]);
    let second = protocol(&[
        "agent",
        "hook",
        "emit",
        "--source",
        "codex",
        "--event",
        "Stop",
        "--terminal",
        TERMINAL,
        "--payload-json",
        payload,
    ]);
    assert_eq!(operation(&first), "session.journal.append");
    assert_eq!(first.params["event"]["kind"], "agent.turn.completed");
    assert_eq!(first.params["event"]["payload"]["native"]["opaque"]["v"], 42);
    assert_eq!(
        first.params["event"]["payload"]["normalized"]["agent_session_id"],
        "native-session"
    );
    assert_eq!(first.params["event"]["subjects"][0]["id"], TERMINAL);
    assert_eq!(first.params["event"]["sensitivity"], "sensitive");
    for optional in ["occurred_at_ms", "causation_id", "correlation_id"] {
        assert!(
            first.params["event"].get(optional).is_none(),
            "absent optional field {optional} must not serialize as null"
        );
    }
    assert_eq!(first.idempotency_key, None);
    assert_eq!(second.idempotency_key, None);

    assert!(
        parse(
            &strings(&[
                "agent",
                "hook",
                "emit",
                "--source",
                "Invalid Source",
                "--event",
                "Stop",
                "--payload-json",
                "{}",
            ]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
}

#[test]
fn journal_append_inherits_scoped_hook_causation() {
    let mut event = json!({
        "producer_id":"demo",
        "subjects":[{"kind":"workspace","id":"ws_test"}],
        "payload":{},
    });
    apply_journal_hook_context(
        &mut event,
        Some("demo_hook"),
        Some("event_hook_started"),
        Some("demo_hook:1:event_source"),
    )
    .unwrap();
    assert_eq!(event["causation_id"], "event_hook_started");
    assert_eq!(event["correlation_id"], "demo_hook:1:event_source");
    assert_eq!(
        event["subjects"],
        json!([
            {"kind":"workspace","id":"ws_test"},
            {"kind":"hook","id":"demo_hook"},
        ])
    );
}

#[test]
fn run_never_infers_a_shell() {
    let direct = protocol(&["pane", "current", "run", "--", "printf", "%s", "a b"]);
    assert_eq!(direct.params["argv"], json!(["printf", "%s", "a b"]));
    assert!(direct.params.get("shell").is_none());

    let shell = protocol(&["pane", "current", "run", "shell", "printf 'ok'"]);
    assert_eq!(shell.params["shell"], "printf 'ok'");
    assert!(shell.params.get("argv").is_none());

    let empty_argument = protocol(&["pane", "current", "run", "--", "printf", ""]);
    assert_eq!(empty_argument.params["argv"], json!(["printf", ""]));
    assert!(
        parse(
            &strings(&["pane", "current", "run", "--", "", "argument"]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(&strings(&["pane", "current", "run", "echo ok"]), super::super::Surface::CmuxTui)
            .is_err()
    );
}

#[test]
fn run_on_exit_policy_is_validated_and_forwarded_verbatim() {
    for scope in [["workspace", "current"], ["pane", "current"]] {
        let kept = protocol(&[scope[0], scope[1], "run", "--on-exit", "keep", "--", "true"]);
        assert_eq!(kept.params["on_exit"], "keep");

        let closed = protocol(&[scope[0], scope[1], "run", "--on-exit", "close", "--", "true"]);
        assert_eq!(closed.params["on_exit"], "close");

        let default = protocol(&[scope[0], scope[1], "run", "--", "true"]);
        assert!(default.params.get("on_exit").is_none());

        let shell = protocol(&[scope[0], scope[1], "run", "--on-exit", "shell", "--", "true"]);
        assert_eq!(shell.params["on_exit"], "shell");
        assert!(
            parse(
                &strings(&[scope[0], scope[1], "run", "--on-exit", "sh", "--", "true"]),
                super::super::Surface::CmuxTui
            )
            .is_err()
        );
    }
}

#[test]
fn terminal_output_read_parses_cursor_and_bounded_window() {
    const TERMINAL: &str = "term_00000000000000000000000000000008";
    let plain = protocol(&["terminal", TERMINAL, "output", "read"]);
    assert!(plain.params.get("after").is_none());
    assert!(plain.params.get("max_bytes").is_none());

    let resumed = protocol(&[
        "terminal",
        TERMINAL,
        "output",
        "read",
        "--after",
        "4096",
        "--max-bytes",
        "65536",
    ]);
    assert_eq!(resumed.params["after"], "4096");
    assert_eq!(resumed.params["max_bytes"], 65536);

    assert!(
        parse(
            &strings(&["terminal", TERMINAL, "output", "read", "--after", "-1"]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&["terminal", TERMINAL, "output", "read", "--max-bytes", "0"]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&["terminal", TERMINAL, "output", "read", "--max-bytes", "4194305"]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
}

#[test]
fn input_commands_enforce_variant_constraints() {
    const TERMINAL: &str = "term_00000000000000000000000000000008";
    const BROWSER: &str = "browser_00000000000000000000000000000009";

    assert!(
        parse(
            &strings(&["terminal", TERMINAL, "mouse", "down", "--row", "1", "--column", "1",]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&[
                "terminal",
                TERMINAL,
                "mouse",
                "wheel",
                "--row",
                "1",
                "--column",
                "1",
                "--delta-rows",
                "0",
            ]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&[
                "terminal",
                TERMINAL,
                "mouse",
                "move",
                "--row",
                "1",
                "--column",
                "1",
                "--modifiers",
                "super",
            ]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    let meta = protocol(&[
        "terminal",
        TERMINAL,
        "mouse",
        "move",
        "--row",
        "1",
        "--column",
        "1",
        "--modifiers",
        "meta",
    ]);
    assert_eq!(meta.params["modifiers"], json!(["meta"]));

    assert!(
        parse(
            &strings(&[
                "browser", BROWSER, "mouse", "--kind", "down", "--x-px", "1", "--y-px", "1",
            ]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&[
                "browser", BROWSER, "mouse", "--kind", "move", "--x-px", "1", "--y-px", "1",
                "--button", "left",
            ]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&[
                "browser",
                BROWSER,
                "wheel",
                "--delta-x",
                "0",
                "--delta-y",
                "1",
                "--x-px",
                "1",
            ]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    assert!(
        parse(
            &strings(&[
                "browser", BROWSER, "mouse", "--kind", "move", "--x-px", "1", "--y-px", "1",
            ]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
    let guarded = protocol(&[
        "browser",
        BROWSER,
        "mouse",
        "--kind",
        "move",
        "--x-px",
        "1",
        "--y-px",
        "1",
        "--pointer-frame-seq",
        "18446744073709551615",
    ]);
    assert_eq!(guarded.params["pointer_frame_seq"], "18446744073709551615");
    assert!(
        parse(
            &strings(&[
                "browser",
                BROWSER,
                "wheel",
                "--delta-x",
                "0",
                "--delta-y",
                "1",
                "--x-px",
                "1",
                "--y-px",
                "1",
                "--pointer-frame-seq",
                "18446744073709551616",
            ]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
}

#[test]
fn idempotency_is_only_for_mutations() {
    let mutation = protocol(&["workspace", "create"]);
    assert_eq!(mutation.operation.class(), OperationClass::Mutation);
    let read = parse(
        &strings(&["workspace", "list", "--idempotency-key", "no"]),
        super::super::Surface::CmuxTui,
    );
    assert!(read.is_err());
}

#[test]
fn explicit_idempotency_keys_match_the_durable_identifier_contract() {
    for invalid in ["", " ", "\u{00a0}\u{3000}", "key\ncontrol", &"\u{00e9}".repeat(65)] {
        assert!(
            parse(
                &strings(&["workspace", "create", "--idempotency-key", invalid]),
                super::super::Surface::CmuxTui
            )
            .is_err(),
            "accepted invalid idempotency key {invalid:?}"
        );
    }
    for valid in [" key ", "\u{feff}", &"\u{00e9}".repeat(64)] {
        let plan = protocol(&["workspace", "create", "--idempotency-key", valid]);
        assert_eq!(plan.idempotency_key.as_deref(), Some(valid));
    }
}

#[test]
fn nullable_fields_have_explicit_clear_flags() {
    const CLIENT: &str = "client_00000000000000000000000000000003";
    const SESSION: &str = "session_00000000000000000000000000000002";

    let client = protocol(&["client", CLIENT, "metadata", "set", "--clear-name", "--clear-kind"]);
    assert_eq!(client.params["name"], Value::Null);
    assert_eq!(client.params["kind"], Value::Null);

    let defaults = protocol(&[
        "session",
        SESSION,
        "terminal",
        "defaults",
        "set",
        "--clear-foreground",
        "--clear-cursor-blink",
        "--clear-palette",
    ]);
    assert_eq!(defaults.params["foreground"], Value::Null);
    assert_eq!(defaults.params["cursor_blink"], Value::Null);
    assert_eq!(defaults.params["palette"], Value::Null);

    assert!(
        parse(
            &strings(&["client", CLIENT, "metadata", "set", "--name", "cli", "--clear-name",]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
}

#[test]
fn attach_allocates_a_typed_stream_id() {
    let attach = protocol(&["terminal", "term_55555555555555555555555555555555", "attach"]);
    assert!(attach.params["stream_id"].as_str().is_some_and(|value| value.starts_with("stream_")));
    assert!(attach.stream);
}

#[test]
fn wrong_resource_id_prefix_is_rejected_locally() {
    assert!(
        parse(
            &strings(&["workspace", "pane_33333333333333333333333333333333", "show",]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
}

#[test]
fn agent_commands_use_canonical_public_states() {
    const TERMINAL: &str = "term_55555555555555555555555555555555";
    // agent list --state takes the shared status words and maps them
    // (command/agent_list.rs tests); agent report takes the daemon state.
    for state in ["working", "blocked", "idle", "done", "unknown"] {
        let report = protocol(&[
            "agent",
            "report",
            "--terminal",
            TERMINAL,
            "--state",
            state,
            "--source",
            "socket",
        ]);
        assert_eq!(report.params["state"], state);
    }
    for noncanonical in ["running", "waiting", "error"] {
        assert!(
            parse(
                &strings(&[
                    "agent",
                    "report",
                    "--terminal",
                    TERMINAL,
                    "--state",
                    noncanonical,
                    "--source",
                    "socket",
                ]),
                super::super::Surface::CmuxTui
            )
            .is_err(),
            "accepted noncanonical agent state {noncanonical:?}"
        );
    }
}

#[test]
fn old_hyphenated_action_is_not_a_nested_selector() {
    assert!(
        parse(
            &strings(&["terminal", "term_55555555555555555555555555555555", "history-clear",]),
            super::super::Surface::CmuxTui
        )
        .is_err()
    );
}

/// W5-Q (lead decision on PR A findings 6-7): `done` is only a finished
/// turn nobody viewed. A session that ended is `ended` on the CLI: `agent
/// report --state ended` reports the daemon's `done`, and the report's
/// receipt says `ended` for it. The wire keeps its word.
#[test]
fn w5q_agent_report_says_ended_for_an_ended_session() {
    const TERMINAL: &str = "term_55555555555555555555555555555555";
    let report = protocol(&[
        "agent",
        "report",
        "--terminal",
        TERMINAL,
        "--state",
        "ended",
        "--source",
        "socket",
    ]);
    assert_eq!(report.params["state"], "done");
    let shown = report.view.project(serde_json::json!({
        "value": {"terminal_id": TERMINAL, "state": "done", "source": "socket"},
    }));
    assert_eq!(shown["value"]["state"], "ended", "{shown}");
    let working = report.view.project(serde_json::json!({"value": {"state": "working"}}));
    assert_eq!(working["value"]["state"], "working");
}

#[test]
fn sensitive_renderer_grant_has_no_public_path() {
    for scope in ["terminal", "tab", "client"] {
        let args = strings(&[scope, "renderer", "grant", "create"]);
        assert!(parse(&args, super::super::Surface::CmuxTui).is_err());
    }
    let raw = protocol(&[
        "raw",
        "operation",
        "terminal.renderer_grant.create",
        "--params-json",
        r#"{"machine":"current","session":"current","terminal":"term_00000000000000000000000000000001","ttl_ms":1000}"#,
    ]);
    assert_eq!(operation(&raw), "terminal.renderer_grant.create");
    assert_eq!(raw.operation.class(), OperationClass::ConnectionControl);
}

#[test]
fn every_local_catalog_operation_has_a_socket_free_path() {
    let cases = [
        (
            vec![
                "sidebar",
                "plugin",
                "install",
                "https://example.com/plugin.git",
                "--name",
                "custom",
                "--force",
            ],
            "sidebar_plugin.install",
        ),
        (vec!["sidebar", "plugin", "list"], "sidebar_plugin.list"),
        (vec!["sidebar", "plugin", "remove", "custom"], "sidebar_plugin.remove"),
        (vec!["sidebar", "plugin", "update", "custom"], "sidebar_plugin.update"),
        (vec!["sidebar", "plugin", "use", "custom"], "sidebar_plugin.use"),
        (vec!["sidebar", "plugin", "use", "--builtin"], "sidebar_plugin.use_builtin"),
    ];
    let mut seen = std::collections::BTreeSet::new();
    for (args, operation) in cases {
        let CommandPlan::Plugin(plan) =
            parse(&strings(&args), super::super::Surface::CmuxTui).unwrap()
        else {
            panic!("{operation} did not stay local");
        };
        assert!(!plan.positionals.is_empty());
        if operation == "sidebar_plugin.install" {
            assert_eq!(plan.name.as_deref(), Some("custom"));
            assert!(plan.force);
        }
        if operation == "sidebar_plugin.use_builtin" {
            assert!(plan.builtin);
        }
        seen.insert(operation);
    }
    let catalog = operation_catalog();
    let expected = catalog["local_operations"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(seen, expected);
}

#[test]
fn agent_plugin_management_stays_local_and_can_be_disabled() {
    let cases = [
        (vec!["agent", "plugin", "list"], false),
        (vec!["agent", "plugin", "install", "https://example.com/plugin.git"], false),
        (vec!["agent", "plugin", "use", "screen-detector"], false),
        (vec!["agent", "plugin", "update", "screen-detector"], false),
        (vec!["agent", "plugin", "remove", "screen-detector"], false),
        (vec!["agent", "plugin", "use", "--builtin"], true),
    ];
    for (args, builtin) in cases {
        let CommandPlan::Plugin(plan) =
            parse(&strings(&args), super::super::Surface::CmuxTui).unwrap()
        else {
            panic!("agent plugin command did not stay local: {args:?}");
        };
        assert_eq!(plan.kind, crate::plugin_manager::PluginKind::Agent);
        assert_eq!(plan.builtin, builtin);
    }
}

mod argv_tail_tests;
mod name_source_tests;
mod split_fit_tests;
mod split_focus_tests;
mod transport_path_coverage_tests;

fn record_covered_fields<'a>(
    plan: &RequestPlan,
    operation: &'a str,
    catalog: &Value,
    covered: &mut BTreeMap<&'a str, std::collections::BTreeSet<String>>,
) {
    let catalog_fields = catalog["operations"][operation]["params"]["fields"].as_object().unwrap();
    let entry = covered.entry(operation).or_default();
    for key in plan.params.as_object().unwrap().keys() {
        if catalog_fields.contains_key(key) {
            entry.insert(key.clone());
        }
    }
}
