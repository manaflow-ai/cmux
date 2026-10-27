use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;

use super::page::WAIT_MARGIN;
use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn call(command: AppCommand) -> (&'static str, Value) {
    match command {
        AppCommand::Call { method, params, .. } => (method, params),
        AppCommand::Open { .. }
        | AppCommand::Events { .. }
        | AppCommand::DebugCall { .. }
        | AppCommand::Screenshot { .. }
        | AppCommand::Right { .. }
        | AppCommand::Settings(_)
        | AppCommand::Version => {
            panic!("expected a call")
        }
    }
}

/// `cmux window screenshot --out FILE` names a file of the caller's working
/// directory, so the app (which runs elsewhere) gets it absolute; `--out -`
/// (the PNG inline in the reply) and an absolute path go as given.
#[test]
fn screenshot_out_is_made_absolute_except_stdout() {
    let out = |value: &str| {
        let (method, params) =
            call(parse(&args(&["window", "screenshot", "--out", value])).unwrap().unwrap());
        assert_eq!(method, "action.run");
        assert_eq!(params["action"], "window screenshot");
        params["args"]["out"].as_str().unwrap().to_owned()
    };
    let cwd = std::env::current_dir().unwrap();
    assert_eq!(out("shot.png"), cwd.join("shot.png").to_string_lossy());
    assert_eq!(out("-"), "-");
    assert_eq!(out("/tmp/shot.png"), "/tmp/shot.png");
}

/// `cmux space set-defaults --cwd DIR` (and every other action's `--cwd`) names
/// a folder of the caller's working directory, so the app gets it absolute:
/// the app runs elsewhere, and a space's default directory must be absolute.
/// `~/…` is left for the app to expand, an empty `--cwd=` still clears, and a
/// bare `--cwd` (true) stays a bool for the app to refuse.
#[test]
fn an_action_cwd_is_made_absolute_except_home_and_empty() {
    let sent = |words: &[&str]| {
        let (method, params) =
            call(run_action("space set-defaults", &args(words), ActionName::Cli).unwrap());
        assert_eq!(method, "action.run");
        params["args"]["cwd"].clone()
    };
    let cwd = std::env::current_dir().unwrap();
    assert_eq!(sent(&["--cwd", "."]), json!(cwd.to_string_lossy()));
    assert_eq!(sent(&["--cwd", "sub"]), json!(cwd.join("sub").to_string_lossy()));
    assert_eq!(sent(&["--cwd=./sub/x"]), json!(cwd.join("sub/x").to_string_lossy()));
    assert_eq!(sent(&["--cwd", "~/x"]), json!("~/x"));
    assert_eq!(sent(&["--cwd", "/srv/app"]), json!("/srv/app"));
    assert_eq!(sent(&["--cwd="]), json!(""));
    assert_eq!(sent(&["--cwd"]), json!(true));
}

/// A remote, cloud or agent action's `--cwd` is a folder on the machine it runs
/// on, so it is sent as typed, never resolved against the caller's directory.
#[test]
fn a_remote_or_cloud_action_cwd_is_sent_as_typed() {
    let sent = |action: &str, name: ActionName| {
        let (_, params) = call(run_action(action, &args(&["--cwd", "."]), name).unwrap());
        params["args"]["cwd"].clone()
    };
    for action in
        ["open-remote", "remote open-terminal-here", "cloud start-session", "agent new-chat"]
    {
        assert_eq!(sent(action, ActionName::Cli), json!("."), "{action}");
    }
    for action in [
        "remote.openRemote",
        "cloudStartSession",
        "palette.newAgentChat",
        "agent.openSessionWorkspace",
    ] {
        assert_eq!(sent(action, ActionName::Any), json!("."), "{action}");
    }
    let cwd = std::env::current_dir().unwrap();
    assert_eq!(sent("tab new", ActionName::Cli), json!(cwd.to_string_lossy()));
}

/// `cmux cloud new-machine --bootstrap-script FILE` uploads a file of the
/// caller's working directory, so the app gets it absolute; `--persistent`
/// alone is a true flag and `--size` keeps its value.
#[test]
fn new_machine_bootstrap_script_is_made_absolute() {
    let (method, params) = call(
        run_action(
            "cloud new-machine",
            &args(&[
                "--persistent",
                "--size",
                "medium",
                "--bootstrap",
                "lane",
                "--bootstrap-script",
                "boot.sh",
            ]),
            ActionName::Cli,
        )
        .unwrap(),
    );
    assert_eq!(method, "action.run");
    let cwd = std::env::current_dir().unwrap();
    assert_eq!(params["args"]["bootstrapScript"], json!(cwd.join("boot.sh").to_string_lossy()));
    assert_eq!(params["args"]["persistent"], json!(true));
    assert_eq!(params["args"]["size"], json!("medium"));
    assert_eq!(params["args"]["bootstrap"], json!("lane"));
}

/// `cmux cloud apply-machine-config --machine-config FILE` names a file of the
/// caller's working directory too.
#[test]
fn machine_config_is_made_absolute() {
    let (_, params) = call(
        run_action(
            "cloud apply-machine-config",
            &args(&["--target", "machine:vm-1", "--machine-config", ".cmux/machine.toml"]),
            ActionName::Cli,
        )
        .unwrap(),
    );
    let cwd = std::env::current_dir().unwrap();
    assert_eq!(
        params["args"]["machineConfig"],
        json!(cwd.join(".cmux/machine.toml").to_string_lossy())
    );
}

#[test]
fn non_app_scopes_are_left_to_the_resource_grammar() {
    assert_eq!(parse(&args(&["workspace", "list"])).unwrap(), None);
    assert_eq!(parse(&args(&[])).unwrap(), None);
}

#[test]
fn focus_asks_the_app_to_move_the_view() {
    let (_, params) = call(
        parse(&args(&["tab", "move-to-new-workspace", "--target", "tab_1", "--focus"]))
            .unwrap()
            .unwrap_or_else(|| {
                run_action(
                    "tab move-to-new-workspace",
                    &args(&["--target", "tab_1", "--focus"]),
                    ActionName::Cli,
                )
                .unwrap()
            }),
    );
    assert_eq!(params["focus"], true);
    assert_eq!(params["origin"], "script");
    assert!(params.get("args").is_none());
}

#[test]
fn action_flags_name_camel_case_arguments_and_bare_flags_are_true() {
    let (_, params) = call(
        parse(&args(&["app", "quit", "--keep-sessions", "--browser-profile", "work"]))
            .unwrap()
            .unwrap(),
    );
    assert_eq!(params["action"], "app quit");
    assert_eq!(params["args"], json!({ "keepSessions": true, "browserProfile": "work" }));
    assert!(parse(&args(&["action", "run", "quit", "--target"])).is_err());
}

#[test]
fn unknown_words_run_the_action_with_that_cli_name() {
    let (method, params) = call(parse(&args(&["app", "new-window"])).unwrap().unwrap());
    assert_eq!(method, "action.run");
    assert_eq!(
        params,
        json!({ "action": "app new-window", "cli": true, "wait": true, "origin": "script" })
    );
}

#[test]
fn action_runs_wait_by_default_and_no_wait_opts_out() {
    let (_, params) = call(parse(&args(&["action", "run", "window.new"])).unwrap().unwrap());
    assert_eq!(params, json!({ "action": "window.new", "wait": true, "origin": "script" }));
    let command = parse(&args(&["action", "run", "window.new", "--no-wait"])).unwrap().unwrap();
    let AppCommand::Call { timeout, .. } = &command else { panic!("expected a call") };
    assert_eq!(*timeout, Some(READ_TIMEOUT));
    assert_eq!(
        call(command).1,
        json!({ "action": "window.new", "wait": false, "origin": "script" })
    );
}

