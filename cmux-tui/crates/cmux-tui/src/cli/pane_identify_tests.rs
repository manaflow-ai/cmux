use super::*;

fn record(pairs: &[(&str, &str)]) -> Value {
    Value::Object(pairs.iter().map(|(k, v)| ((*k).to_owned(), json!(v))).collect())
}

/// The caller path follows terminal, tab, pane, screen and workspace in
/// that order, and keeps the names the app's caller lacks.
#[test]
fn identify_follows_the_terminal_to_its_workspace() {
    let mut asked = Vec::new();
    let mut read = |operation: ResourceOperation,
                    extra: Option<(&str, &str)>|
     -> Result<Value, Failure> {
        asked.push((operation.wire_name().to_owned(), extra.map(|(_, id)| id.to_owned())));
        Ok(match operation {
            ResourceOperation::TerminalGet => record(&[("id", "term_1"), ("tab_id", "tab_1")]),
            ResourceOperation::TabGet => {
                record(&[("id", "tab_1"), ("pane_id", "pane_1"), ("name", "logs")])
            }
            ResourceOperation::PaneGet => record(&[("id", "pane_1"), ("screen_id", "screen_1")]),
            ResourceOperation::ScreenGet => {
                record(&[("id", "screen_1"), ("workspace_id", "ws_1"), ("name", "main")])
            }
            ResourceOperation::WorkspaceGet => record(&[("id", "ws_1"), ("name", "api")]),
            _ => Value::Null,
        })
    };
    let mut records = CallerRecords::default();
    assert!(caller_records(&mut read, "term_1", &mut records).is_ok());
    let caller = records.caller("term_1");
    assert_eq!(
        asked.iter().map(|(operation, _)| operation.as_str()).collect::<Vec<_>>(),
        ["terminal.get", "tab.get", "pane.get", "screen.get", "workspace.get"]
    );
    assert_eq!(caller["found"], true);
    assert_eq!(caller["workspace"], "ws_1");
    assert_eq!(caller["workspace_name"], "api");
    assert_eq!(caller["screen"], "screen_1");
    assert_eq!(caller["pane"], "pane_1");
    assert_eq!(caller["tab"], "tab_1");
    assert_eq!(caller["tab_name"], "logs");
    assert_eq!(caller["terminal_id"], "term_1");
}

/// A terminal that left its tab says so instead of naming a wrong place.
#[test]
fn a_terminal_without_a_tab_is_not_found() {
    let mut read = |_: ResourceOperation, _: Option<(&str, &str)>| -> Result<Value, Failure> {
        Ok(record(&[("id", "t")]))
    };
    let mut records = CallerRecords::default();
    let Err(Failure::Resource(error)) = caller_records(&mut read, "term_9", &mut records) else {
        panic!("a terminal with no tab was placed");
    };
    assert_eq!(error["code"], "selector.not_found");
}

#[test]
fn identity_names_the_session_machine_outer_app_and_guide() {
    let value = identity_value(
        Path::new("/tmp/cmux-tui-501/bench.sock"),
        &record(&[("id", "session_1"), ("name", "bench")]),
        &record(&[("id", "machine_1"), ("name", "mac")]),
        json!({"found": true, "terminal_id": "term_1"}),
        json!({"socket_path": "/x/cmux.sock", "identify": "cmux app identify"}),
    );
    assert_eq!(value["kind"], "cmux-tui");
    assert_eq!(value["session"], json!({"id": "session_1", "name": "bench"}));
    assert_eq!(value["machine"], json!({"id": "machine_1", "name": "mac"}));
    assert_eq!(value["socket_path"], "/tmp/cmux-tui-501/bench.sock");
    assert_eq!(value["outer_app"]["identify"], "cmux app identify");
    assert_eq!(value["guide"], "cmux skill show");
    let text = human(&value);
    assert!(text.contains("session_1 bench"), "{text}");
    assert!(text.contains("/x/cmux.sock (`cmux app identify`)"), "{text}");
}

