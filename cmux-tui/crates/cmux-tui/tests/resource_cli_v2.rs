use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::PROTOCOL;
use serde_json::{Value, json};
use wait_timeout::ChildExt;

const WORKSPACE_ID: &str = "ws_11111111111111111111111111111111";
const OTHER_WORKSPACE_ID: &str = "ws_12121212121212121212121212121212";
const SCREEN_ID: &str = "screen_22222222222222222222222222222222";
const PANE_ID: &str = "pane_33333333333333333333333333333333";
const TAB_ID: &str = "tab_44444444444444444444444444444444";
const TERMINAL_ID: &str = "term_55555555555555555555555555555555";
const BROWSER_ID: &str = "browser_66666666666666666666666666666666";
static NEXT_TEMP_DIR: AtomicU64 = AtomicU64::new(0);

#[test]
fn root_help_is_noun_first_and_does_not_publish_the_old_flat_api() {
    let output = local_cli(&["--help"]);
    assert_success(&output);
    assert!(output.stderr.is_empty(), "help wrote diagnostics: {}", stderr(&output));

    let help = stdout(&output);
    assert!(help.starts_with("cmux - "), "{help}");
    assert!(!help.contains("cmux-tui"), "{help}");
    assert!(help.contains("cmux machine-agent [OPTIONS]"), "{help}");
    for scope in [
        "machine",
        "session",
        "client",
        "workspace",
        "screen",
        "pane",
        "tab",
        "terminal",
        "browser",
        "notification",
        "agent",
        "sidebar",
        "pairing",
        "projection",
        "provider",
        "raw",
    ] {
        assert!(help.lines().any(|line| line.trim_start().starts_with(scope)), "{scope}: {help}");
    }

    for removed in [
        "list-workspaces",
        "new-workspace",
        "new-pane-right",
        "read-screen",
        "clear-history",
        "focus-direction",
        "attach-surface",
        "sidebar-plugin",
    ] {
        assert!(!help.contains(removed), "root help still publishes {removed:?}:\n{help}");
    }
}

#[test]
fn every_public_scope_has_specific_help_instead_of_falling_back_to_root_help() {
    for (path, required) in [
        (&["machine"][..], &["list", "show", "session"][..]),
        (&["session"][..], &["show", "snapshot", "events", "ping"][..]),
        (&["client"][..], &["list", "show", "label", "detach", "sizing"][..]),
        (&["workspace"][..], &["list", "create", "show", "rename", "run"][..]),
        (&["screen"][..], &["list", "show", "create", "layout"][..]),
        (&["pane"][..], &["list", "show", "create", "split", "focus"][..]),
        (&["tab"][..], &["list", "show", "terminal", "browser"][..]),
        (&["terminal"][..], &["list", "show", "write", "keys", "history", "attach"][..]),
        (&["browser"][..], &["show", "navigate", "back", "forward", "attach"][..]),
        (&["notification"][..], &["list", "create"][..]),
        (&["agent"][..], &["list", "report"][..]),
        (&["sidebar"][..], &["view", "plugin"][..]),
        (&["pairing"][..], &["request"][..]),
        (&["projection"][..], &["show", "put"][..]),
        (&["provider"][..], &["authority"][..]),
        (&["raw"][..], &["operation"][..]),
    ] {
        let mut args = path.to_vec();
        args.push("--help");
        let output = local_cli(&args);
        assert_success(&output);
        assert!(output.stderr.is_empty(), "{path:?}: {}", stderr(&output));
        let help = stdout(&output);
        assert!(!help.contains("cmux-tui"), "{path:?}: {help}");
        for needle in required {
            assert!(help.contains(needle), "{path:?} help is missing {needle:?}:\n{help}");
        }
        assert!(
            help.contains(path.last().unwrap()),
            "{path:?} returned unrelated help instead of scope-specific help:\n{help}"
        );
    }
}

#[test]
fn usage_errors_use_the_public_command_name() {
    let output = local_cli(&["unknown-scope"]);
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    let diagnostic = stderr(&output);
    assert!(diagnostic.starts_with("cmux: "), "{diagnostic}");
    assert!(!diagnostic.contains("cmux-tui"), "{diagnostic}");
}

#[test]
fn startup_help_and_version_use_the_public_command_name() {
    let help = local_cli(&["help", "start"]);
    assert_success(&help);
    let help = stdout(&help);
    assert!(help.starts_with("cmux - "), "{help}");
    assert!(!help.contains("cmux-tui"), "{help}");

    let version = local_cli(&["--version"]);
    assert_success(&version);
    let version = stdout(&version);
    assert!(version.starts_with("cmux "), "{version}");
}

#[test]
fn nested_non_hyphenated_actions_have_specific_help() {
    for (path, required) in [
        (
            &["workspace", WORKSPACE_ID, "screen", "current", "pane", "current", "split"][..],
            &["right"][..],
        ),
        (&["terminal", TERMINAL_ID, "history", "clear"][..], &["clear"][..]),
        (&["terminal", TERMINAL_ID, "state", "read"][..], &["read"][..]),
        (&["pane", PANE_ID, "focus", "direction"][..], &["direction"][..]),
        (&["sidebar", "plugin"][..], &["list", "install", "use", "update", "remove"][..]),
        (&["sidebar", "view"][..], &["show", "ensure", "attach", "reload"][..]),
        (&["pairing", "request"][..], &["list", "respond"][..]),
    ] {
        let mut args = path.to_vec();
        args.push("--help");
        let output = local_cli(&args);
        assert_success(&output);
        assert!(output.stderr.is_empty(), "{path:?}: {}", stderr(&output));
        let help = stdout(&output);
        for needle in required {
            assert!(help.contains(needle), "{path:?} help is missing {needle:?}:\n{help}");
        }
    }
}

