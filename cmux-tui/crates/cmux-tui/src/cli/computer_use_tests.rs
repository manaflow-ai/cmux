use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn the_commands_parse() {
    assert_eq!(parse(&words("tools")).unwrap(), Request::Tools);
    assert_eq!(parse(&words("mcp")).unwrap(), Request::Mcp { primary: false });
    assert_eq!(parse(&words("mcp --primary")).unwrap(), Request::Mcp { primary: true });
    assert!(parse(&words("mcp --stdio")).is_err());
    assert_eq!(parse(&words("machines")).unwrap(), Request::Machines);
    assert_eq!(
        parse(&words("status --machine studio")).unwrap(),
        Request::Call { tool: "status".into(), args: json!({}), machine: Some("studio".into()) }
    );
    let args = vec![
        "call".to_owned(),
        "click".into(),
        "--args".into(),
        r#"{"window_id":"w","x":1}"#.into(),
    ];
    assert_eq!(
        parse(&args).unwrap(),
        Request::Call {
            tool: "click".into(),
            args: json!({"window_id": "w", "x": 1}),
            machine: None
        }
    );
    assert_eq!(
        parse(&words("screenshot --out /tmp/a.png --window w1")).unwrap(),
        Request::Screenshot {
            out: "/tmp/a.png".into(),
            window: Some("w1".into()),
            display: None,
            machine: None
        }
    );
    assert_eq!(
        parse(&words("approvals forget com.apple.Notes")).unwrap(),
        Request::Approvals { action: "forget", app: Some("com.apple.Notes".into()) }
    );
    assert_eq!(
        parse(&words("approvals revoke-sessions")).unwrap(),
        Request::Approvals { action: "revoke_sessions", app: None }
    );
    assert_eq!(parse(&[]).unwrap(), Request::Help);
}