/// With no app, identify still answers from the daemon and says why no
/// app answered.
#[test]
fn a_headless_identity_says_no_app_answered() {
    let value = without_app(
        identity_value(
            Path::new("/run/cmux-tui/main.sock"),
            &record(&[("id", "session_1"), ("name", "main")]),
            &record(&[("id", "machine_1"), ("name", "runner")]),
            json!({"found": false, "terminal_id": null, "error": {"message": "outside"}}),
            Value::Null,
        ),
        &json!({"code": "app.not_found", "message": "no cmux app found", "details": {}}),
    );
    assert_eq!(value["app_connected"], false);
    assert_eq!(value["app"], Value::Null);
    assert_eq!(
        value["app_error"],
        json!({"code": "app.not_found", "message": "no cmux app found"})
    );
    assert_eq!(value["session"]["name"], "main");
    let text = human(&value);
    assert!(text.contains(crate::localization::catalog().pane_cli.no_app), "{text}");
}

/// W5-Q (bench round 4 orchestration #3): `identify` says when the
/// `cmux` that runs is not the session daemon's build, and which `cmux`
/// is (`cli_path`). The bench's `cmux` on PATH was an old install.
#[test]
fn w5q_identify_warns_when_this_cmux_is_not_the_daemons_build() {
    let identity = || {
        identity_value(
            Path::new("/tmp/s.sock"),
            &record(&[("id", "session_1"), ("name", "bench")]),
            &record(&[("id", "machine_1"), ("name", "mac")]),
            json!({"found": true, "terminal_id": "term_1"}),
            Value::Null,
        )
    };
    let daemon = super::super::skew::DaemonBuild {
        build_id: "cmux-tui 0.9 (def456)".into(),
        cli_path: "/Applications/cmux.app/Contents/Resources/bin/cmux".into(),
        pid: 7,
    };
    let in_pane = Reach::Local { pane_cli: Some("/opt/cmux/bin/cmux") };
    let mut other = identity();
    with_build(&mut other, "cmux-tui 0.1 (abc123)", Some(&daemon), in_pane);
    assert_eq!(other["build"]["cli"], "cmux-tui 0.1 (abc123)", "{other}");
    assert_eq!(other["build"]["daemon"], "cmux-tui 0.9 (def456)", "{other}");
    assert_eq!(other["build"]["matches"], false, "{other}");
    let warning = other["warning"].as_str().unwrap_or_default();
    assert!(warning.contains("def456") && warning.contains("abc123"), "{other}");
    assert!(warning.contains("/Applications/cmux.app/Contents/Resources/bin/cmux"), "{other}");
    assert!(human(&other).contains(warning), "{}", human(&other));

    let mut same = identity();
    with_build(&mut same, "cmux-tui 0.9 (def456)", Some(&daemon), in_pane);
    assert_eq!(same["build"]["matches"], true, "{same}");
    assert_eq!(same["warning"], Value::Null, "{same}");

    // A daemon too old to say its build: nothing to compare, no warning.
    let mut unknown = identity();
    with_build(&mut unknown, "cmux-tui 0.1 (abc123)", None, in_pane);
    assert_eq!(unknown["build"]["daemon"], Value::Null, "{unknown}");
    assert_eq!(unknown["warning"], Value::Null, "{unknown}");
}

/// W5-Q review (PR B finding 5): a tunnel's daemon runs on another
/// machine, so its `cmux` path is not here: the warning names the
/// remote upgrade, as the CLI's skew line does. Outside a pane
/// (`CMUX_TUI_CLI` not set) the warning names only the daemon's `cmux`.
#[test]
fn w5q_identify_warns_by_how_it_reached_the_daemon() {
    let mut identity = identity_value(
        Path::new("/tmp/s.sock"),
        &record(&[("id", "session_1"), ("name", "bench")]),
        &record(&[("id", "machine_1"), ("name", "mac")]),
        json!({"found": true, "terminal_id": "term_1"}),
        Value::Null,
    );
    let daemon = super::super::skew::DaemonBuild {
        build_id: "cmux-tui 0.9 (def456)".into(),
        cli_path: "/remote/only/bin/cmux".into(),
        pid: 7,
    };
    let mut tunnel = identity.clone();
    let socket = Path::new("/tmp/w5q-no-route-record.sock");
    with_build(&mut tunnel, "cmux-tui 0.1 (abc123)", Some(&daemon), Reach::Tunnel { socket });
    let warning = tunnel["warning"].as_str().unwrap_or_default().to_owned();
    assert!(warning.contains("def456"), "{tunnel}");
    assert!(!warning.contains("/remote/only/bin/cmux"), "a remote path: {warning}");
    assert!(!warning.contains("CMUX_TUI_CLI"), "{warning}");

    let local = Reach::Local { pane_cli: None };
    with_build(&mut identity, "cmux-tui 0.1 (abc123)", Some(&daemon), local);
    let warning = identity["warning"].as_str().unwrap_or_default();
    assert!(warning.contains("/remote/only/bin/cmux"), "{warning}");
    assert!(!warning.contains("CMUX_TUI_CLI"), "outside a pane: {warning}");
}