#[test]
fn old_action_first_commands_are_all_usage_errors() {
    let missing_socket = unique_temp_dir("removed-actions").join("missing.sock");
    for removed in [
        "identify",
        "ping",
        "set-client-info",
        "list-clients",
        "detach-client",
        "set-client-sizing",
        "reload-config",
        "set-window-title",
        "clear-window-title",
        "list-workspaces",
        "export-layout",
        "apply-layout",
        "send",
        "read-screen",
        "clear-history",
        "read-scrollback",
        "wait-for",
        "run",
        "send-key",
        "copy",
        "ids",
        "notify",
        "list-agents",
        "report-agent",
        "vt-state",
        "new-tab",
        "new-browser-tab",
        "new-workspace",
        "new-screen",
        "new-pane",
        "new-pane-right",
        "split",
        "set-ratio",
        "set-split-ratio",
        "set-viewport-pane-width",
        "undo-layout",
        "pane-neighbor",
        "focus-direction",
        "swap-pane",
        "zoom-pane",
        "process-info",
        "set-default-colors",
        "close-surface",
        "close-pane",
        "close-screen",
        "close-workspace",
        "rename-pane",
        "rename-surface",
        "rename-screen",
        "rename-workspace",
        "resize-surface",
        "release-surface-size",
        "focus-pane",
        "select-tab",
        "select-screen",
        "select-workspace",
        "move-tab",
        "move-workspace",
        "scroll-surface",
        "subscribe",
        "attach-surface",
        "plugin",
    ] {
        let output = Command::new(bin())
            .arg("--socket")
            .arg(&missing_socket)
            .arg(removed)
            .env_remove("CMUX_TUI_SOCKET")
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(2),
            "{removed:?} was not rejected as usage\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
        assert!(output.stdout.is_empty(), "{removed:?} wrote success output");
        assert!(!output.stderr.is_empty(), "{removed:?} omitted its usage diagnostic");
    }
}

#[test]
fn hyphenated_resource_actions_and_flat_auxiliary_scopes_are_usage_errors() {
    for args in [
        &["workspace", WORKSPACE_ID, "layout-apply"][..],
        &["terminal", TERMINAL_ID, "history-clear"][..],
        &["terminal", TERMINAL_ID, "state-read"][..],
        &["pane", PANE_ID, "focus-direction", "right"][..],
        &["sidebar-plugin", "list"][..],
        &["pairing-request", "list"][..],
        &["provider-scope", "list"][..],
        &["provider-action", "invoke"][..],
        &["provider-notice", "watch"][..],
    ] {
        let output = local_cli(args);
        assert_eq!(
            output.status.code(),
            Some(2),
            "{args:?} was not rejected as usage\nstdout:\n{}\nstderr:\n{}",
            stdout(&output),
            stderr(&output)
        );
        assert!(output.stdout.is_empty(), "{args:?} wrote success output");
        assert!(!output.stderr.is_empty(), "{args:?} omitted its usage diagnostic");
    }
}

#[cfg(unix)]
#[test]
fn direct_and_nested_resource_paths_address_the_same_typed_resources() {
    for case in [
        RequestCase::new(&["workspace", WORKSPACE_ID, "show"], "workspace.get", WORKSPACE_ID),
        RequestCase::new(&["screen", SCREEN_ID, "show"], "screen.get", SCREEN_ID),
        RequestCase::new(&["pane", PANE_ID, "show"], "pane.get", PANE_ID),
        RequestCase::new(&["tab", TAB_ID, "show"], "tab.get", TAB_ID),
        RequestCase::new(&["terminal", TERMINAL_ID, "show"], "terminal.get", TERMINAL_ID),
        RequestCase::new(&["browser", BROWSER_ID, "show"], "browser.get", BROWSER_ID),
        RequestCase::new(
            &["workspace", WORKSPACE_ID, "screen", SCREEN_ID, "show"],
            "screen.get",
            SCREEN_ID,
        ),
        RequestCase::new(
            &["workspace", WORKSPACE_ID, "screen", SCREEN_ID, "pane", PANE_ID, "show"],
            "pane.get",
            PANE_ID,
        ),
        RequestCase::new(
            &[
                "workspace",
                WORKSPACE_ID,
                "screen",
                SCREEN_ID,
                "pane",
                PANE_ID,
                "tab",
                TAB_ID,
                "show",
            ],
            "tab.get",
            TAB_ID,
        ),
    ] {
        let result = json!({"id": case.target});
        let (output, requests) = fake_resource_cli(case.args, FakeReply::Success(result.clone()));
        assert_success(&output);
        assert!(output.stderr.is_empty(), "{:?}: {}", case.args, stderr(&output));
        assert_eq!(parse_single_json(&output.stdout), result, "{:?}", case.args);
        assert_eq!(requests.len(), 1, "{:?}: {requests:?}", case.args);
        assert_eq!(requests[0]["operation"], case.operation, "{:?}", case.args);
        assert_json_contains_string(&requests[0]["params"], case.target);
        for ancestor in case.args.iter().copied().filter(|arg| is_resource_id(arg)) {
            assert_json_contains_string(&requests[0]["params"], ancestor);
        }
        assert_read_has_no_idempotency_key(&requests[0]);
    }
}