#[test]
fn busy_is_retried_only_when_the_app_says_nothing_ran() {
    let not_run = json!({ "code": "busy", "data": { "state": "not_run" } });
    assert!(busy_before_running(&not_run));
    assert!(busy_before_running(&json!({ "code": "busy", "data": { "not_run": true } })));
    assert!(!busy_before_running(&json!({ "code": "busy", "data": { "state": "in_progress" } })));
    assert!(!busy_before_running(&json!({ "code": "busy" })));
    assert!(!busy_before_running(&json!({ "code": "timeout", "data": { "state": "not_run" } })));
    assert_eq!(busy_retry_delay(&not_run), BUSY_RETRY_DELAY);
    let later = json!({ "code": "busy", "data": { "state": "not_run", "retry_after_ms": 60_000 } });
    assert_eq!(busy_retry_delay(&later), MAX_BUSY_RETRY_DELAY);
}

/// A fake app control socket that answers each request line with the
/// next canned response and records what it received, per connection.
fn fake_app(responses: Vec<Value>) -> (PathBuf, std::thread::JoinHandle<Vec<Vec<Value>>>) {
    fake_app_after(Duration::ZERO, responses)
}

/// `fake_app` that waits `delay` before each answer (a person at a sheet).
fn fake_app_after(
    delay: Duration,
    responses: Vec<Value>,
) -> (PathBuf, std::thread::JoinHandle<Vec<Vec<Value>>>) {
    use std::os::unix::net::UnixListener;
    // The shared helper keeps the socket path under sun_path whatever
    // $TMPDIR is; the guard moves into the server thread.
    let dir = cmux_unix_socket::short_test_dir("cmux-app");
    let socket = dir.path().join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(false).unwrap();
    let handle = std::thread::spawn(move || {
        let mut connections = Vec::new();
        let mut responses = responses.into_iter();
        // One connection is expected; a second one would show up here.
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut received = Vec::new();
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap() > 0 {
            received.push(serde_json::from_str::<Value>(&line).unwrap());
            line.clear();
            let Some(response) = responses.next() else { break };
            std::thread::sleep(delay);
            writeln!(writer, "{response}").unwrap();
        }
        connections.push(received);
        listener.set_nonblocking(true).unwrap();
        if let Ok((stream, _)) = listener.accept() {
            let mut extra = String::new();
            let _ = BufReader::new(stream).read_line(&mut extra);
            connections.push(vec![json!(extra)]);
        }
        drop(dir);
        connections
    });
    (socket, handle)
}

#[test]
fn an_app_socket_of_another_user_is_refused_before_a_request_is_written() {
    let (socket, app) = fake_app(vec![]);
    let own = cmux_tui_core::platform::effective_uid();
    let other = if own == u32::MAX { own - 1 } else { own + 1 };
    let result = connect_for_uid(&socket, other);
    let kind = result.as_ref().err().map(std::io::Error::kind);
    drop(result);

    assert_eq!(kind, Some(std::io::ErrorKind::PermissionDenied));
    assert!(app.join().unwrap()[0].is_empty(), "the client wrote before checking the peer uid");
}

fn global_for(socket: &Path) -> GlobalArgs {
    GlobalArgs {
        app_socket: Some(socket.to_path_buf()),
        output: OutputMode::Quiet,
        ..GlobalArgs::default()
    }
}

#[test]
fn unknown_cli_name_is_one_action_run_and_not_found_means_not_an_action() {
    let not_found =
        json!({ "id": 1, "ok": false, "error": { "code": "not_found", "message": "x" } });
    let (socket, app) = fake_app(vec![not_found]);
    let ran = run_cli_action(&global_for(&socket), "workspace frobnicate", &args(&["--x", "1"]));
    assert_eq!(ran, None);
    let connections = app.join().unwrap();
    assert_eq!(connections.len(), 1, "opened more than one connection: {connections:?}");
    let [request] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(request["method"], "action.run");
    assert_eq!(request["params"]["action"], "workspace frobnicate");
    assert_eq!(request["params"]["cli"], true);
    assert_eq!(request["params"]["wait"], true);
    assert!(request["params"]["idempotency_key"].as_str().is_some_and(|key| !key.is_empty()));
}

#[test]
fn a_busy_run_that_never_started_is_resent_with_the_same_key() {
    let busy = json!({ "id": 1, "ok": false, "error": { "code": "busy", "data": { "state": "not_run", "retry_after_ms": 1 } } });
    let ran = json!({ "id": 1, "ok": true, "result": { "ran": true } });
    let (socket, app) = fake_app(vec![busy, ran]);
    let mut global = global_for(&socket);
    global.idempotency_key = Some("mutation-retry-1".into());
    let command = parse(&args(&["action", "run", "window.new"])).unwrap().unwrap();
    assert_eq!(run(&global, command), 0);
    let connections = app.join().unwrap();
    assert_eq!(connections.len(), 1);
    let keys: Vec<_> =
        connections[0].iter().map(|request| request["params"]["idempotency_key"].clone()).collect();
    assert_eq!(keys, vec![json!("mutation-retry-1"), json!("mutation-retry-1")]);
}