#[test]
fn bad_commands_are_usage_errors() {
    for bad in [
        "call",
        "call run_shell",
        "call click --args [1]",
        "screenshot",
        "screenshot --out",
        "approvals forget",
        "approvals",
        "settings set mode off",
        "status --force",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
    let machine_in_args =
        vec!["call".to_owned(), "click".into(), "--args".into(), r#"{"machine":"x"}"#.into()];
    assert!(parse(&machine_in_args).is_err());
}

#[test]
fn the_alerts_commands_parse() {
    let list = |machine: Option<&str>| Request::Call {
        tool: "list_alerts".into(),
        args: json!({}),
        machine: machine.map(str::to_owned),
    };
    assert_eq!(parse(&words("alerts")).unwrap(), list(None));
    assert_eq!(parse(&words("alerts --json")).unwrap(), list(None));
    assert_eq!(parse(&words("alerts --json --machine studio")).unwrap(), list(Some("studio")));
    let args: Vec<String> =
        ["alerts", "dismiss", "96", "--button", "Not Now", "--machine", "studio"]
            .iter()
            .map(|w| (*w).to_owned())
            .collect();
    assert_eq!(
        parse(&args).unwrap(),
        Request::Call {
            tool: "dismiss_alert".into(),
            args: json!({"alert_id": "96", "button": "Not Now"}),
            machine: Some("studio".into()),
        }
    );
    // No button named, no alert named, or a flag nobody knows: usage errors.
    assert!(parse(&words("alerts dismiss 96")).is_err());
    assert!(parse(&words("alerts dismiss --button OK")).is_err());
    assert!(parse(&words("alerts dismiss")).is_err());
    assert!(parse(&words("alerts dismiss 96 --button OK --force yes")).is_err());
    assert!(parse(&words("alerts --all")).is_err());
}

#[test]
fn displays_doctor_and_display_screenshots_parse() {
    assert_eq!(
        parse(&words("displays --machine studio")).unwrap(),
        Request::Call {
            tool: "list_displays".into(),
            args: json!({}),
            machine: Some("studio".into())
        }
    );
    assert_eq!(
        parse(&words("screenshot --out /tmp/a.png --display 69733382")).unwrap(),
        Request::Screenshot {
            out: "/tmp/a.png".into(),
            window: None,
            display: Some("69733382".into()),
            machine: None
        }
    );
    assert_eq!(parse(&words("doctor")).unwrap(), Request::Doctor { machine: None, json: false });
    assert_eq!(
        parse(&words("doctor --json --machine studio")).unwrap(),
        Request::Doctor { machine: Some("studio".into()), json: true }
    );
    for bad in ["screenshot --out a --window w --display 1", "doctor --fix", "displays --all"] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

mod doctor_checks {
    use super::super::doctor::{Endpoint, Reply, evaluate, human};
    use serde_json::json;

    fn ready() -> Endpoint {
        Endpoint::State(json!({"state": "ready", "pid": 7}))
    }

    fn healthy_status() -> serde_json::Value {
        json!({
            "platform": {"os": "macos"},
            "permissions": {"accessibility": "granted", "screen_capture": "granted", "input": "granted"},
            "mode": "fullAccess",
            "allow_own_machines": true,
            "screen_locked": false,
            "worker": {"executable": "/Users/p/Library/Application Support/cmux-next/screen-sharing/com.cmuxterm.app.nightly/computer-use/cmux Screen Sharing.app/Contents/MacOS/cmux-screen-sharing", "pid": 9},
        })
    }

    fn one_display() -> Reply {
        Reply::Ok(json!({"displays": [{"id": "1", "main": true, "scale": 2.0,
            "frame": {"x": 0.0, "y": 0.0, "width": 1512.0, "height": 982.0}}]}))
    }

    fn failing(checks: &[super::super::doctor::Check]) -> Vec<&'static str> {
        checks.iter().filter(|c| !c.ok).map(|c| c.name).collect()
    }

    #[test]
    fn a_healthy_machine_passes_every_check() {
        let checks = evaluate(None, &ready(), &Reply::Ok(healthy_status()), &one_display());
        assert!(failing(&checks).is_empty(), "{checks:?}");
        assert!(checks.iter().all(|c| c.fix.is_none()));
        let helper = checks.iter().find(|c| c.name == "helper").unwrap();
        assert!(
            helper.detail.contains("staged") && helper.detail.contains("com.cmuxterm.app.nightly")
        );
        assert!(human(&checks, true).contains("can capture and act"));
    }

    #[test]
    fn each_failure_names_its_fix() {
        let mut status = healthy_status();
        status["permissions"]["screen_capture"] = json!("denied");
        status["permissions"]["input"] = json!("unknown");
        status["screen_locked"] = json!(true);
        status["mode"] = json!("lookOnly");
        status["worker"]["executable"] =
            json!("/Applications/cmux NIGHTLY.app/Contents/Helpers/cmux-screen-sharing");
        let checks =
            evaluate(None, &ready(), &Reply::Ok(status), &Reply::Ok(json!({"displays": []})));
        assert_eq!(
            failing(&checks),
            ["helper", "screen_capture", "input", "screen_locked", "mode", "displays"]
        );
        for c in checks.iter().filter(|c| !c.ok) {
            assert!(c.fix.as_deref().is_some_and(|f| !f.is_empty()), "{c:?}");
        }
        assert!(human(&checks, false).contains("fix: "));
    }

    #[test]
    fn an_unreachable_daemon_or_missing_helper_stops_early() {
        let not_asked =
            Reply::Failed { code: "daemon_unreachable".into(), message: "not asked".into() };
        let checks =
            evaluate(None, &Endpoint::Unreachable("no socket".into()), &not_asked, &not_asked);
        assert_eq!(failing(&checks)[0], "daemon");

        let no_helper = "This cmux build can't run Computer Use. Install the latest cmux.";
        let endpoint = Endpoint::State(json!({"state": "unavailable", "reason": no_helper}));
        let failed =
            Reply::Failed { code: "computer_use_unavailable".into(), message: no_helper.into() };
        let checks = evaluate(None, &endpoint, &failed, &failed);
        let worker = checks.iter().find(|c| c.name == "worker").unwrap();
        assert_eq!(worker.fix.as_deref(), Some(no_helper));
    }

    #[test]
    fn off_and_other_machines() {
        let checks = evaluate(
            None,
            &ready(),
            &Reply::Ok(json!({"mode": "off", "reason": "set by the person"})),
            &Reply::Off(String::new()),
        );
        assert_eq!(failing(&checks), ["mode"]);

        let mut status = healthy_status();
        status["allow_own_machines"] = json!(false);
        status["platform"]["os"] = json!("linux");
        status["permissions"] = json!({"accessibility": "granted", "screen_capture": "not_needed", "input": "not_needed"});
        status["worker"]["executable"] = json!("/usr/bin/cmux");
        let checks = evaluate(Some("box"), &Endpoint::Skipped, &Reply::Ok(status), &one_display());
        assert_eq!(failing(&checks), ["own_machines"]);
    }
}

#[test]
fn record_parses_its_three_forms() {
    use record::RecordRequest;
    assert_eq!(
        parse(&words("record --out /tmp/a.mp4 --seconds 2.5 --display 3 --machine studio"))
            .unwrap(),
        Request::Record(RecordRequest::Whole {
            out: "/tmp/a.mp4".into(),
            seconds: 2.5,
            options: json!({"display": "3"}),
            machine: Some("studio".into()),
        })
    );
    assert_eq!(
        parse(&words("record start --max-seconds 60 --fps 15 --max-edge 1280")).unwrap(),
        Request::Record(RecordRequest::Start {
            options: json!({"max_seconds": 60.0, "fps": 15, "max_edge": 1280}),
            machine: None,
        })
    );
    assert_eq!(
        parse(&words("record stop --out a.mp4 --id rec-1")).unwrap(),
        Request::Record(RecordRequest::Stop {
            out: "a.mp4".into(),
            id: Some("rec-1".into()),
            machine: None,
        })
    );
    for bad in [
        "record",
        "record --out a.mp4",
        "record --seconds 2",
        "record --out a.mp4 --seconds 0",
        "record --out a.mp4 --seconds soon",
        "record --out a.mp4 --seconds 2 --window w1",
        "record --out a.mp4 --seconds 2 --fps fast",
        "record start --out a.mp4",
        "record start --seconds 2",
        "record stop",
        "record stop --out a.mp4 --seconds 2",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
    // Every flag the CLI sends is one the tool takes.
    let tool = tools::find("record").unwrap().schema();
    for key in
        ["action", "seconds", "max_seconds", "display", "fps", "max_edge", "recording_id", "offset"]
    {
        assert!(tool["properties"].get(key).is_some(), "{key}");
    }
}

/// What `cmux ARGS` asks the computer-use command for, globals applied.
fn request(text: &str) -> Request {
    let (global, rest) = split(&words(text)).expect("a computer-use command");
    parse(&rest).unwrap().on_machine(global.machine.as_deref())
}

#[test]
fn machine_after_the_command_reaches_the_command() {
    // The global option used to swallow these, so the call ran on this machine.
    assert_eq!(
        request("computer-use status --machine cmux16"),
        Request::Call { tool: "status".into(), args: json!({}), machine: Some("cmux16".into()) }
    );
    assert_eq!(
        request("computer-use call list_windows --machine air-blue"),
        Request::Call {
            tool: "list_windows".into(),
            args: json!({}),
            machine: Some("air-blue".into())
        }
    );
    assert_eq!(
        request("computer-use screenshot --out /tmp/a.png --machine=studio"),
        Request::Screenshot {
            out: "/tmp/a.png".into(),
            window: None,
            display: None,
            machine: Some("studio".into())
        }
    );
}

#[test]
fn machine_before_the_command_is_the_fallback() {
    assert_eq!(
        request("--machine studio computer-use status"),
        Request::Call { tool: "status".into(), args: json!({}), machine: Some("studio".into()) }
    );
    assert_eq!(
        request("--machine studio computer-use status --machine other"),
        Request::Call { tool: "status".into(), args: json!({}), machine: Some("other".into()) }
    );
    assert_eq!(
        request("computer-use status"),
        Request::Call { tool: "status".into(), args: json!({}), machine: None }
    );
    assert!(split(&words("workspace list --machine m")).is_none());
}