#[cfg(unix)]
#[test]
fn terminal_wait_timeouts_are_canonical_decimal_strings_on_the_wire() {
    for (args, operation, result) in [
        (
            &[
                "terminal",
                TERMINAL_ID,
                "screen",
                "wait",
                "--pattern",
                "ready",
                "--timeout-ms",
                "2000",
            ][..],
            "terminal.wait",
            json!({"matched": true, "text": "ready"}),
        ),
        (
            &["terminal", TERMINAL_ID, "process", "wait", "--timeout-ms", "2000"][..],
            "terminal.wait_exit",
            json!({
                "state": "pending",
                "terminal_id": TERMINAL_ID,
                "lifecycle": "running",
                "revision": "1"
            }),
        ),
    ] {
        let (output, requests) = fake_resource_cli(args, FakeReply::Success(result));
        assert_success(&output);
        assert!(output.stderr.is_empty(), "{args:?}: {}", stderr(&output));
        assert_eq!(requests.len(), 1, "{args:?}: {requests:?}");
        assert_eq!(requests[0]["operation"], operation, "{args:?}");
        assert_eq!(requests[0]["params"]["timeout_ms"], "2000", "{args:?}");
    }
}

#[cfg(unix)]
#[test]
fn workspace_creation_preserves_empty_whitespace_unicode_and_reserved_names() {
    for name in
        ["", " \t ", "日本語 🦀", "current", "under_score", "ws_99999999999999999999999999999999"]
    {
        let result = created_path();
        let (output, requests) =
            fake_resource_cli(&["workspace", "create", "--name", name], FakeReply::Success(result));
        assert_success(&output);
        assert!(output.stderr.is_empty(), "{name:?}: {}", stderr(&output));
        let printed = parse_single_json(&output.stdout);
        assert_eq!(printed["workspace"]["id"], WORKSPACE_ID, "{name:?}: {printed}");
        assert_eq!(printed["screen"]["id"], SCREEN_ID, "{name:?}: {printed}");
        assert_eq!(printed["pane"]["id"], PANE_ID, "{name:?}: {printed}");
        assert_eq!(printed["tab"]["id"], TAB_ID, "{name:?}: {printed}");
        assert_eq!(printed["terminal"]["id"], TERMINAL_ID, "{name:?}: {printed}");

        assert_eq!(requests.len(), 1, "{name:?}: {requests:?}");
        assert_eq!(requests[0]["operation"], "workspace.create", "{name:?}");
        assert_json_key_equals(&requests[0]["params"], "name", name);
        assert_mutation_has_idempotency_key(&requests[0]);
    }
}

#[cfg(unix)]
#[test]
fn forced_name_selectors_remain_distinct_from_current_and_opaque_ids() {
    for (selector, forced_name) in [
        ("name:", ""),
        ("name: \t ", " \t "),
        ("name:日本語 🦀", "日本語 🦀"),
        ("name:current", "current"),
        ("name:under_score", "under_score"),
        ("name:ws_99999999999999999999999999999999", "ws_99999999999999999999999999999999"),
    ] {
        let (output, requests) = fake_resource_cli(
            &["workspace", selector, "show"],
            FakeReply::Success(json!({"id": WORKSPACE_ID, "name": forced_name})),
        );
        assert_success(&output);
        assert_eq!(parse_single_json(&output.stdout)["name"], forced_name, "{selector:?}");
        assert_eq!(requests.len(), 1, "{selector:?}: {requests:?}");
        assert_eq!(requests[0]["operation"], "workspace.get", "{selector:?}");
        assert_forced_name_selector(&requests[0]["params"], forced_name);
    }

    let (_, current_requests) = fake_resource_cli(
        &["workspace", "current", "show"],
        FakeReply::Success(json!({"id": OTHER_WORKSPACE_ID})),
    );
    assert_eq!(current_requests.len(), 1);
    assert_current_selector(&current_requests[0]["params"]);
}

