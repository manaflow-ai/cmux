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
