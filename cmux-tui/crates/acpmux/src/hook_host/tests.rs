use super::*;
use serde_json::json;

fn home_with(rules: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(rules::FILE), rules).unwrap();
    dir
}

/// A free loopback port (bound, then released).
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn payload(event: &str, command: &str) -> Vec<u8> {
    json!({"session_id": "s1", "cwd": std::env::temp_dir(), "hook_event_name": event,
           "tool_name": "Bash", "tool_input": {"command": command}})
    .to_string()
    .into_bytes()
}

#[test]
fn rules_run_with_the_payload_on_stdin_and_the_callers_env() {
    let rules = r#"{"rules": [
      {"name": "echo", "events": ["PreToolUse"], "tools": "Bash", "screen": "cargo",
       "command": "printf '{\"hookSpecificOutput\":{\"additionalContext\":\"%s %s\"}}' \"$HOOK_WORD\" \"$(wc -c | tr -d ' ')\"",
       "env": ["HOOK_WORD"]}
    ]}"#;
    let config = Config::parse(rules).unwrap();
    let body = payload("PreToolUse", "cargo test");
    let p: Value = serde_json::from_slice(&body).unwrap();
    let env = HashMap::from([("HOOK_WORD".to_owned(), "hi".to_owned())]);
    let a = run_rules(&config, "PreToolUse", &p, &body, &env, None);
    // the whole payload arrived on stdin
    assert_eq!(a["hookSpecificOutput"]["additionalContext"], format!("hi {}", body.len()));
    // a call the screen does not match starts nothing
    let quiet = payload("PreToolUse", "git status");
    let q: Value = serde_json::from_slice(&quiet).unwrap();
    assert_eq!(run_rules(&config, "PreToolUse", &q, &quiet, &env, None), json!({}));
}

#[test]
fn a_rule_past_its_bound_is_left_out_and_the_others_answer() {
    let rules = r#"{"rules": [
      {"name": "slow", "events": ["Stop"], "command": "sleep 5; echo '{\"decision\":\"block\"}'",
       "timeout_s": 0.3, "kill": true},
      {"name": "deny", "events": ["Stop"], "command": "echo stop >&2; exit 2"}
    ]}"#;
    let config = Config::parse(rules).unwrap();
    let started = Instant::now();
    let a = run_rules(&config, "Stop", &json!({}), b"{}", &HashMap::new(), None);
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
    assert_eq!(a, json!({"decision": "block", "reason": "stop"}));
}

#[test]
fn requests_parse_whole_or_ask_for_more() {
    let raw = b"POST /hook/PreToolUse HTTP/1.1\r\nX-Hook-Token: t\r\nX-Env-PATH: /bin\r\nContent-Length: 2\r\n\r\n{}";
    assert!(parse_request(&raw[..raw.len() - 1]).unwrap().is_none());
    let req = parse_request(raw).unwrap().unwrap();
    assert_eq!((req.method.as_str(), req.path.as_str()), ("POST", "/hook/PreToolUse"));
    assert_eq!(req.body, b"{}");
    let env = header_env(&req.headers, &["PATH".to_owned(), "HOME".to_owned()]);
    assert_eq!(env, HashMap::from([("PATH".to_owned(), "/bin".to_owned())]));
    assert!(parse_request(b"GET / HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n").is_err());
}