#[cfg(unix)]
#[test]
fn duplicate_name_ambiguity_is_structured_and_never_retried() {
    let error = json!({
        "code": "selector.ambiguous",
        "message": "more than one workspace is named \"api\"",
        "details": {"candidates": [WORKSPACE_ID, OTHER_WORKSPACE_ID]},
        "retryable": false
    });
    let (output, requests) = fake_resource_cli(
        &["workspace", "api", "rename", "--name", "changed"],
        FakeReply::Failure(error),
    );

    assert_eq!(
        output.status.code(),
        Some(1),
        "stdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert!(output.stdout.is_empty(), "operation failure wrote success output");
    let diagnostic = parse_single_json(&output.stderr);
    assert_eq!(find_key(&diagnostic, "code"), Some(&json!("selector.ambiguous")));
    assert_eq!(find_key(&diagnostic, "retryable"), Some(&json!(false)));
    let candidates = find_key(&diagnostic, "candidates")
        .and_then(Value::as_array)
        .expect("ambiguity diagnostic omitted candidate IDs");
    assert_eq!(candidates, &vec![json!(WORKSPACE_ID), json!(OTHER_WORKSPACE_ID)]);

    assert_eq!(requests.len(), 1, "ambiguous mutation was retried: {requests:?}");
    assert_eq!(requests[0]["operation"], "workspace.rename");
    assert_json_contains_string(&requests[0]["params"], "api");
    assert_json_key_equals(&requests[0]["params"], "name", "changed");
    assert_mutation_has_idempotency_key(&requests[0]);
}

#[cfg(unix)]
#[test]
fn indeterminate_mutation_is_preserved_exactly_and_never_retried() {
    let error = json!({
        "code": "mutation.indeterminate",
        "message": "the workspace may have been created before the connection closed",
        "details": {
            "idempotency_key": "create-workspace-1",
            "operation": "workspace.create",
            "recovery": "inspect_state_then_retry_with_new_key"
        },
        "retryable": false
    });
    let (output, requests) = fake_resource_cli(
        &[
            "workspace",
            "create",
            "--name",
            "maybe-created",
            "--idempotency-key",
            "create-workspace-1",
        ],
        FakeReply::Failure(error.clone()),
    );

    assert_eq!(
        output.status.code(),
        Some(1),
        "stdout:\n{}\nstderr:\n{}",
        stdout(&output),
        stderr(&output)
    );
    assert!(output.stdout.is_empty(), "indeterminate mutation wrote success output");
    assert_eq!(parse_single_json(&output.stderr), error);
    assert_eq!(requests.len(), 1, "indeterminate mutation was retried: {requests:?}");
    assert_eq!(requests[0]["operation"], "workspace.create");
    assert_eq!(requests[0]["idempotency_key"], "create-workspace-1");
}

#[cfg(unix)]
#[test]
fn output_modes_keep_success_on_stdout_and_diagnostics_on_stderr() {
    let result = json!({
        "workspaces": [
            {"id": WORKSPACE_ID, "name": "one"},
            {"id": OTHER_WORKSPACE_ID, "name": "two"}
        ]
    });

    let (human_output, _) =
        fake_resource_cli_with_mode("", &["workspace", "list"], FakeReply::Success(result.clone()));
    assert_success(&human_output);
    assert!(human_output.stderr.is_empty());
    let human = stdout(&human_output);
    assert!(human.starts_with("ID"), "{human}");
    assert!(human.contains("NAME"), "{human}");
    assert!(human.contains(WORKSPACE_ID), "{human}");
    assert!(human.contains(OTHER_WORKSPACE_ID), "{human}");
    assert!(!human.contains(['{', '}', '"']), "{human}");

    let (json_output, _) =
        fake_resource_cli(&["workspace", "list"], FakeReply::Success(result.clone()));
    assert_success(&json_output);
    assert_eq!(parse_single_json(&json_output.stdout), result);
    assert!(json_output.stderr.is_empty());

    let (jsonl_output, _) =
        fake_resource_cli_with_mode("--jsonl", &["workspace", "list"], FakeReply::Success(result));
    assert_success(&jsonl_output);
    assert!(jsonl_output.stderr.is_empty());
    let lines = stdout(&jsonl_output)
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).expect("JSONL emitted invalid JSON"))
        .collect::<Vec<_>>();
    assert_eq!(
        lines,
        vec![
            json!({"id": WORKSPACE_ID, "name": "one"}),
            json!({"id": OTHER_WORKSPACE_ID, "name": "two"})
        ]
    );

    let (quiet_output, requests) = fake_resource_cli_with_mode(
        "--quiet",
        &["workspace", WORKSPACE_ID, "rename", "--name", "renamed"],
        FakeReply::Success(json!({"id": WORKSPACE_ID, "name": "renamed"})),
    );
    assert_success(&quiet_output);
    assert!(quiet_output.stdout.is_empty(), "quiet mode wrote success output");
    assert!(quiet_output.stderr.is_empty(), "quiet mode wrote diagnostics");
    assert_eq!(requests.len(), 1);
    assert_mutation_has_idempotency_key(&requests[0]);
}

