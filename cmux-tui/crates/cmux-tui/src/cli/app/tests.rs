use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn call(command: AppCommand) -> (&'static str, Value) {
    match command {
        AppCommand::Call { method, params, .. } => (method, params),
        AppCommand::Open { .. } | AppCommand::Events { .. } => panic!("expected a call"),
    }
}

#[test]
fn non_app_scopes_are_left_to_the_resource_grammar() {
    assert_eq!(parse(&args(&["workspace", "list"])).unwrap(), None);
    assert_eq!(parse(&args(&[])).unwrap(), None);
}

#[test]
fn history_and_bookmark_reads_call_the_app_and_other_words_run_actions() {
    let (method, params) = call(
        parse(&args(&["history", "search", "cmux", "--kind", "page", "--limit", "5"]))
            .unwrap()
            .unwrap(),
    );
    assert_eq!(method, "history.list");
    assert_eq!(params, json!({ "text": "cmux", "kind": "page", "limit": 5 }));
    let (method, params) =
        call(parse(&args(&["bookmark", "list", "--folder", "Work"])).unwrap().unwrap());
    assert_eq!(method, "bookmark.list");
    assert_eq!(params, json!({ "folder": "Work" }));
    assert!(parse(&args(&["history", "search"])).is_err());
    assert!(parse(&args(&["bookmark", "list", "--limit", "0"])).is_err());
    assert_eq!(call(parse(&args(&["accounts", "list"])).unwrap().unwrap()).0, "accounts.list");
    let (method, params) = call(parse(&args(&["history", "reopen"])).unwrap().unwrap());
    assert_eq!(method, "action.run");
    assert_eq!(params["action"], "history reopen");
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
    assert_eq!(*timeout, READ_TIMEOUT);
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
    use std::os::unix::net::UnixListener;
    let dir = std::env::temp_dir().join(format!(
        "cmux-app-cli-{}-{}",
        std::process::id(),
        super::super::command::random_prefixed("t").unwrap()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("app.sock");
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
            writeln!(writer, "{response}").unwrap();
        }
        connections.push(received);
        listener.set_nonblocking(true).unwrap();
        if let Ok((stream, _)) = listener.accept() {
            let mut extra = String::new();
            let _ = BufReader::new(stream).read_line(&mut extra);
            connections.push(vec![json!(extra)]);
        }
        let _ = std::fs::remove_dir_all(dir);
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
fn app_requests_wait_for_the_app_to_catch_up_with_the_daemon() {
    assert_eq!(
        with_read_barrier(json!({ "action": "x" })),
        json!({ "action": "x", "after": "sync" })
    );
    assert_eq!(with_read_barrier(json!({ "after": 12 })), json!({ "after": 12 }));
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
fn open_directory_passes_focus_and_activate_for_both_flags() {
    let root = std::env::temp_dir().join(format!("cmux-open-test-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let root_text = root.to_string_lossy().into_owned();
    let environment = std::collections::HashMap::new();
    for (flags, expected) in [(vec!["--focus", "true"], true), (Vec::new(), false)] {
        let mut command_args = flags.into_iter().map(String::from).collect::<Vec<_>>();
        command_args.push(root.to_string_lossy().into_owned());
        let AppCommand::Open { requests } =
            parse_open_with(&command_args, false, &environment).unwrap()
        else {
            panic!("expected open command")
        };
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].method, "workspace.create");
        assert_eq!(requests[0].params["cwd"].as_str(), Some(root_text.as_str()));
        assert_eq!(requests[0].params["focus"], expected);
        assert_eq!(requests[0].params["activate"], expected);
    }
    let _ = std::fs::remove_dir_all(root);
}
