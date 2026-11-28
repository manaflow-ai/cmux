use super::*;

const TOKEN: &str = "sk-ant-oat01-missed-host-fixture";
const TOKEN_ENV: &str = "CLAUDE_CODE_OAUTH_TOKEN";

async fn token_chat(tag: &str) -> (Daemon, String, Value) {
    use std::os::unix::fs::PermissionsExt as _;

    let mut daemon = Daemon::new(tag, "approve-all");
    daemon.sigterm();
    let launcher = daemon.home.join("claude");
    std::fs::copy(FAKE, &launcher).unwrap();
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({
            "harnesses": {
                "claude": {"argv": [launcher], "kind": "claude-stdio"},
                "claude-fake": {"argv": [launcher], "family": "claude"}
            },
            "defaultHarness": "claude-fake", "permissionPolicy": "approve-all"
        })
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let created = rpc
        .call(
            "session/new",
            json!({"cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {
                "credentials": {"env": {TOKEN_ENV: TOKEN}, "connection": "claude-token"}
            }}}),
        )
        .await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    let host = daemon.host_record(&session);
    (daemon, session, host)
}

async fn restart_after_recovery(daemon: &mut Daemon, session: &str, miss_host: bool) -> Rpc {
    daemon.sigterm();

    // Leave the saved result of a completed recovery.
    let path = daemon.saved_meta_path(session);
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    meta["claudeTokenRecovery"] = json!("machineLogin");
    meta["claudeLoginRestartPending"] = json!(true);
    meta.as_object_mut().unwrap().remove("credentialConnection");
    std::fs::write(path, meta.to_string()).unwrap();
    let hidden = daemon.home.join("records-hidden");
    if miss_host {
        std::fs::write(&hidden, "").unwrap();
        daemon
            .env
            .push(("ACPMUX_TEST_HOST_RECORDS_FAIL_FILE".into(), hidden.display().to_string()));
    }
    daemon.start();
    let mut rpc = daemon.rpc().await;
    // The health request waits for startup, including the adoption pass.
    rpc.call("_acpmux/harness/health", json!({})).await;
    if miss_host {
        assert!(!daemon.events(session).iter().any(|event| event["kind"] == "host_adopted"));
        std::fs::remove_file(hidden).unwrap();
    }
    rpc
}

#[tokio::test]
async fn the_first_prompt_after_missed_adoption_uses_the_machine_login() {
    let (mut daemon, session, host) = token_chat("r9-adopt").await;
    let old_host = host["host_pid"].as_i64().unwrap();
    let old_harness = host["harness_pid"].as_i64().unwrap();
    let mut rpc = restart_after_recovery(&mut daemon, &session, true).await;
    assert!(alive(old_host));
    rpc.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {TOKEN_ENV}")}]}),
    )
    .await;
    daemon.wait_event(&session, "the new agent's token status", |event| {
        chunk(event, "CLAUDE_CODE_OAUTH_TOKEN=")
    });
    assert!(
        !daemon.events(&session).iter().any(|event| chunk(event, &format!("{TOKEN_ENV}={TOKEN}")))
    );
    assert_ne!(daemon.host_record(&session)["host_pid"].as_i64(), Some(old_host));
    assert!(gone_within(old_host, Duration::from_secs(10)));
    assert!(gone_within(old_harness, Duration::from_secs(10)));
}

async fn prompt_reply(rpc: &mut Rpc, session: &str) -> Value {
    rpc.reply(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "recovery fixture prompt"}]}),
    )
    .await
}

fn assert_old_child_untouched(daemon: &Daemon, session: &str, host: &Value) {
    assert_eq!(daemon.host_record(session)["host_pid"], host["host_pid"]);
    assert!(alive(host["host_pid"].as_i64().unwrap()));
    assert!(alive(host["harness_pid"].as_i64().unwrap()));
    let events = daemon.events(session);
    assert!(!events.iter().any(|event| {
        event["dir"] == "out" && event["msg"]["method"] == "session/prompt"
            || chunk(event, "echo: recovery fixture prompt")
    }));
}

#[tokio::test]
async fn recovery_keeps_the_live_host_when_readoption_fails() {
    let (mut daemon, session, host) = token_chat("r9-missed").await;
    let mut rpc = restart_after_recovery(&mut daemon, &session, true).await;
    // Keep the nonce and live lock readable, but leave readoption with no reachable socket.
    let socket = Path::new(host["socket"].as_str().unwrap());
    std::fs::rename(socket, socket.with_extension("offline")).unwrap();

    let reply = prompt_reply(&mut rpc, &session).await;
    assert_eq!(reply["error"]["data"]["reason"], "credentials.claude_login_busy", "{reply}");
    assert_old_child_untouched(&daemon, &session, &host);
}

#[tokio::test]
async fn recovery_keeps_the_live_host_after_partial_replay() {
    let (mut daemon, session, host) = token_chat("r9-partial").await;
    daemon.env.push(("ACPMUX_TEST_REPLAY_INCOMPLETE".into(), "1".into()));
    let mut rpc = restart_after_recovery(&mut daemon, &session, true).await;

    let reply = prompt_reply(&mut rpc, &session).await;
    assert_eq!(reply["error"]["data"]["reason"], "credentials.claude_login_busy", "{reply}");
    assert!(daemon.events(&session).iter().any(|event| event["kind"] == "host_adopted"));
    assert_old_child_untouched(&daemon, &session, &host);
}