#[cfg(unix)]
#[test]
fn stream_commands_validate_and_print_typed_stream_envelopes() {
    let dir = unique_temp_dir("stream");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("control.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let read_half = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(read_half);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        let request_id = request["id"].clone();
        let stream_id = request["params"]["stream_id"].clone();
        for envelope in [
            json!({
                "protocol": "cmux.protocol/2",
                "type": "response",
                "id": request_id,
                "ok": true,
                "result": {"stream_id": stream_id}
            }),
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_item",
                "stream_id": stream_id,
                "sequence": "0",
                "item": {"kind": "output", "text": "ready"}
            }),
            json!({
                "protocol": "cmux.protocol/2",
                "type": "stream_end",
                "stream_id": stream_id,
                "reason": "completed"
            }),
        ] {
            writeln!(stream, "{envelope}").unwrap();
        }
        stream.flush().unwrap();
        request
    });

    let output = Command::new(bin())
        .args(["--jsonl", "--socket"])
        .arg(&socket)
        .args(["terminal", TERMINAL_ID, "attach"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let request = server.join().unwrap();
    assert_success(&output);
    assert!(output.stderr.is_empty(), "{}", stderr(&output));
    assert_eq!(request["operation"], "terminal.attach");
    let item = parse_single_json(&output.stdout);
    assert_eq!(item["type"], "stream_item");
    assert_eq!(item["item"]["text"], "ready");
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn raw_command_sends_the_exact_private_request_object() {
    let dir = unique_temp_dir("raw-command");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("control.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let read_half = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(read_half);
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        writeln!(stream, "{}", json!({"id": "raw-1", "ok": true, "data": {"pong": true}})).unwrap();
        stream.flush().unwrap();
        request
    });

    let output = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&socket)
        .args([
            "raw",
            "command",
            "--request-json",
            r#"{"id":"raw-1","cmd":"private.ping","opaque":{"x":true}}"#,
        ])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let request = server.join().unwrap();
    assert_success(&output);
    assert_eq!(request, json!({"id":"raw-1","cmd":"private.ping","opaque":{"x":true}}));
    assert_eq!(parse_single_json(&output.stdout), json!({"pong": true}));
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn local_plugin_jsonl_never_connects_to_the_session_socket() {
    let dir = unique_temp_dir("plugin-list");
    let data = dir.join("data");
    let config = dir.join("config");
    let plugins = data.join("cmux").join("mux-plugins");
    fs::create_dir_all(plugins.join(".registry")).unwrap();
    for (name, id) in [
        ("alpha", "sidebar_plugin_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        ("beta", "sidebar_plugin_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
        (
            "sidebar_plugin_cccccccccccccccccccccccccccccccc",
            "sidebar_plugin_dddddddddddddddddddddddddddddddd",
        ),
    ] {
        let plugin = plugins.join(name);
        fs::create_dir_all(plugin.join("bin")).unwrap();
        fs::write(
            plugins.join(".registry").join(format!("{name}.json")),
            format!("{{\"id\":\"{id}\"}}\n"),
        )
        .unwrap();
        fs::write(
            plugin.join("cmux-plugin.toml"),
            format!(
                "[plugin]\nname = \"{name}\"\nkind = \"sidebar\"\n\n[run]\ncommand = [\"bin/sidebar\"]\n"
            ),
        )
        .unwrap();
        let executable = plugin.join("bin").join("sidebar");
        fs::write(&executable, "#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }
    let output = Command::new(bin())
        .args(["--jsonl", "--socket"])
        .arg(dir.join("missing.sock"))
        .args(["sidebar", "plugin", "list"])
        .env("XDG_DATA_HOME", &data)
        .env("XDG_CONFIG_HOME", &config)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&output);
    assert!(output.stderr.is_empty(), "{}", stderr(&output));
    let snapshots = stdout(&output)
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    let names = snapshots
        .iter()
        .map(|snapshot| snapshot["name"].as_str().unwrap().to_owned())
        .collect::<Vec<_>>();
    assert_eq!(names, ["alpha", "beta", "sidebar_plugin_cccccccccccccccccccccccccccccccc"]);
    for snapshot in &snapshots {
        let id = snapshot["id"].as_str().unwrap();
        assert!(id.starts_with("sidebar_plugin_"));
        assert_eq!(id.len(), "sidebar_plugin_".len() + 32);
        assert_eq!(snapshot["active"], false);
        assert_eq!(snapshot["enabled"], true);
        let keys = snapshot.as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>();
        assert_eq!(keys, ["active", "enabled", "extra", "id", "name", "source"]);
    }
    assert_ne!(snapshots[0]["id"], snapshots[1]["id"]);

    let alpha_id = snapshots[0]["id"].as_str().unwrap();
    let selected = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(dir.join("missing.sock"))
        .args(["sidebar", "plugin", "use", alpha_id])
        .env("XDG_DATA_HOME", &data)
        .env("XDG_CONFIG_HOME", &config)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&selected);
    let selected = parse_single_json(&selected.stdout);
    assert_eq!(selected["plugin"]["id"], alpha_id);
    assert_eq!(selected["plugin"]["name"], "alpha");
    assert_eq!(selected["plugin"]["active"], true);

    let forced_name = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(dir.join("missing.sock"))
        .args(["sidebar", "plugin", "use", "name:sidebar_plugin_cccccccccccccccccccccccccccccccc"])
        .env("XDG_DATA_HOME", &data)
        .env("XDG_CONFIG_HOME", &config)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&forced_name);
    let forced_name = parse_single_json(&forced_name.stdout);
    assert_eq!(forced_name["plugin"]["id"], "sidebar_plugin_dddddddddddddddddddddddddddddddd");
    assert_eq!(forced_name["plugin"]["name"], "sidebar_plugin_cccccccccccccccccccccccccccccccc");
    assert_eq!(forced_name["plugin"]["active"], true);

    let builtin = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(dir.join("missing.sock"))
        .args(["sidebar", "plugin", "use", "--builtin"])
        .env("XDG_DATA_HOME", &data)
        .env("XDG_CONFIG_HOME", &config)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&builtin);
    assert!(
        parse_single_json(&builtin.stdout)["plugins"]
            .as_array()
            .unwrap()
            .iter()
            .all(|snapshot| snapshot["active"] == false && snapshot["enabled"] == true)
    );

    let beta_id = snapshots[1]["id"].as_str().unwrap();
    let removed = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(dir.join("missing.sock"))
        .args(["sidebar", "plugin", "remove", beta_id])
        .env("XDG_DATA_HOME", &data)
        .env("XDG_CONFIG_HOME", &config)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_success(&removed);
    let removed = parse_single_json(&removed.stdout);
    assert_eq!(removed["plugin"]["id"], beta_id);
    assert_eq!(removed["plugin"]["active"], false);
    assert_eq!(removed["plugin"]["enabled"], false);

    let invalid = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(dir.join("missing.sock"))
        .args(["sidebar", "plugin", "use", "Bad"])
        .env("XDG_DATA_HOME", &data)
        .env("XDG_CONFIG_HOME", &config)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(invalid.status.code(), Some(1));
    assert!(invalid.stdout.is_empty());
    let invalid = parse_single_json(&invalid.stderr);
    assert_eq!(invalid["code"], "validation.invalid");
    assert_eq!(invalid["retryable"], false);
    assert_eq!(invalid["details"]["field"], "sidebar_plugin");
    assert!(invalid["details"]["reason"].is_string());
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn usage_and_transport_failures_use_distinct_exit_codes_and_stderr() {
    let usage = local_cli(&["workspace", WORKSPACE_ID, "definitely-not-an-action"]);
    assert_eq!(usage.status.code(), Some(2));
    assert!(usage.stdout.is_empty());
    assert!(!usage.stderr.is_empty());

    let missing_socket = unique_temp_dir("transport-exit").join("missing.sock");
    let wrong_stream_mode = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&missing_socket)
        .args(["terminal", TERMINAL_ID, "attach"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(wrong_stream_mode.status.code(), Some(2));
    assert!(wrong_stream_mode.stdout.is_empty());
    assert!(stderr(&wrong_stream_mode).contains("--jsonl"));

    let transport = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&missing_socket)
        .args(["workspace", "list"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    assert_eq!(
        transport.status.code(),
        Some(3),
        "stdout:\n{}\nstderr:\n{}",
        stdout(&transport),
        stderr(&transport)
    );
    assert!(transport.stdout.is_empty());
    assert!(!transport.stderr.is_empty());
}

#[cfg(unix)]
#[test]
fn journal_subscription_rejects_a_stale_session_before_sending_the_new_envelope() {
    let dir = unique_temp_dir("journal-stale-session");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
        let read_half = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(read_half);
        let mut requests = Vec::new();
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap() != 0 {
            let request: Value = serde_json::from_str(&line).unwrap();
            requests.push(request.clone());
            let response = if request.get("cmd").and_then(Value::as_str) == Some("identify") {
                json!({
                    "id":request["id"],
                    "ok":true,
                    "data":{
                        "app":"cmux-tui",
                        "protocol":10,
                        "capabilities":["workspace-registry-v1"],
                        "session":"journal-v1"
                    }
                })
            } else {
                json!({
                    "protocol":"cmux.protocol/1",
                    "type":"response",
                    "id":request["id"],
                    "ok":false,
                    "error":{
                        "code":"validation.invalid",
                        "message":"invalid request envelope",
                        "details":{"reason":"invalid request envelope"},
                        "retryable":false
                    }
                })
            };
            writeln!(stream, "{response}").unwrap();
            stream.flush().unwrap();
        }
        line.clear();
        if reader.read_line(&mut line).is_ok() && !line.is_empty() {
            requests.push(serde_json::from_str(&line).unwrap());
        }
        requests
    });

    let output = Command::new(bin())
        .args(["--jsonl", "--socket"])
        .arg(&socket)
        .args(["session", "current", "journal", "subscribe"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let requests = server.join().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let error = parse_single_json(&output.stderr);
    assert_eq!(error["code"], "operation.unsupported");
    assert_eq!(error["details"]["capability"], "session-journal-v1");
    assert!(error["details"].get("session").is_none());
    assert_eq!(requests.len(), 1, "new request reached a stale server: {requests:?}");
    assert_eq!(requests[0]["cmd"], "identify");
    let _ = fs::remove_file(&socket);
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn pre_ready_resource_reload_uses_selected_locale() {
    let dir = unique_temp_dir("pre-ready-reload-locale");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone_box().unwrap()).read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["operation"], "session.reload_config");
        let response = json!({
            "protocol":PROTOCOL,
            "type":"response",
            "id":request["id"],
            "ok":false,
            "error":{
                "code":"operation.failed",
                "message":"server lifecycle is not ready",
                "details":{
                    "operation":"session.reload_config",
                    "reason":"lifecycle_not_ready"
                },
                "retryable":false
            }
        });
        writeln!(stream, "{response}").unwrap();
        stream.flush().unwrap();
    });

    let output = Command::new(bin())
        .args(["--socket"])
        .arg(&socket)
        .args(["session", "current", "config", "reload"])
        .env("LC_ALL", "ja_JP.UTF-8")
        .env("LC_MESSAGES", "ja_JP.UTF-8")
        .env("LANG", "ja_JP.UTF-8")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    server.join().unwrap();
    assert_eq!(output.status.code(), Some(1));
    let diagnostic = stderr(&output);
    assert!(diagnostic.contains("ローカルサーバーは起動中です"), "{diagnostic}");
    assert!(!diagnostic.contains("server lifecycle is not ready"), "{diagnostic}");
    let _ = fs::remove_file(&socket);
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn pre_ready_resource_reload_json_preserves_server_message() {
    let dir = unique_temp_dir("pre-ready-reload-json");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone_box().unwrap()).read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["operation"], "session.reload_config");
        let response = json!({
            "protocol":PROTOCOL,
            "type":"response",
            "id":request["id"],
            "ok":false,
            "error":{
                "code":"operation.failed",
                "message":"server lifecycle is not ready",
                "details":{
                    "operation":"session.reload_config",
                    "reason":"lifecycle_not_ready"
                },
                "retryable":false
            }
        });
        writeln!(stream, "{response}").unwrap();
        stream.flush().unwrap();
    });

    let output = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["session", "current", "config", "reload"])
        .env("LC_ALL", "ja_JP.UTF-8")
        .env("LC_MESSAGES", "ja_JP.UTF-8")
        .env("LANG", "ja_JP.UTF-8")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    server.join().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let error = parse_single_json(&output.stderr);
    assert_eq!(error["code"], "operation.failed");
    assert_eq!(error["message"], "server lifecycle is not ready");
    assert_eq!(error["details"]["reason"], "lifecycle_not_ready");
    assert_eq!(error["retryable"], false);
    let _ = fs::remove_file(&socket);
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn journal_subscription_negotiates_then_sends_the_resource_envelope() {
    let dir = unique_temp_dir("journal-capable-session");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let read_half = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(read_half);
        let mut requests = Vec::new();

        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let identify: Value = serde_json::from_str(&line).unwrap();
        requests.push(identify.clone());
        writeln!(
            stream,
            "{}",
            json!({
                "id":identify["id"],
                "ok":true,
                "data":{
                    "app":"cmux-tui",
                    "protocol":10,
                    "capabilities":["session-journal-v1"],
                    "session":"journal-capable"
                }
            })
        )
        .unwrap();
        stream.flush().unwrap();

        line.clear();
        reader.read_line(&mut line).unwrap();
        let subscribe: Value = serde_json::from_str(&line).unwrap();
        requests.push(subscribe.clone());
        let stream_id = subscribe["params"]["stream_id"].clone();
        for envelope in [
            json!({
                "protocol":"cmux.protocol/2",
                "type":"response",
                "id":subscribe["id"],
                "ok":true,
                "result":{"stream_id":stream_id}
            }),
            json!({
                "protocol":"cmux.protocol/2",
                "type":"stream_end",
                "stream_id":stream_id,
                "reason":"completed"
            }),
        ] {
            writeln!(stream, "{envelope}").unwrap();
        }
        stream.flush().unwrap();
        requests
    });

    let output = Command::new(bin())
        .args(["--session", "journal-capable", "--jsonl", "--socket"])
        .arg(&socket)
        .args(["session", "current", "journal", "subscribe"])
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let requests = server.join().unwrap();
    assert_success(&output);
    assert!(output.stderr.is_empty(), "{}", stderr(&output));
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0]["cmd"], "identify");
    assert_eq!(requests[1]["operation"], "session.journal.subscribe");
    assert_eq!(requests[1]["params"]["session"], "journal-capable");
    let lifecycle = stdout(&output)
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    assert_eq!(lifecycle.len(), 2);
    assert_eq!(lifecycle[0]["type"], "response");
    assert_eq!(lifecycle[1]["type"], "stream_end");
    let _ = fs::remove_file(&socket);
    fs::remove_dir_all(dir).unwrap();
}

