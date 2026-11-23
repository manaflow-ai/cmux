use super::*;

fn step(name: &str, status: Status, ms: u64, detail: &str) -> Step {
    Step { step: name.to_owned(), status, ms, detail: detail.to_owned() }
}

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parse_reads_every_flag() {
    let args = parse(&words(
        "--backend staging --team t1 --model-stub /s.py --chat-timeout 5 --out /tmp/x",
    ))
    .unwrap();
    assert_eq!(args.backend, "staging");
    assert_eq!(args.team.as_deref(), Some("t1"));
    assert_eq!(args.model_stub, Some(PathBuf::from("/s.py")));
    // Clamped to at least 10 s.
    assert_eq!(args.chat_budget, Duration::from_secs(10));
    assert_eq!(args.out, Some(PathBuf::from("/tmp/x")));
    assert_eq!(args.prompt, DEFAULT_PROMPT);
    assert!(parse(&words("--bogus")).is_err());
    assert!(parse(&words("--backend")).is_err());
    assert!(parse(&words("--chat-timeout soon")).is_err());
}

#[test]
fn backends_resolve_like_the_ts_journey() {
    assert_eq!(resolve_backend("staging").unwrap().0, cmux_cloud_environment::STAGING_API);
    assert_eq!(resolve_backend("prod").unwrap().0, cmux_cloud_environment::PRODUCTION_API);
    assert_eq!(
        resolve_backend("prod").unwrap().1,
        cmux_cloud_environment::PRODUCTION_STACK_PROJECT
    );
    assert_eq!(
        resolve_backend("preview-42").unwrap().0,
        "https://cmux-api-preview-42.debussy.workers.dev"
    );
    assert!(resolve_backend("preview-").is_err());
    assert!(resolve_backend("preview-A/b").is_err());
    assert!(resolve_backend("elsewhere").is_err());
}

#[test]
fn summary_matches_the_ts_format() {
    let steps = vec![
        step("create machine", Status::Pass, 1000, "m1 status provisioning"),
        step("running (status)", Status::Pass, 2000, "host h"),
        step("first exec", Status::Pass, 300, "journey-ok"),
        step("pass Claude login", Status::Pass, 100, "none"),
        step("start agent (claude)", Status::Pass, 600, "a|b\nc"),
        step("delete", Status::Pass, 0, "m1"),
    ];
    let meta = [("tag", "jr-1".to_owned()), ("agent", "claude".to_owned())];
    let md = summary_markdown("staging", "https://api", &meta, &steps);
    let lines: Vec<&str> = md.lines().collect();
    assert_eq!(
        lines[0],
        "PASS: Cloud journey on `staging` (https://api), 4.0 s; create machine to agent running 4.0 s"
    );
    assert_eq!(lines[1], "");
    assert_eq!(lines[2], "tag: jr-1, agent: claude");
    assert_eq!(lines[4], "| result | step | ms | detail |");
    assert_eq!(lines[5], "|---|---|---:|---|");
    assert_eq!(lines[10], "| pass | start agent (claude) | 600 | a\\|b c |");
    assert!(md.ends_with('\n'));
}

#[test]
fn a_failed_step_fails_the_summary_and_drops_ready_time() {
    let steps = vec![
        step("create machine", Status::Pass, 1000, ""),
        step("running (status)", Status::Fail, 2000, "timeout"),
        step("delete", Status::Skip, 0, ""),
    ];
    let md = summary_markdown("dev", "https://api", &[], &steps);
    assert!(md.starts_with("FAIL: Cloud journey on `dev` (https://api), 3.0 s\n"));
    assert!(md.contains("| **FAIL** | running (status) | 2000 | timeout |"));
    assert!(md.contains("| skip | delete | 0 |  |"));
    assert_eq!(ready_ms(&steps), None);
}

#[test]
fn the_launch_credential_rides_the_heredoc_not_argv() {
    let program = launch_credential_program(
        "journey-jr-1",
        "claude",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "sk-ant-oat01-x'y\"z",
    );
    let first = program.lines().next().unwrap();
    assert_eq!(first, "python3 -I - <<'CMUX_JOURNEY_START'");
    assert!(!first.contains("sk-ant"));
    assert!(program.ends_with("CMUX_JOURNEY_START"));
    // The params are one Python string literal that json.loads reads back.
    let literal = program.lines().find(|l| l.starts_with("params = json.loads(")).unwrap();
    let inner = literal.trim_start_matches("params = json.loads(").trim_end_matches(')');
    let text: String = serde_json::from_str(inner).unwrap();
    let params: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(params["_meta"]["acpmux"]["name"], "journey-jr-1");
    assert_eq!(
        params["_meta"]["acpmux"]["credentials"]["env"]["CLAUDE_CODE_OAUTH_TOKEN"],
        "sk-ant-oat01-x'y\"z"
    );
}

#[test]
fn stub_reply_needs_the_nonce_and_the_tool_output() {
    assert!(stub_reply_ok("Stub reply ab12. The tool printed ab12-tool.", "ab12"));
    assert!(!stub_reply_ok("Stub reply ab12.", "ab12"));
    assert!(!stub_reply_ok("Stub reply zz. The tool printed zz-tool.", "ab12"));
}

#[test]
fn shell_quoting_survives_single_quotes() {
    assert_eq!(shq("it's"), "'it'\\''s'");
}

#[test]
fn run_tags_look_like_the_ts_tags() {
    let tag = run_tag();
    assert!(tag.starts_with("jr-"));
    assert!(tag[3..].bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase()));
}
