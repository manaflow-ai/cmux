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
        Request::Screenshot { out: "/tmp/a.png".into(), window: Some("w1".into()), machine: None }
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