#[cfg(unix)]
#[test]
fn journal_subscription_sigint_exits_immediately_and_cleanly() {
    let dir = unique_temp_dir("journal-subscribe-sigint");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        let read_half = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(read_half);

        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let identify: Value = serde_json::from_str(&line).unwrap();
        writeln!(
            stream,
            "{}",
            json!({
                "id":identify["id"],
                "ok":true,
                "data":{
                    "app":"cmux-tui",
                    "protocol":10,
                    "capabilities":["session-journal-v1"],
                    "session":"journal-sigint"
                }
            })
        )
        .unwrap();
        stream.flush().unwrap();

        line.clear();
        reader.read_line(&mut line).unwrap();
        let subscribe: Value = serde_json::from_str(&line).unwrap();
        writeln!(
            stream,
            "{}",
            json!({
                "protocol":"cmux.protocol/2",
                "type":"response",
                "id":subscribe["id"],
                "ok":true,
                "result":{"stream_id":subscribe["params"]["stream_id"]}
            })
        )
        .unwrap();
        stream.flush().unwrap();

        line.clear();
        let _ = reader.read_line(&mut line);
    });

    let mut child = Command::new(bin())
        .args(["--jsonl", "--socket"])
        .arg(&socket)
        .args(["session", "current", "journal", "subscribe"])
        .env_remove("CMUX_TUI_SOCKET")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut accepted = String::new();
    stdout.read_line(&mut accepted).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&accepted).unwrap()["type"], "response");

    let started = Instant::now();
    let pid = libc::pid_t::try_from(child.id()).unwrap();
    assert_eq!(unsafe { libc::kill(pid, libc::SIGINT) }, 0);
    let status = child.wait_timeout(Duration::from_millis(100)).unwrap().unwrap_or_else(|| {
        let _ = child.kill();
        let _ = child.wait();
        panic!("journal subscriber did not exit within 100 ms of SIGINT");
    });
    let elapsed = started.elapsed();
    let mut stderr = String::new();
    child.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
    assert!(status.success(), "SIGINT exit was {status:?}: {stderr}");
    assert!(stderr.is_empty(), "SIGINT wrote a transport error: {stderr}");
    assert!(elapsed < Duration::from_millis(100), "SIGINT exit took {elapsed:?}");

    server.join().unwrap();
    let _ = fs::remove_file(&socket);
    fs::remove_dir_all(dir).unwrap();
}