#[test]
fn a_request_without_the_token_is_refused() {
    let config =
        Config::parse(r#"{"rules": [{"name": "a", "events": ["Stop"], "command": "exit 2"}]}"#)
            .unwrap();
    let throttle = Mutex::new(Throttle::default());
    let req = |token: &str| Request {
        method: "POST".into(),
        path: "/hook/Stop".into(),
        headers: HashMap::from([("x-hook-token".to_owned(), token.to_owned())]),
        body: b"{}".to_vec(),
    };
    assert_eq!(respond(&req("wrong"), Some(&config), "right", &throttle).0, 403);
    let (status, body) = respond(&req("right"), Some(&config), "right", &throttle);
    assert_eq!(status, 200);
    assert!(body.contains("block"), "{body}");
}

#[test]
fn settings_write_one_entry_per_event() {
    let config = Config::parse(
        r#"{"listen": "127.0.0.1:47999", "rules": [
          {"name": "a", "events": ["PreToolUse"], "tools": "Bash", "command": ["t"], "env": ["PATH"], "timeout_s": 7},
          {"name": "b", "events": ["PostToolUse"], "command": ["t"]}]}"#,
    )
    .unwrap();
    let http = settings(&config, "http", "tok", "/bin/acpmux").unwrap();
    let pre = &http["PreToolUse"][0];
    assert_eq!(pre["matcher"], "Bash");
    assert_eq!(pre["hooks"][0]["url"], "http://127.0.0.1:47999/hook/PreToolUse");
    assert_eq!(pre["hooks"][0]["timeout"], 12);
    assert_eq!(pre["hooks"][0]["headers"]["X-Env-PATH"], "${PATH}");
    assert_eq!(pre["hooks"][0]["headers"]["X-Hook-Token"], "tok");
    assert!(http["PostToolUse"][0].get("matcher").is_none());
    let cmd = settings(&config, "command", "tok", "/bin/acp mux").unwrap();
    assert_eq!(
        cmd["PostToolUse"][0]["hooks"][0]["command"],
        "'/bin/acp mux' hook-host run PostToolUse"
    );
    assert!(settings(&config, "carrier-pigeon", "tok", "x").is_err());
}

#[test]
fn the_client_answers_itself_when_the_host_is_down() {
    let port = free_port();
    let home = home_with(&format!(
        r#"{{"listen": "127.0.0.1:{port}", "rules": [
          {{"name": "d", "events": ["PreToolUse"], "tools": "Bash", "screen": "rm -rf",
            "command": "echo 'not that' >&2; exit 2"}}]}}"#
    ));
    token(home.path(), true).unwrap();
    let a = run_client(home.path(), "PreToolUse", &payload("PreToolUse", "rm -rf /"));
    assert_eq!(a["hookSpecificOutput"]["permissionDecision"], "deny");
    assert_eq!(run_client(home.path(), "PreToolUse", &payload("PreToolUse", "ls")), json!({}));
}

#[test]
fn no_rules_file_means_no_answer_and_no_listener() {
    let home = tempfile::tempdir().unwrap();
    assert_eq!(run_client(home.path(), "PreToolUse", b"{}"), json!({}));
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    // serve returns at once: nothing to host
    rt.block_on(async {
        tokio::time::timeout(Duration::from_secs(2), serve(home.path().to_path_buf()))
            .await
            .unwrap()
    });
    assert!(!home.path().join(TOKEN_FILE).exists());
}

#[test]
fn the_daemon_listener_answers_the_client_and_keeps_every_s() {
    let port = free_port();
    let home = home_with(&format!(
        r#"{{"listen": "127.0.0.1:{port}", "rules": [
          {{"name": "count", "events": ["PostToolUse"], "every_s": 300,
            "command": "echo x >> \"$COUNT_FILE\"; echo '{{\"hookSpecificOutput\":{{\"additionalContext\":\"ran\"}}}}'",
            "env": ["COUNT_FILE"]}}]}}"#
    ));
    let count = home.path().join("count");
    let rt =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    let h = home.path().to_path_buf();
    rt.spawn(serve(h));
    let deadline = Instant::now() + Duration::from_secs(10);
    while !home.path().join(TOKEN_FILE).exists()
        || std::net::TcpStream::connect(("127.0.0.1", port)).is_err()
    {
        assert!(Instant::now() < deadline, "the host never listened");
        std::thread::sleep(Duration::from_millis(20));
    }
    // SAFETY: this test's own variable; the client reads it on this thread.
    unsafe { std::env::set_var("COUNT_FILE", &count) };
    let body = payload("PostToolUse", "ls");
    let first = run_client(home.path(), "PostToolUse", &body);
    assert_eq!(first["hookSpecificOutput"]["additionalContext"], "ran");
    let second = run_client(home.path(), "PostToolUse", &body);
    assert_eq!(second, json!({}), "every_s held the second run");
    assert_eq!(std::fs::read_to_string(&count).unwrap().lines().count(), 1);
    rt.shutdown_background();
}
