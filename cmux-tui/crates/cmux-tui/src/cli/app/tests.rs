use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn call(command: AppCommand) -> (&'static str, Value) {
    match command {
        AppCommand::Call { method, params, .. } => (method, params),
        AppCommand::Open { .. } | AppCommand::Events { .. } | AppCommand::DebugCall { .. } => {
            panic!("expected a call")
        }
    }
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

fn global_for(socket: &std::path::Path) -> GlobalArgs {
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
fn app_requests_wait_for_the_app_to_catch_up_with_the_daemon() {
    assert_eq!(
        with_read_barrier(json!({ "action": "x" })),
        json!({ "action": "x", "after": "sync" })
    );
    assert_eq!(with_read_barrier(json!({ "after": 12 })), json!({ "after": 12 }));
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

fn identify_answer(bundle_id: &str) -> Value {
    json!({ "id": 1, "ok": true, "result": { "app": "cmux-next", "bundle_id": bundle_id, "tag": "occl1-v1" } })
}

fn app_call(socket: &std::path::Path, words: &[&str]) -> i32 {
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