struct RequestCase {
    args: &'static [&'static str],
    operation: &'static str,
    target: &'static str,
}

impl RequestCase {
    const fn new(
        args: &'static [&'static str],
        operation: &'static str,
        target: &'static str,
    ) -> Self {
        Self { args, operation, target }
    }
}

#[derive(Clone)]
enum FakeReply {
    Success(Value),
    Failure(Value),
}

#[cfg(unix)]
fn fake_resource_cli(args: &[&str], reply: FakeReply) -> (Output, Vec<Value>) {
    fake_resource_cli_with_mode("--json", args, reply)
}

#[cfg(unix)]
fn fake_resource_cli_with_mode(
    mode: &str,
    args: &[&str],
    reply: FakeReply,
) -> (Output, Vec<Value>) {
    let dir = unique_temp_dir("resource-fake");
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let mut stream = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let read_half = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(read_half);
        let mut requests = Vec::new();
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap() != 0 {
            let request: Value = serde_json::from_str(&line).expect("CLI sent invalid JSON");
            let id = request["id"].clone();
            let response = match reply {
                FakeReply::Success(result) => json!({
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": id,
                    "ok": true,
                    "result": result
                }),
                FakeReply::Failure(error) => json!({
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": id,
                    "ok": false,
                    "error": error
                }),
            };
            requests.push(request);
            writeln!(stream, "{response}").unwrap();
            stream.flush().unwrap();
        }
        requests
    });

    let mut command = Command::new(bin());
    if !mode.is_empty() {
        command.arg(mode);
    }
    let output = command
        .arg("--socket")
        .arg(&socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    let requests = server.join().unwrap();
    let _ = fs::remove_file(&socket);
    fs::remove_dir_all(dir).unwrap();
    (output, requests)
}