#[test]
fn a_run_that_may_have_started_is_not_retried() {
    let timeout = json!({ "id": 1, "ok": false, "error": { "code": "timeout", "message": "slow", "data": { "state": "in_progress" } } });
    let (socket, app) = fake_app(vec![timeout]);
    let command = parse(&args(&["action", "run", "window.new"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 1);
    let connections = app.join().unwrap();
    assert_eq!(connections[0].len(), 1);
}

#[test]
fn action_run_maps_flags_to_target_and_arguments() {
    let (_, params) = call(
        parse(&args(&[
            "action",
            "run",
            "tab.rename",
            "--target",
            "tab_0123",
            "--title",
            "Build",
            "--arg",
            "keep_case=true",
            "--wait",
        ]))
        .unwrap()
        .unwrap(),
    );
    assert_eq!(
        params,
        json!({
            "action": "tab.rename",
            "target": "tab_0123",
            "wait": true,
            "origin": "script",
            "args": { "title": "Build", "keep_case": "true" },
        })
    );
}

#[test]
fn both_agent_tab_command_forms_forward_the_peer_host() {
    for words in [
        vec!["agent", "open-tab", "session-id", "--target", "pane_0123", "--host", "cmux16"],
        vec![
            "action",
            "run",
            "agent.openSessionTab",
            "--target",
            "pane_0123",
            "--session",
            "session-id",
            "--host",
            "cmux16",
        ],
    ] {
        let (_, params) = call(parse(&args(&words)).unwrap().unwrap());
        assert_eq!(params["target"], "pane_0123");
        assert_eq!(params["args"], json!({"session": "session-id", "host": "cmux16"}));
    }
}

#[test]
fn app_requests_wait_for_the_app_to_catch_up_with_the_daemon() {
    assert_eq!(
        with_read_barrier("action.run", json!({ "action": "x" })),
        json!({ "action": "x", "after": "sync" })
    );
    assert_eq!(with_read_barrier("snapshot.get", json!({ "after": 12 })), json!({ "after": 12 }));
}

#[test]
fn liveness_probes_do_not_wait_for_the_daemon() {
    assert_eq!(with_read_barrier("system.ping", json!({})), json!({}));
    assert_eq!(with_read_barrier("system.capabilities", json!({})), json!({}));
    assert_eq!(with_read_barrier("system.identify", json!({})), json!({ "after": "sync" }));
}

#[test]
fn only_reads_are_asked_again_after_a_timeout() {
    for read in ["system.ping", "snapshot.get", "workspace.list", "action.describe"] {
        assert!(is_retryable_read(read), "{read}");
    }
    for write in ["action.run", "workspace.create", "browser.open_split", "settings.set"] {
        assert!(!is_retryable_read(write), "{write}");
    }
    assert!(timed_out(&Err(json!({ "code": "timeout", "message": "x" }))));
    assert!(!timed_out(&Err(json!({ "code": "busy", "message": "x" }))));
    assert!(!timed_out(&Ok(json!({}))));
}

#[test]
fn app_browser_tabs_take_page_commands_and_daemon_browsers_stay_with_the_mux() {
    let (method, params) = call(
        parse(&args(&["browser", "tab_01ab", "navigate", "https://cmux.com"])).unwrap().unwrap(),
    );
    assert_eq!(method, "browser.page.navigate");
    assert_eq!(params, json!({ "tab": "tab_01ab", "url": "https://cmux.com" }));
    let (method, params) =
        call(parse(&args(&["browser", "page", "fill", "#q", "hello"])).unwrap().unwrap());
    assert_eq!(method, "browser.page.fill");
    assert_eq!(params, json!({ "selector": "#q", "text": "hello" }));
    let (method, params) = call(
        parse(&args(&["browser", "page", "snapshot", "--interactive", "--max-depth", "4"]))
            .unwrap()
            .unwrap(),
    );
    assert_eq!(method, "browser.page.snapshot");
    assert_eq!(params, json!({ "interactive": true, "max_depth": 4 }));
    assert_eq!(parse(&args(&["browser", "browser_01ab", "navigate", "--url", "x"])).unwrap(), None);
    assert!(parse(&args(&["browser", "page", "fill", "#q"])).is_err());
}

// `cmux browser <tab|page> press|hover|check|uncheck|select|scroll|
// scroll-into-view` reach the app as the browser.page input methods, in the
// old CLI's positional and flag forms; `select` with words is the input verb,
// not the tab verb.
#[test]
fn browser_input_verbs_reach_the_app_in_the_old_cli_forms() {
    let done = json!({ "id": 1, "ok": true, "result": { "tab": "tab_01ab" } });
    for (words, method, params) in [
        (&["press", "Enter"][..], "browser.page.press", json!({ "key": "Enter" })),
        (
            &["press", "--selector", "#q", "--key", "Enter"],
            "browser.page.press",
            json!({ "key": "Enter", "selector": "#q" }),
        ),
        (&["key", "Tab"], "browser.page.press", json!({ "key": "Tab" })),
        (&["hover", "#menu"], "browser.page.hover", json!({ "selector": "#menu" })),
        (&["check", "#a"], "browser.page.check", json!({ "selector": "#a" })),
        (&["uncheck", "#a"], "browser.page.uncheck", json!({ "selector": "#a" })),
        (
            &["select", "#size", "m"],
            "browser.page.select",
            json!({ "selector": "#size", "value": "m" }),
        ),
        (
            &["select", "--selector", "#size", "--value", "m"],
            "browser.page.select",
            json!({ "selector": "#size", "value": "m" }),
        ),
        (&["scroll", "400"], "browser.page.scroll", json!({ "dy": 400.0 })),
        (
            &["scroll", "#list", "--dx=-50"],
            "browser.page.scroll",
            json!({ "selector": "#list", "dx": -50.0 }),
        ),
        (
            &["scrollintoview", "--selector", "#f"],
            "browser.page.scroll_into_view",
            json!({ "selector": "#f" }),
        ),
    ] {
        let (socket, app) = fake_app(vec![done.clone()]);
        let mut all = vec!["browser", "tab_01ab"];
        all.extend_from_slice(words);
        let command = parse(&args(&all)).unwrap().unwrap();
        assert_eq!(run(&global_for(&socket), command), 0, "{words:?}");
        let connections = app.join().unwrap();
        let [request] = connections[0].as_slice() else { panic!("{connections:?}") };
        assert_eq!(request["method"], method, "{words:?}");
        let mut sent = request["params"].clone();
        sent.as_object_mut().unwrap().remove("after");
        let mut expected = params;
        expected["tab"] = json!("tab_01ab");
        assert_eq!(sent, expected, "{words:?}");
    }
    for bad in [
        &["press"][..],
        &["press", "a", "b"],
        &["press", "a", "--dy", "1"],
        &["scroll"],
        &["scroll", "--dy", "inf"],
        &["scroll", "--dy", "far"],
        &["scroll", "#a", "--selector", "#b", "--dy", "1"],
        &["select", "#size"],
        &["check"],
        &["hover", "#a", "--force"],
    ] {
        let mut all = vec!["browser", "tab_01ab"];
        all.extend_from_slice(bad);
        assert!(parse(&args(&all)).is_err(), "{bad:?}");
    }
}

// `cmux browser <tab|page> wait` sends one condition with its timeout, and
// the CLI outwaits the app's own deadline; a second positional is refused.
#[test]
fn page_waits_reach_the_app_with_one_condition_and_the_cli_outwaits_them() {
    let met = json!({ "id": 1, "ok": true, "result": { "tab": "tab_01ab", "met": true } });
    let (socket, app) = fake_app(vec![met]);
    let command = parse(&args(&["browser", "tab_01ab", "wait", "#done", "--timeout-ms", "20000"]))
        .unwrap()
        .unwrap();
    let AppCommand::Call { timeout, .. } = &command else { panic!("expected a call") };
    assert_eq!(*timeout, Some(Duration::from_millis(20_000) + WAIT_MARGIN));
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [request] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(request["method"], "browser.page.wait");
    let mut sent = request["params"].clone();
    sent.as_object_mut().unwrap().remove("after");
    assert_eq!(sent, json!({ "tab": "tab_01ab", "selector": "#done", "timeout_ms": 20000 }));
    let (_, params) = call(
        parse(&args(&[
            "browser",
            "page",
            "wait",
            "--url-contains",
            "/done",
            "--load-state",
            "complete",
            "--timeout",
            "1.5",
        ]))
        .unwrap()
        .unwrap(),
    );
    assert_eq!(
        params,
        json!({ "url_contains": "/done", "load_state": "complete", "timeout_ms": 1500 })
    );
    assert!(parse(&args(&["browser", "page", "wait", "#a", "#b"])).is_err());
    assert!(parse(&args(&["browser", "page", "wait", "--timeout-ms", "soon"])).is_err());
}

// `cmux browser … screenshot`: the PNG lands at --out whether the app sends it
// inline or only as its own file, --out naming that file leaves it whole, and
// bad image data fails.
#[test]
fn a_screenshot_is_written_to_out_and_bad_image_data_fails() {
    let png = [0x89, b'P', b'N', b'G', 0, 1];
    let response = json!({ "id": 1, "ok": true, "result": {
        "tab": "tab_01ab", "png_base64": BASE64.encode(png), "width": 1, "height": 1 } });
    let (socket, app) = fake_app(vec![response]);
    let dir = std::env::temp_dir()
        .join(format!("cmux-shot-{}", super::super::command::random_prefixed("t").unwrap()));
    let out = dir.join("nested").join("shot.png");
    let command = parse(&args(&[
        "browser",
        "page",
        "screenshot",
        "--selector",
        "#hero",
        "--out",
        out.to_str().unwrap(),
    ]))
    .unwrap()
    .unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    assert_eq!(std::fs::read(&out).unwrap(), png);
    let connections = app.join().unwrap();
    assert_eq!(connections[0][0]["method"], "browser.page.screenshot");
    assert_eq!(connections[0][0]["params"]["selector"], "#hero");

    // A large PNG comes only as the app's file, which --out copies.
    let saved = dir.join("app.png");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(&saved, png).unwrap();
    let response = json!({ "id": 1, "ok": true, "result": {
        "tab": "tab_01ab", "path": saved.to_str().unwrap(), "width": 1, "height": 1 } });
    let (socket, app) = fake_app(vec![response.clone()]);
    let copy = dir.join("copy.png");
    let command =
        AppCommand::Screenshot { params: json!({}), out: Some(copy.to_str().unwrap().to_owned()) };
    assert_eq!(run(&global_for(&socket), command), 0);
    assert_eq!(std::fs::read(&copy).unwrap(), png);
    app.join().unwrap();

    // --out naming the app's own file leaves it whole.
    let (socket, app) = fake_app(vec![response]);
    let command =
        AppCommand::Screenshot { params: json!({}), out: Some(saved.to_str().unwrap().to_owned()) };
    assert_eq!(run(&global_for(&socket), command), 0);
    assert_eq!(std::fs::read(&saved).unwrap(), png);
    app.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);

    let broken = json!({ "id": 1, "ok": true, "result": { "png_base64": "not base64!" } });
    let (socket, app) = fake_app(vec![broken]);
    let command = AppCommand::Screenshot { params: json!({}), out: Some("-".into()) };
    assert_eq!(run(&global_for(&socket), command), 3);
    app.join().unwrap();
    assert!(
        parse(&args(&["browser", "page", "screenshot", "--selector", "#a", "--full-page"]))
            .is_err()
    );
}

// `cmux browser <tab|page> cookies|storage` reach the app as the
// browser.page cookie and storage methods, in the old CLI's forms.
#[test]
fn browser_cookies_and_storage_reach_the_app_in_the_old_cli_forms() {
    let done = json!({ "id": 1, "ok": true, "result": { "tab": "tab_01ab" } });
    for (words, method, params) in [
        (&["cookies"][..], "browser.page.cookies.get", json!({})),
        (
            &["cookies", "get", "--name", "sid", "--domain=example"],
            "browser.page.cookies.get",
            json!({ "name": "sid", "domain": "example" }),
        ),
        (
            &[
                "cookies",
                "set",
                "sid",
                "1",
                "--url",
                "https://cmux.com/",
                "--expires",
                "1900000000",
                "--secure",
                "--http-only",
            ],
            "browser.page.cookies.set",
            json!({ "name": "sid", "value": "1", "url": "https://cmux.com/",
                    "expires": 1_900_000_000, "secure": true, "http_only": true }),
        ),
        (
            &["cookies", "set", "--name", "a", "--value", "b"],
            "browser.page.cookies.set",
            json!({ "name": "a", "value": "b" }),
        ),
        (
            &["cookies", "get", "--url", "https://cmux.com/", "--http-only"],
            "browser.page.cookies.get",
            json!({ "url": "https://cmux.com/", "http_only": true }),
        ),
        (
            &[
                "cookies",
                "clear",
                "--name",
                "sid",
                "--value=1",
                "--expires",
                "1900000000",
                "--secure",
            ],
            "browser.page.cookies.clear",
            json!({ "name": "sid", "value": "1", "expires": 1_900_000_000, "secure": true }),
        ),
        (&["cookies", "clear", "--all"], "browser.page.cookies.clear", json!({ "all": true })),
        (&["storage"], "browser.page.storage.get", json!({})),
        (
            &["storage", "session", "get", "theme"],
            "browser.page.storage.get",
            json!({ "type": "session", "key": "theme" }),
        ),
        (
            &["storage", "set", "theme", "dark"],
            "browser.page.storage.set",
            json!({ "key": "theme", "value": "dark" }),
        ),
        (&["storage", "local", "clear"], "browser.page.storage.clear", json!({ "type": "local" })),
    ] {
        let (socket, app) = fake_app(vec![done.clone()]);
        let mut all = vec!["browser", "tab_01ab"];
        all.extend_from_slice(words);
        let command = parse(&args(&all)).unwrap().unwrap();
        assert_eq!(run(&global_for(&socket), command), 0, "{words:?}");
        let connections = app.join().unwrap();
        let [request] = connections[0].as_slice() else { panic!("{connections:?}") };
        assert_eq!(request["method"], method, "{words:?}");
        let mut sent = request["params"].clone();
        sent.as_object_mut().unwrap().remove("after");
        let mut expected = params;
        expected["tab"] = json!("tab_01ab");
        assert_eq!(sent, expected, "{words:?}");
    }
    for bad in [
        &["cookies", "set", "sid"][..],
        &["cookies", "set", "a", "b", "--expires", "soon"],
        &["cookies", "get", "--all"],
        &["cookies", "get", "extra"],
        &["cookies", "eat"],
        &["storage", "local", "set", "k"],
        &["storage", "cookies"],
    ] {
        let mut all = vec!["browser", "tab_01ab"];
        all.extend_from_slice(bad);
        assert!(parse(&args(&all)).is_err(), "{bad:?}");
    }
}

// `cmux browser <tab|page> tabs|new-tab|select|close` reach the app as the
// browser.page tab methods; runs that open, select or close carry an
// idempotency key, so a busy retry is one run, and `--no-wait` asks the app
// not to wait.
#[test]
fn browser_tab_verbs_reach_the_app_and_runs_carry_a_key() {
    let listed = json!({ "id": 1, "ok": true, "result": { "tabs": [] } });
    let opened = json!({ "id": 1, "ok": true, "result": { "ran": true, "created": ["tab_02cd"] } });
    let closed = json!({ "id": 1, "ok": true, "result": { "ran": true } });
    for (words, response, method, params) in [
        (
            vec!["browser", "page", "tabs", "--all"],
            listed,
            "browser.page.tabs",
            json!({ "all": true }),
        ),
        (
            vec!["browser", "tab_01ab", "new-tab", "https://cmux.com"],
            opened,
            "browser.page.new_tab",
            json!({ "tab": "tab_01ab", "url": "https://cmux.com" }),
        ),
        (
            vec!["browser", "tab_01ab", "switch"],
            json!({ "id": 1, "ok": true, "result": { "ran": true } }),
            "browser.page.select_tab",
            json!({ "tab": "tab_01ab" }),
        ),
        (
            vec!["browser", "tab_01ab", "close", "--no-wait"],
            closed,
            "browser.page.close",
            json!({ "tab": "tab_01ab", "wait": false }),
        ),
    ] {
        let (socket, app) = fake_app(vec![response]);
        let command = parse(&args(&words)).unwrap().unwrap();
        assert_eq!(run(&global_for(&socket), command), 0, "{words:?}");
        let connections = app.join().unwrap();
        let [request] = connections[0].as_slice() else { panic!("{connections:?}") };
        assert_eq!(request["method"], method, "{words:?}");
        let mut sent = request["params"].clone();
        let key = sent.as_object_mut().unwrap().remove("idempotency_key");
        sent.as_object_mut().unwrap().remove("after");
        assert_eq!(sent, params, "{words:?}");
        assert_eq!(key.is_some(), method != "browser.page.tabs", "{words:?}");
    }
    assert!(parse(&args(&["browser", "page", "close", "tab_02"])).is_err());
    assert!(parse(&args(&["browser", "tab_01ab", "select", "--all"])).is_err());
}

#[test]
fn settings_set_takes_json_or_a_plain_string() {
    let (_, params) =
        call(parse(&args(&["settings", "set", "layout.panePadding", "4"])).unwrap().unwrap());
    assert_eq!(params, json!({ "path": "layout.panePadding", "value": 4 }));
    let (_, params) =
        call(parse(&args(&["settings", "set", "window.titlebar", "minimal"])).unwrap().unwrap());
    assert_eq!(params, json!({ "path": "window.titlebar", "value": "minimal" }));
}

#[test]
fn responses_split_transport_from_app_errors() {
    assert_eq!(
        parse_response(r#"{"id":"1","ok":true,"result":{"pong":true}}"#),
        Ok(Ok(json!({"pong":true})))
    );
    assert_eq!(
        parse_response(r#"{"id":"1","ok":false,"error":{"code":"not_found"}}"#),
        Ok(Err(json!({"code":"not_found"})))
    );
    assert!(
        parse_response("ERROR: Access denied - only processes started inside cmux can connect")
            .is_err()
    );
    assert!(parse_response("").is_err());
}

#[test]
fn keybinding_reads_call_the_app_read_ops() {
    let (method, params) = call(
        parse(&args(&["keybinding", "list", "--query", "tab", "--source", "user"]))
            .unwrap()
            .unwrap(),
    );
    assert_eq!(method, "keybinding.list");
    assert_eq!(params, json!({ "query": "tab", "source": "user" }));
    let (method, params) = call(
        parse(&args(&["keybinding", "resolve", "ctrl+k s", "--window", "win_a"])).unwrap().unwrap(),
    );
    assert_eq!(method, "keybinding.resolve");
    assert_eq!(params, json!({ "keys": "ctrl+k s", "window": "win_a" }));
    let (method, params) = call(parse(&args(&["keybinding", "context"])).unwrap().unwrap());
    assert_eq!(method, "context.keys");
    assert_eq!(params, json!({}));
    assert!(parse(&args(&["keybinding", "resolve"])).is_err(), "resolve needs keys");
    assert!(parse(&args(&["keybinding"])).is_err());
    assert!(parse(&args(&["keybinding", "list", "--nope", "x"])).is_err());
}

/// RED: `--confirm` sends `confirm: true` on every settings write, anywhere
/// after the verb; `settings reset` is its own verb (`unset` stays).
#[test]
fn settings_writes_take_confirm_and_reset_is_a_verb() {
    let cases = [
        (
            &["settings", "set", "history.terminalCommands", "false", "--confirm"][..],
            "settings.set",
            json!({ "path": "history.terminalCommands", "value": false, "confirm": true }),
        ),
        (
            &["settings", "set", "--confirm", "window.titlebar", "minimal"][..],
            "settings.set",
            json!({ "path": "window.titlebar", "value": "minimal", "confirm": true }),
        ),
        (
            &["settings", "reset", "a.b", "--confirm"][..],
            "settings.reset",
            json!({ "path": "a.b", "confirm": true }),
        ),
        (&["settings", "reset", "a.b"][..], "settings.reset", json!({ "path": "a.b" })),
        (
            &["settings", "unset", "a.b", "--confirm"][..],
            "settings.unset",
            json!({ "path": "a.b", "confirm": true }),
        ),
        (&["settings", "unset", "a.b"][..], "settings.unset", json!({ "path": "a.b" })),
    ];
    for (words, method, params) in cases {
        let command = parse(&args(words)).unwrap_or_else(|error| panic!("{words:?}: {error:?}"));
        assert_eq!(call(command.unwrap()), (method, params), "{words:?}");
    }
    assert!(parse(&args(&["settings", "set", "a.b"])).is_err());
    assert!(parse(&args(&["settings", "reset"])).is_err());
    assert!(parse(&args(&["settings", "reset", "a.b", "--yes"])).is_err());
}

/// RED: a user-only key the app refuses (`setting_user_only`) ends the
/// command with exit 1, the CLI's code for an op the app refused, and the
/// request carries no `confirm`. With `--confirm` the CLI waits for the
/// person longer than any read deadline, and a declined sheet is exit 1.
#[test]
fn a_user_only_key_is_refused_without_confirm_and_waits_for_the_person_with_it() {
    let key = "history.terminalCommands";
    let refused = json!({ "id": 1, "ok": false, "error": { "code": "setting_user_only",
        "message": "history.terminalCommands can be changed only by you",
        "data": { "key": key } } });
    let (socket, app) = fake_app(vec![refused]);
    let command = parse(&args(&["settings", "set", key, "false"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 1);
    let connections = app.join().unwrap();
    assert!(connections[0][0]["params"].get("confirm").is_none(), "{connections:?}");

    let approved = json!({ "id": 1, "ok": true, "result": { "path": ["history", "terminalCommands"], "value": false } });
    let (socket, app) = fake_app_after(READ_TIMEOUT + Duration::from_millis(500), vec![approved]);
    let command = parse(&args(&["settings", "set", key, "false", "--confirm"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 0, "the CLI stopped waiting for the person");
    let connections = app.join().unwrap();
    assert_eq!(connections[0][0]["params"]["confirm"], true);

    let declined = json!({ "id": 1, "ok": false, "error": { "code": "setting_user_only",
        "message": "history.terminalCommands was not changed: the confirmation was declined",
        "data": { "key": key, "declined": true } } });
    let (socket, app) = fake_app(vec![declined]);
    let command = parse(&args(&["settings", "reset", key, "--confirm"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 1);
    assert_eq!(app.join().unwrap()[0][0]["method"], "settings.reset");
}

/// `--confirm` waits with no client deadline; plain reads and writes keep
/// the control-plane one.
#[test]
fn only_a_confirmed_settings_write_waits_without_a_deadline() {
    let timeout = |words: &[&str]| match parse(&args(words)).unwrap().unwrap() {
        AppCommand::Call { timeout, .. } => timeout,
        AppCommand::Open { .. }
        | AppCommand::Events { .. }
        | AppCommand::DebugCall { .. }
        | AppCommand::Screenshot { .. }
        | AppCommand::Right { .. }
        | AppCommand::Settings(_)
        | AppCommand::Version => {
            panic!("expected a call")
        }
    };
    assert_eq!(timeout(&["settings", "set", "a.b", "1", "--confirm"]), None);
    assert_eq!(timeout(&["settings", "reset", "a.b", "--confirm"]), None);
    assert_eq!(timeout(&["settings", "set", "a.b", "1"]), Some(READ_TIMEOUT));
    assert_eq!(timeout(&["settings", "get"]), Some(READ_TIMEOUT));
}

/// A refusal without --confirm keeps the app's message and adds the rerun
/// hint; a declined sheet says "declined in cmux"; neither echoes the value.
#[test]
fn a_user_only_refusal_says_what_to_do() {
    let messages = &crate::localization::catalog().app_control;
    let refusal = |declined: bool| {
        json!({ "code": "setting_user_only", "message": "k can be changed only by you",
            "data": { "key": "k", "declined": declined } })
    };
    let secret = "s3cr3t-value";
    let mut error = refusal(false);
    settings::explain_refusal("settings.set", &json!({ "path": "k", "value": secret }), &mut error);
    let text = error["message"].as_str().unwrap();
    assert!(text.starts_with("k can be changed only by you\n"), "{text}");
    assert!(text.ends_with(messages.settings_confirm_hint), "{text}");
    assert!(!text.contains(secret));
    assert_eq!(error["code"], "setting_user_only", "JSON output keeps the code");

    let mut error = refusal(true);
    let confirmed = json!({ "path": "k", "value": secret, "confirm": true });
    settings::explain_refusal("settings.reset", &confirmed, &mut error);
    assert_eq!(error["message"], messages.settings_declined);
    assert_eq!(error["data"]["declined"], true);

    let mut other = json!({ "code": "managed", "message": "managed by your organization" });
    settings::explain_refusal("settings.set", &confirmed, &mut other);
    assert_eq!(other["message"], "managed by your organization");
}

/// RED: `--` ends the options, so a value or path may start with `--`
/// (`cmux settings set <key> -- --confirm` sets the string "--confirm").
#[test]
fn a_double_dash_ends_the_settings_options() {
    let cases = [
        (
            &["settings", "set", "a.b", "--", "--confirm"][..],
            "settings.set",
            json!({ "path": "a.b", "value": "--confirm" }),
        ),
        (
            &["settings", "set", "--confirm", "a.b", "--", "--x"][..],
            "settings.set",
            json!({ "path": "a.b", "value": "--x", "confirm": true }),
        ),
        (
            &["settings", "set", "--", "a.b", "-1"][..],
            "settings.set",
            json!({ "path": "a.b", "value": -1 }),
        ),
        (&["settings", "reset", "--", "--odd"][..], "settings.reset", json!({ "path": "--odd" })),
    ];
    for (words, method, params) in cases {
        let command = parse(&args(words)).unwrap_or_else(|error| panic!("{words:?}: {error:?}"));
        assert_eq!(call(command.unwrap()), (method, params), "{words:?}");
    }
    assert!(parse(&args(&["settings", "set", "a.b", "--"])).is_err());
    assert!(parse(&args(&["settings", "set", "a.b", "--", "x", "y"])).is_err());
}

/// A `--confirm` write says first that the sheet is in the app; other
/// requests print no note.
#[test]
fn a_confirmed_write_says_where_to_answer() {
    let messages = &crate::localization::catalog().app_control;
    let confirmed = json!({ "path": "a.b", "confirm": true });
    for method in ["settings.set", "settings.reset", "settings.unset"] {
        assert_eq!(settings::waiting_note(method, &confirmed), Some(messages.settings_waiting));
    }
    assert_eq!(settings::waiting_note("settings.set", &json!({ "path": "a.b" })), None);
    assert_eq!(settings::waiting_note("action.run", &confirmed), None);
    assert!(output_shows_notes(OutputMode::Human));
    assert!(!output_shows_notes(OutputMode::Json) && !output_shows_notes(OutputMode::Quiet));
}

fn identify_answer(bundle_id: &str) -> Value {
    json!({ "id": 1, "ok": true, "result": { "app": "cmux-next", "bundle_id": bundle_id, "tag": "occl1-v1" } })
}

fn app_call(socket: &Path, words: &[&str]) -> i32 {
    let mut command_args = vec!["app", "call"];
    command_args.extend_from_slice(words);
    run(&global_for(socket), parse(&args(&command_args)).unwrap().unwrap())
}

/// RED: `app call <method> [json]` asks the app who it is, then sends the
/// method with exactly the given params plus the CLI's origin (no read
/// barrier, so `debug.hangs` keeps its own `after`).
#[test]
fn app_call_sends_the_method_to_a_debug_build() {
    let answer = json!({ "id": 1, "ok": true, "result": { "surfaces": [] } });
    let (socket, app) = fake_app(vec![identify_answer("com.cmuxterm.app.debug.occl1-v1"), answer]);
    assert_eq!(app_call(&socket, &["debug.surfaces", r#"{"window":"win_1"}"#]), 0);
    let connections = app.join().unwrap();
    let methods: Vec<_> = connections[0].iter().map(|request| request["method"].clone()).collect();
    assert_eq!(methods, vec![json!("system.identify"), json!("debug.surfaces")]);
    assert_eq!(connections[0][1]["params"], json!({ "window": "win_1", "origin": "script" }));

    let (socket, app) = fake_app(vec![
        identify_answer("com.cmuxterm.app.debug"),
        json!({ "id": 1, "ok": true, "result": {} }),
    ]);
    assert_eq!(app_call(&socket, &["debug.hangs"]), 0);
    assert_eq!(app.join().unwrap()[0][1]["params"], json!({ "origin": "script" }));
}

/// RED: a release, nightly or rc app is refused before any method is sent.
#[test]
fn app_call_refuses_an_app_that_is_not_a_debug_build() {
    for bundle in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debugger"] {
        let (socket, app) =
            fake_app(vec![identify_answer(bundle), json!({ "id": 1, "ok": true, "result": {} })]);
        assert_eq!(app_call(&socket, &["debug.surfaces"]), 1, "{bundle}");
        let connections = app.join().unwrap();
        assert_eq!(connections[0].len(), 1, "{bundle}: sent more than identify: {connections:?}");
    }
}

/// RED: the params must be one JSON object (else a usage error, exit 2), and
/// a method is required.
#[test]
fn app_call_params_are_one_json_object() {
    for words in [
        &["app", "call"][..],
        &["app", "call", "debug.surfaces", "{nope"],
        &["app", "call", "debug.surfaces", "[1]"],
        &["app", "call", "debug.surfaces", "{}", "extra"],
    ] {
        assert!(parse(&args(words)).is_err(), "{words:?}");
    }
}

/// RED: a caller cannot claim to be the person: the CLI's origin replaces any
/// `origin` in the JSON, and a person-only answer passes through as exit 1.
#[test]
fn app_call_never_claims_the_person_and_passes_app_refusals_through() {
    let refused = json!({ "id": 1, "ok": false, "error": { "code": "setting_user_only",
        "message": "history.terminalCommands can be changed only by you",
        "data": { "key": "history.terminalCommands" } } });
    let (socket, app) = fake_app(vec![identify_answer("com.cmuxterm.app.debug.t1"), refused]);
    let params =
        r#"{"path":"history.terminalCommands","value":false,"origin":"user","confirm":false}"#;
    assert_eq!(app_call(&socket, &["settings.set", params]), 1);
    let sent = &app.join().unwrap()[0][1];
    assert_eq!(sent["method"], "settings.set");
    assert_eq!(sent["params"]["origin"], "script");
}

/// R92: `cmux ghostty diagnostics` prints the app's `ghostty.diagnostics`
/// report (the Ghostty config keys and keybind actions cmux does not
/// apply); extra words are a usage error.
#[test]
fn ghostty_diagnostics_reads_the_app_report() {
    let (method, params) = call(parse(&args(&["ghostty", "diagnostics"])).unwrap().unwrap());
    assert_eq!(method, "ghostty.diagnostics");
    assert_eq!(params, json!({}));
    assert!(parse(&args(&["ghostty", "diagnostics", "extra"])).is_err());
}

/// `cmux errors` lists the app's error journal (`errors.list`) with its
/// filters; `cmux errors clear` forgets entries (`errors.clear`).
#[test]
fn errors_lists_and_clears_the_app_journal() {
    let (method, params) = call(parse(&args(&["errors"])).unwrap().unwrap());
    assert_eq!(method, "errors.list");
    assert_eq!(params, json!({}));
    let (method, params) = call(
        parse(&args(&[
            "errors",
            "list",
            "--since",
            "2h",
            "--source",
            "acpmux",
            "--source",
            "page",
            "--level",
            "error",
            "--text",
            "hello",
            "--top",
            "--limit",
            "5",
            "--no-harvest",
        ]))
        .unwrap()
        .unwrap(),
    );
    assert_eq!(method, "errors.list");
    assert_eq!(
        params,
        json!({"since": "2h", "source": ["acpmux", "page"], "level": "error", "text": "hello",
               "order": "count", "limit": 5, "harvest": false})
    );
    let (method, params) = call(
        parse(&args(&["errors", "clear", "--fingerprint", "ab", "--fingerprint", "cd"]))
            .unwrap()
            .unwrap(),
    );
    assert_eq!(method, "errors.clear");
    assert_eq!(params, json!({"fingerprints": ["ab", "cd"]}));
    assert!(parse(&args(&["errors", "list", "--limit", "0"])).is_err());
    assert!(parse(&args(&["errors", "list", "stray"])).is_err());
}

#[test]
fn open_dash_reads_urls_from_stdin_and_passes_the_callers_terminal() {
    let environment =
        std::collections::HashMap::from([("CMUX_TUI_TERMINAL_ID".to_owned(), "term_1".to_owned())]);
    let mut stdin = "https://a.example/\n\n  \nhttp://127.0.0.1:7739/o/code\r\n".as_bytes();
    let AppCommand::Open { requests, stop_on_failure } =
        parse_open_with(&args(&["-"]), false, &environment, &mut stdin).unwrap()
    else {
        panic!("expected open command")
    };
    assert!(stop_on_failure);
    let urls: Vec<_> = requests.iter().map(|request| request.params["url"].clone()).collect();
    assert_eq!(urls, vec![json!("https://a.example/"), json!("http://127.0.0.1:7739/o/code")]);
    for request in &requests {
        assert_eq!(request.method, "browser.open_split");
        assert_eq!(request.params["terminal_id"], "term_1");
        assert_eq!(request.params["focus"], false);
        assert_eq!(request.timeout(), WAITING_RUN_TIMEOUT);
    }
}

#[test]
fn open_dash_names_the_bad_line_without_echoing_it() {
    let environment = std::collections::HashMap::new();
    let mut stdin = "https://a.example/\nexample.com/?token=SECRET\n".as_bytes();
    let error = parse_open_with(&args(&["-"]), false, &environment, &mut stdin).unwrap_err();
    let message = error.to_string();
    assert!(message.contains("line 2"), "{message}");
    assert!(!message.contains("SECRET"), "{message}");
    let mut empty = "\n \n".as_bytes();
    assert!(parse_open_with(&args(&["-"]), false, &environment, &mut empty).is_err());
    let mut unused = "https://a.example/\n".as_bytes();
    assert!(
        parse_open_with(&args(&["-", "https://b.example/"]), false, &environment, &mut unused)
            .is_err()
    );
}

#[test]
fn open_workspace_names_the_workspace_and_defaults_to_no_focus() {
    let environment = std::collections::HashMap::new();
    for given in [
        vec!["--workspace", "ws_1", "https://a.example/"],
        vec!["--workspace=ws_1", "https://a.example/"],
    ] {
        let AppCommand::Open { requests, .. } =
            parse_open_with(&args(&given), true, &environment, &mut std::io::empty()).unwrap()
        else {
            panic!("expected open command")
        };
        assert_eq!(requests[0].params["workspace_id"], "ws_1");
        assert_eq!(requests[0].params["focus"], false, "a named workspace keeps the view");
    }
    let AppCommand::Open { requests, .. } = parse_open_with(
        &args(&["--workspace", "ws_1", "--focus", "https://a.example/"]),
        false,
        &environment,
        &mut std::io::empty(),
    )
    .unwrap() else {
        panic!("expected open command")
    };
    assert_eq!(requests[0].params["focus"], true);
    assert!(
        parse_open_with(
            &args(&["--workspace", "ws_1", "/tmp"]),
            false,
            &environment,
            &mut std::io::empty()
        )
        .is_err(),
        "--workspace is for URLs"
    );
}

#[test]
fn web_urls_are_absolute_http_with_a_host() {
    for good in [
        "https://example.com",
        "http://127.0.0.1:7739/o/x",
        "HTTPS://EXAMPLE.COM/a?b#c",
        "http://[::1]:80/",
    ] {
        assert!(is_web_url(good), "{good}");
    }
    for bad in [
        "",
        "example.com",
        "https://",
        "https:///path",
        "javascript:alert(1)",
        "file:///etc",
        "mailto:a@b.c",
        "https://a b.com/",
        "https://a.com/\u{7}",
    ] {
        assert!(!is_web_url(bad), "{bad}");
    }
}

fn local(command: AppCommand) -> Result<Value, Value> {
    match command {
        AppCommand::Settings(settings::Command::Local(answer)) => answer,
        _ => panic!("expected a local answer"),
    }
}

#[test]
fn config_is_the_settings_scope() {
    assert_eq!(
        call(parse(&args(&["config", "set", "sidebar.side", "right"])).unwrap().unwrap()),
        ("settings.set", json!({ "path": "sidebar.side", "value": "right" }))
    );
    assert_eq!(
        call(parse(&args(&["config", "get", "sidebar.side"])).unwrap().unwrap()),
        ("settings.get", json!({ "path": "sidebar.side" }))
    );
}

#[test]
fn settings_list_keys_and_schema_answer_without_the_app() {
    let keys = local(parse(&args(&["settings", "list", "--keys"])).unwrap().unwrap()).unwrap();
    assert_eq!(
        local(parse(&args(&["settings", "list", "--keys", "--keys"])).unwrap().unwrap()).unwrap(),
        keys,
        "repeated completion flag remains harmless",
    );
    let keys: Vec<&str> =
        keys.as_array().unwrap().iter().map(|key| key.as_str().unwrap()).collect();
    assert!(keys.contains(&"sidebar.side") && keys.contains(&"appearance.theme"), "{keys:?}");
    assert!(keys.windows(2).all(|pair| pair[0] < pair[1]), "sorted, no duplicates");
    let section = local(
        parse(&args(&["config", "list", "--keys", "--section", "browser"])).unwrap().unwrap(),
    )
    .unwrap();
    let section = section.as_array().unwrap();
    assert!(!section.is_empty() && section.len() < keys.len());
    assert!(!section.contains(&json!("sidebar.side")));

    let AppCommand::Settings(settings::Command::Document(schema)) =
        parse(&args(&["settings", "schema"])).unwrap().unwrap()
    else {
        panic!("schema is a local document")
    };
    assert_eq!(schema["$schema"], "https://json-schema.org/draft/2020-12/schema");
    assert_eq!(
        schema["properties"]["sidebar"]["properties"]["side"]["enum"],
        json!(["left", "right"])
    );
    assert!(parse(&args(&["settings", "schema", "extra"])).is_err());
    assert!(parse(&args(&["settings", "list", "--nope"])).is_err());
    assert!(parse(&args(&["settings", "list", "--section"])).is_err());
}

#[test]
fn settings_list_leaves_value_reads_to_the_daemon() {
    for scope in ["settings", "config"] {
        assert!(parse(&args(&[scope, "list"])).unwrap().is_none());
        assert!(parse(&args(&[scope, "list", "--section", "appearance"])).unwrap().is_none());
    }
    let error = parse(&args(&["settings", "list", "--section", "nope"])).err().unwrap();
    assert!(error.to_string().contains("appearance"), "{error}");
    assert!(
        parse(&args(&["settings", "list", "--section", "browser", "--section", "general"]))
            .is_err()
    );
}

#[test]
fn settings_validate_reports_what_the_owner_would() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("cmux-next.json");
    let validate = |text: &str| {
        std::fs::write(&file, text).unwrap();
        let path = file.display().to_string();
        local(parse(&args(&["config", "validate", path.as_str()])).unwrap().unwrap())
    };
    let ok = validate("// my rice\n{ \"sidebar\": { \"side\": \"right\", }, \"actions\": {} }\n")
        .unwrap();
    assert_eq!(ok["valid"], true);

    let error = validate(
        "{ \"sidebar\": { \"side\": \"top\" }, \"appearance\": { \"glassTransparency\": 9 } }",
    )
    .unwrap_err();
    assert_eq!(error["code"], "settings.invalid");
    let keys: Vec<&Value> =
        error["details"]["diagnostics"].as_array().unwrap().iter().map(|d| &d["path"]).collect();
    assert!(
        keys.contains(&&json!("sidebar.side"))
            && keys.contains(&&json!("appearance.glassTransparency")),
        "{keys:?}"
    );
    let message = error["message"].as_str().unwrap();
    assert!(
        message.contains("sidebar.side does not accept \"top\"; expected one of left, right"),
        "{message}"
    );
    assert!(message.contains("expected a number from 0 to 1"), "{message}");
    let side = error["details"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["path"] == "sidebar.side")
        .unwrap();
    assert_eq!(side["accepted"], json!({ "choices": ["left", "right"] }));

    let broken = validate("{ \"sidebar\": ").unwrap_err();
    assert_eq!(broken["details"]["diagnostics"][0]["kind"], "unreadable_file");

    let missing = dir.path().join("nope.json").display().to_string();
    let missing =
        local(parse(&args(&["settings", "validate", missing.as_str()])).unwrap().unwrap());
    assert_eq!(missing.unwrap_err()["code"], "settings.unreadable");
}

/// Lawrence 2026-10-19: `cmux <noun> move-to-window --new` moves the object
/// to a new window, as `cmux <noun> move-to-new-window` does, for every noun.
#[test]
fn move_to_window_new_is_move_to_new_window() {
    for noun in
        ["tab", "tab-group", "pane", "workspace", "workspace-group", "screen", "screen-group"]
    {
        let name = format!("{noun} move-to-window");
        assert_eq!(
            new_window_spelling(&name, &args(&["--new", "--target", "x1"])),
            Some((format!("{noun} move-to-new-window"), args(&["--target", "x1"]))),
            "{noun}"
        );
        assert_eq!(
            new_window_spelling(&name, &args(&["--target", "x1", "--new=true"])),
            Some((format!("{noun} move-to-new-window"), args(&["--target", "x1"]))),
            "{noun} --new=true"
        );
    }
    // Without --new it names a window: the action keeps its own name.
    assert_eq!(new_window_spelling("workspace move-to-window", &args(&["--window", "w1"])), None);
    assert_eq!(new_window_spelling("workspace move-to-window", &args(&["--new=false"])), None);
    assert_eq!(new_window_spelling("workspace rename", &args(&["--new"])), None);
}

/// A Chief turn (`CMUX_CALLER_HOME_CHAT=1`, set by the Chief host) names the
/// Home chat too, so the app opens its tabs beside Home's chat when it does not
/// know the turn's agent session (a Cloud Chief turn on a VM, or a local turn).
#[test]
fn a_chief_turn_names_the_home_chat_as_its_caller() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    };
    assert_eq!(
        caller_from(env(&[("CMUX_AGENT_SESSION", "turn-1"), ("CMUX_CALLER_HOME_CHAT", "1")])),
        Some(json!({ "agent_session": "turn-1", "home_chat": true }))
    );
    assert_eq!(
        caller_from(env(&[("CMUX_CALLER_HOME_CHAT", "1")])),
        Some(json!({ "home_chat": true }))
    );
    assert_eq!(
        caller_from(env(&[("CMUX_AGENT_SESSION", "turn-1")])),
        Some(json!({ "agent_session": "turn-1" }))
    );
    assert_eq!(caller_from(env(&[("CMUX_CALLER_HOME_CHAT", "0")])), None);
}

/// The agent cursor's tag says who drives and where, and goes there on a click
/// (user, 2026-10-20): every page input verb sends its caller, so the app knows
/// the agent's terminal or chat. Reads and navigation do not need it.
#[test]
fn page_input_verbs_send_the_caller() {
    for method in
        ["browser.page.click", "browser.page.fill", "browser.page.press", "browser.page.drag"]
    {
        assert!(takes_caller(method), "{method}");
    }
    for method in ["browser.page.text", "browser.page.navigate", "browser.page.screenshot"] {
        assert!(!takes_caller(method), "{method}");
    }
    assert!(takes_caller("action.run"));
}

#[path = "right_tests.rs"]
mod right;

#[test]
fn only_reads_and_keyed_runs_are_resent_after_a_dropped_connection() {
    use super::run::safe_to_resend;
    assert!(safe_to_resend("system.identify", &json!({})));
    assert!(safe_to_resend("action.run", &json!({ "idempotency_key": "mutation_1" })));
    assert!(!safe_to_resend("action.run", &json!({})));
    assert!(!safe_to_resend("errors.clear", &json!({})));
}

#[test]
fn open_link_sends_browser_open_link_with_the_callers_and_terminal() {
    let environment =
        std::collections::HashMap::from([("CMUX_TUI_TERMINAL_ID".to_owned(), "term_1".to_owned())]);
    let mut stdin = "https://signin.aws.amazon.com/oauth?state=x\n".as_bytes();
    let AppCommand::Open { requests, stop_on_failure } = parse_open_with(
        &args(&["--link", "--caller", "python3,aws", "--caller=zsh", "-"]),
        false,
        &environment,
        &mut stdin,
    )
    .unwrap() else {
        panic!("expected open command")
    };
    assert!(stop_on_failure);
    assert_eq!(requests.len(), 1);
    let request = &requests[0];
    assert_eq!(request.method, "browser.open_link");
    assert_eq!(request.params["url"], "https://signin.aws.amazon.com/oauth?state=x");
    assert_eq!(request.params["callers"], json!(["python3", "aws", "zsh"]));
    assert_eq!(request.params["terminal_id"], "term_1");
    assert_eq!(request.params["focus"], false, "a program's browser keeps the terminal's keyboard");
    assert!(request.params.get("target").is_none());

    let AppCommand::Open { requests, .. } = parse_open_with(
        &args(&["--link", "--target", "chrome@Work", "https://a.example/"]),
        false,
        &environment,
        &mut std::io::empty(),
    )
    .unwrap() else {
        panic!("expected open command")
    };
    assert_eq!(requests[0].params["target"], "chrome@Work");
}

#[test]
fn open_link_refuses_files_workspaces_and_stray_flags_without_echoing_urls() {
    let environment = std::collections::HashMap::new();
    let error = parse_open_with(
        &args(&["--link", "https://a.example/", "/tmp/notes?token=SECRET"]),
        false,
        &environment,
        &mut std::io::empty(),
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("argument 2"), "{error}");
    assert!(!error.contains("SECRET"), "{error}");
    assert!(
        parse_open_with(
            &args(&["--link", "--workspace", "ws_1", "https://a.example/"]),
            false,
            &environment,
            &mut std::io::empty()
        )
        .is_err()
    );
    for stray in [
        vec!["--caller", "aws", "https://a.example/"],
        vec!["--target", "system", "https://a.example/"],
    ] {
        assert!(
            parse_open_with(&args(&stray), false, &environment, &mut std::io::empty()).is_err(),
            "{stray:?} needs --link"
        );
    }
}