#[tokio::test]
async fn recovery_rechecks_replay_after_a_transient_timeout() {
    let (mut daemon, session, host) = token_chat("r10-retry-replay").await;
    let replay_gate = daemon.home.join("replay-stalled");
    std::fs::write(&replay_gate, "").unwrap();
    daemon.env.push((
        "ACPMUX_TEST_REPLAY_INCOMPLETE_FILE".into(),
        replay_gate.to_string_lossy().into_owned(),
    ));
    let mut rpc = restart_after_recovery(&mut daemon, &session, false).await;

    let reply = prompt_reply(&mut rpc, &session).await;
    assert_eq!(reply["error"]["data"]["reason"], "credentials.claude_login_busy", "{reply}");
    assert_old_child_untouched(&daemon, &session, &host);

    std::fs::remove_file(replay_gate).unwrap();
    let reply = prompt_reply(&mut rpc, &session).await;
    assert_eq!(reply["result"]["stopReason"], "end_turn", "{reply}");
    assert_ne!(daemon.host_record(&session)["host_pid"], host["host_pid"]);
}

#[tokio::test]
async fn recovery_rechecks_an_incomplete_replay_after_the_open_turn_ends() {
    let (mut daemon, session, host) = token_chat("r11-open-replay").await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let mut old_client = daemon.rpc().await;
    old_client.send(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("gate: {}", gate.display())}]}),
    ).await;
    daemon.wait_event(&session, "the open turn's first chunk", |e| chunk(e, "before-gate"));

    let replay_gate = daemon.home.join("replay-stalled");
    std::fs::write(&replay_gate, "").unwrap();
    daemon.env.push((
        "ACPMUX_TEST_REPLAY_INCOMPLETE_FILE".into(),
        replay_gate.to_string_lossy().into_owned(),
    ));
    let mut rpc = restart_after_recovery(&mut daemon, &session, false).await;
    assert!(daemon.events(&session).iter().any(|event| event["kind"] == "host_adopted"));
    assert_eq!(daemon.host_record(&session)["host_pid"], host["host_pid"]);
    ends_its_turn(&daemon, &session, &gate);
    std::fs::remove_file(replay_gate).unwrap();

    let reply = prompt_reply(&mut rpc, &session).await;
    assert_eq!(reply["result"]["stopReason"], "end_turn", "{reply}");
    assert_ne!(daemon.host_record(&session)["host_pid"], host["host_pid"]);
}

#[tokio::test]
async fn recovery_refuses_the_prompt_when_the_old_host_outlives_the_end_deadline() {
    let (mut daemon, session, host) = token_chat("r9-timeout").await;
    let mut rpc = restart_after_recovery(&mut daemon, &session, false).await;
    assert!(daemon.events(&session).iter().any(|event| event["kind"] == "host_adopted"));
    let pid = host["host_pid"].as_i64().unwrap() as i32;
    // The adopted link remains live, but its host cannot take the terminate frame.
    // Daemon's Drop kills the fixture's process group even if an assertion fails.
    // SAFETY: pid is the host created by this fixture.
    assert_eq!(unsafe { libc::kill(pid, libc::SIGSTOP) }, 0);
    let start = Instant::now();
    let reply = prompt_reply(&mut rpc, &session).await;
    assert!(start.elapsed() >= Duration::from_secs(5));
    assert!(
        reply["error"]["message"].as_str().is_some_and(|m| m.contains("did not end")),
        "{reply}"
    );
    assert_old_child_untouched(&daemon, &session, &host);
}

async fn agent_connection(daemon: &Daemon, session: &str, host: &Value) -> Rpc {
    let mut rpc = daemon.rpc().await;
    let token = host["caller_token"].as_str().unwrap();
    rpc.call(
        "initialize",
        json!({"protocolVersion": 1, "clientInfo": {"name": "fixture", "version": "0.1"},
               "_meta": {"acpmux": {"callerSession": {"sessionId": session, "token": token}}}}),
    )
    .await;
    rpc
}

#[tokio::test]
async fn an_agent_bound_connection_cannot_start_finish_reuse_or_logout_claude_login() {
    let (daemon, session, host) = token_chat("r9-owner").await;
    let mut agent = agent_connection(&daemon, &session, &host).await;
    // This operation confirms that the socket can act as its bound agent.
    agent.call("_acpmux/bg/list", json!({"sessionId": session})).await;
    for (operation, params) in [
        ("start", json!({"agent": "claude"})),
        (
            "recover_start",
            json!({"agent": "claude", "reuseExisting": true, "recoverySession": session}),
        ),
        ("recover_finish", json!({"loginId": "fixture", "recoverySession": session})),
        ("cancel", json!({"loginId": "fixture"})),
        ("logout", json!({"agent": "claude"})),
    ] {
        let reply = agent.reply(&format!("_acpmux/agent_login/{operation}"), params).await;
        assert_eq!(reply["error"]["data"]["reason"], "remote_refused", "{operation}: {reply}");
    }
}

#[tokio::test]
async fn a_named_cloud_connection_can_start_a_background_task() {
    let (daemon, session, host) = token_chat("r9-bg-env").await;
    let mut agent = agent_connection(&daemon, &session, &host).await;
    let started = agent
        .call(
            "_acpmux/bg/start",
            json!({"sessionId": session, "command": "printf 'credential-free task'"}),
        )
        .await;
    assert!(started["id"].is_string());
}