/// W5-Q follow-up (PR B review): the warning says `"$CMUX_TUI_CLI"` only
/// when that path is the target daemon's own `cmux` file (the same path,
/// or a link to it). A pane's `CMUX_TUI_CLI` names its own session's
/// `cmux`; a `--socket` to another session's daemon needs that daemon's
/// `cmux`, so the warning names its path.
#[test]
fn w5q_identify_names_cmux_tui_cli_only_for_the_daemons_own_file() {
    let dir = std::env::temp_dir().join(format!(
        "w5q-identify-cli-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos())
    ));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let daemon_cli = dir.join("cmux");
    std::fs::write(&daemon_cli, b"").expect("daemon cmux file");
    let link = dir.join("cmux-link");
    std::os::unix::fs::symlink(&daemon_cli, &link).expect("link to the daemon cmux");
    let other_cli = dir.join("other-cmux");
    std::fs::write(&other_cli, b"").expect("another cmux file");
    let daemon = super::super::skew::DaemonBuild {
        build_id: "cmux-tui 0.9 (def456)".into(),
        cli_path: daemon_cli.clone(),
        pid: 7,
    };
    let warning = |pane_cli: &Path| {
        let mut identity = identity_value(
            Path::new("/tmp/s.sock"),
            &record(&[("id", "session_1"), ("name", "bench")]),
            &record(&[("id", "machine_1"), ("name", "mac")]),
            json!({"found": true, "terminal_id": "term_1"}),
            Value::Null,
        );
        let pane_cli = pane_cli.to_str().unwrap_or_default();
        let reach = Reach::Local { pane_cli: Some(pane_cli) };
        with_build(&mut identity, "cmux-tui 0.1 (abc123)", Some(&daemon), reach);
        identity["warning"].as_str().unwrap_or_default().to_owned()
    };
    let daemon_path = daemon_cli.display().to_string();

    let other = warning(&other_cli);
    assert!(!other.contains("CMUX_TUI_CLI"), "another session's cmux: {other}");
    assert!(other.contains(&daemon_path), "{other}");
    let missing = warning(Path::new("/opt/w5q-no-such/bin/cmux"));
    assert!(!missing.contains("CMUX_TUI_CLI"), "a cmux that is not there: {missing}");
    assert!(missing.contains(&daemon_path), "{missing}");

    let same = warning(&daemon_cli);
    assert!(same.contains("\"$CMUX_TUI_CLI\""), "the daemon's own cmux: {same}");
    let linked = warning(&link);
    assert!(linked.contains("\"$CMUX_TUI_CLI\""), "a link to the daemon's cmux: {linked}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `machine.get` refuses a session parameter ("unknown parameters").
#[test]
fn the_machine_read_names_no_session() {
    assert!(route(ResourceOperation::MachineGet).get("session").is_none());
    assert_eq!(route(ResourceOperation::MachineGet)["machine"], "current");
    assert_eq!(route(ResourceOperation::SessionGet)["session"], "current");
    assert_eq!(route(ResourceOperation::TerminalGet)["session"], "current");
}

#[test]
fn an_explicit_route_keeps_the_classic_identify() {
    let mut global = GlobalArgs::default();
    assert!(!explicitly_routed(&global));
    global.session = Some("other".into());
    assert!(explicitly_routed(&global));
    let global = GlobalArgs { app_socket: Some("/x/cmux.sock".into()), ..GlobalArgs::default() };
    assert!(explicitly_routed(&global));
}