fn created_path() -> Value {
    json!({
        "workspace": {"id": WORKSPACE_ID, "name": ""},
        "screen": {"id": SCREEN_ID},
        "pane": {"id": PANE_ID},
        "tab": {"id": TAB_ID},
        "terminal": {"id": TERMINAL_ID}
    })
}

fn assert_read_has_no_idempotency_key(request: &Value) {
    assert!(
        find_key(request, "idempotency_key").is_none(),
        "read unexpectedly carried an idempotency key: {request}"
    );
}

fn assert_mutation_has_idempotency_key(request: &Value) {
    let key = find_key(request, "idempotency_key")
        .and_then(Value::as_str)
        .expect("mutation omitted its idempotency key");
    assert!(!key.is_empty(), "mutation used an empty idempotency key");
}

fn assert_forced_name_selector(params: &Value, name: &str) {
    assert!(
        json_contains_string(params, &format!("name:{name}")),
        "forced name selector was not encoded as a name selector: {params}"
    );
}

fn assert_current_selector(params: &Value) {
    assert!(
        json_contains_string(params, "current"),
        "current selector was not encoded as current: {params}"
    );
}

fn assert_json_key_equals(value: &Value, key: &str, expected: &str) {
    assert!(
        json_has_key_value(value, key, &Value::String(expected.to_owned())),
        "{key:?} did not preserve {expected:?}: {value}"
    );
}

fn assert_json_contains_string(value: &Value, expected: &str) {
    assert!(json_contains_string(value, expected), "JSON omitted string {expected:?}: {value}");
}

fn json_contains_string(value: &Value, expected: &str) -> bool {
    match value {
        Value::String(actual) => actual == expected,
        Value::Array(values) => values.iter().any(|value| json_contains_string(value, expected)),
        Value::Object(values) => values.values().any(|value| json_contains_string(value, expected)),
        Value::Null | Value::Bool(_) | Value::Number(_) => false,
    }
}

fn json_has_key_value(value: &Value, key: &str, expected: &Value) -> bool {
    match value {
        Value::Array(values) => values.iter().any(|value| json_has_key_value(value, key, expected)),
        Value::Object(values) => {
            values.get(key) == Some(expected)
                || values.values().any(|value| json_has_key_value(value, key, expected))
        }
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => false,
    }
}

fn find_key<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Array(values) => values.iter().find_map(|value| find_key(value, key)),
        Value::Object(values) => {
            values.get(key).or_else(|| values.values().find_map(|value| find_key(value, key)))
        }
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => None,
    }
}

fn is_resource_id(value: &str) -> bool {
    ["ws_", "screen_", "pane_", "tab_", "term_", "browser_", "client_", "session_", "machine_"]
        .iter()
        .any(|prefix| value.starts_with(prefix))
}

fn parse_single_json(bytes: &[u8]) -> Value {
    serde_json::from_slice(bytes).unwrap_or_else(|error| {
        panic!("expected one JSON value, got {error}: {:?}", String::from_utf8_lossy(bytes))
    })
}

fn local_cli(args: &[&str]) -> Output {
    Command::new(bin()).args(args).env_remove("CMUX_TUI_SOCKET").output().unwrap()
}

fn assert_success(output: &Output) {
    assert!(
        output.status.success(),
        "expected success, got {:?}\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        stdout(output),
        stderr(output)
    );
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn unique_temp_dir(name: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let sequence = NEXT_TEMP_DIR.fetch_add(1, Ordering::Relaxed);
    Path::new("/tmp")
        .join(format!("cmux-resource-cli-{name}-{}-{stamp}-{sequence}", std::process::id()))
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}
