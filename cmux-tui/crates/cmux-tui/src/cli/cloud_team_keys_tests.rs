use super::*;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_status_set_and_remove_and_keeps_the_key_off_argv() {
    assert_eq!(parse(&words("status --team team_a")).unwrap().verb, Verb::Status);
    let set = parse(&words(
        "set codex --kind oauth --secret-file /tmp/auth.json --idempotency-key ck_12345678",
    ))
    .unwrap();
    assert_eq!(
        set.verb,
        Verb::Set {
            agent: "codex".into(),
            kind: "oauth".into(),
            secret_file: Some("/tmp/auth.json".into())
        }
    );
    assert_eq!(set.idempotency_key.as_deref(), Some("ck_12345678"));
    assert_eq!(
        parse(&words("set claude")).unwrap().verb,
        Verb::Set { agent: "claude".into(), kind: "api_key".into(), secret_file: None }
    );
    assert_eq!(parse(&words("rm claude")).unwrap().verb, Verb::Remove { agent: "claude".into() });
    assert_eq!(parse(&[]).unwrap().verb, Verb::Help);
    assert_eq!(parse(&words("status --help")).unwrap().verb, Verb::Help);
    assert_eq!(parse(&words("set claude --help")).unwrap().verb, Verb::Help);
    // No way to put the key itself on the command line.
    assert!(parse(&words("set claude sk-live-123456789")).is_err());
    assert!(parse(&words("set claude --secret sk-live-123456789")).is_err());
    assert!(parse(&words("set gemini")).is_err());
    assert!(parse(&words("set claude --kind password")).is_err());
    assert!(parse(&words("status --kind oauth")).is_err());
    assert!(parse(&words("remove codex --idempotency-key x")).is_err());
}

#[test]
fn resolves_the_team_from_the_flag_or_the_environment() {
    let env = |key: &str| match key {
        "CMUX_CLOUD_API_URL" => Some("https://api.example.test".to_owned()),
        "CMUX_CLOUD_ACCESS_TOKEN" => Some("tok".to_owned()),
        "CMUX_CLOUD_TEAM" => Some("team_env".to_owned()),
        _ => None,
    };
    let status = parse(&words("status")).unwrap();
    assert_eq!(resolve(&status, env).unwrap().team, "team_env");
    let flagged = parse(&words("status --team team_flag")).unwrap();
    assert_eq!(resolve(&flagged, env).unwrap().team, "team_flag");
    let none = |key: &str| if key == "CMUX_CLOUD_TEAM" { None } else { env(key) };
    assert!(resolve(&status, none).unwrap_err().contains("--team"));
    let bad = parse(&words("status --team a/b")).unwrap();
    assert!(resolve(&bad, env).is_err());
}

#[test]
fn a_replayed_set_says_so_and_a_refusal_keeps_its_code() {
    let body = br#"{"ok":true,"op":"team.agent_key.set","value":{"agent":"claude","set":true,"kind":"api_key","generation":1,"updated_at":1,"updated_by":"user_a","hint":"abcd"},"transaction":"t","idempotency_key":"ck_1","replayed":true,"stream":"s","sequence":3}"#;
    let read = cmux_cloud_client::ops::read_answer::<TeamAgentKeySetOp>(200, None, body).unwrap();
    assert_eq!(answer(read).unwrap()["replayed"], json!(true));
    let refused = br#"{"ok":false,"op":"team.agent_key.set","error":{"code":"team_agent_key.not_configured","message":"no sealing key","retryable":false},"transaction":"t","idempotency_key":"ck_1","replayed":false,"stream":"s","sequence":3}"#;
    let read =
        cmux_cloud_client::ops::read_answer::<TeamAgentKeySetOp>(200, None, refused).unwrap();
    assert_eq!(answer(read).unwrap_err().code.as_deref(), Some("team_agent_key.not_configured"));
}

#[test]
fn a_secret_file_is_read_without_its_trailing_line_break() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("key");
    std::fs::write(&path, "sk-team-0123456789\n").unwrap();
    assert_eq!(read_key("claude", Some(&path)).unwrap().as_str(), "sk-team-0123456789");
    std::fs::write(&path, "").unwrap();
    assert_eq!(read_key("claude", Some(&path)).unwrap_err().code.as_deref(), Some("usage.invalid"));
    let missing = dir.path().join("missing");
    let error = read_key("claude", Some(&missing)).unwrap_err();
    assert!(!error.message.contains("missing"), "the path stays out of the error");
}
