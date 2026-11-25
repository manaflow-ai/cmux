use super::*;

#[tokio::test]
async fn the_first_prompt_after_missed_adoption_uses_the_machine_login() {
    let mut daemon = Daemon::new("claude-missed-host", "approve-all");
    daemon.sigterm();
    let token = "sk-ant-oat01-missed-host-fixture";
    let name = "CLAUDE_CODE_OAUTH_TOKEN";
    std::fs::write(
        daemon.home.join("config.json"),
        json!({
            "harnesses": {"claude-fake": {"argv": ["python3", FAKE], "family": "claude"}},
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
                "credentials": {"env": {name: token}, "connection": "claude-token"}
            }}}),
        )
        .await;
    let session = created["sessionId"].as_str().unwrap();
    let host = daemon.host_record(session);
    let old_host = host["host_pid"].as_i64().unwrap();
    let old_harness = host["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(rpc);

    // Leave the saved result of a completed recovery and hide the host records through startup.
    let path = daemon.saved_meta_path(session);
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    meta["claudeTokenRecovery"] = json!("machineLogin");
    meta["claudeLoginRestartPending"] = json!(true);
    meta.as_object_mut().unwrap().remove("credentialConnection");
    std::fs::write(path, meta.to_string()).unwrap();
    let hidden = daemon.home.join("records-hidden");
    std::fs::write(&hidden, "").unwrap();
    daemon.env.push(("ACPMUX_TEST_HOST_RECORDS_FAIL_FILE".into(), hidden.display().to_string()));
    daemon.start();
    let mut rpc = daemon.rpc().await;
    // The health request waits for startup, including the adoption pass.
    rpc.call("_acpmux/harness/health", json!({})).await;
    assert!(alive(old_host));
    assert!(!daemon.events(session).iter().any(|event| event["kind"] == "host_adopted"));
    std::fs::remove_file(hidden).unwrap();

    rpc.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]}),
    )
    .await;
    daemon.wait_event(session, "the new agent's token status", |event| {
        chunk(event, "CLAUDE_CODE_OAUTH_TOKEN=")
    });
    assert!(!daemon.events(session).iter().any(|event| chunk(event, &format!("{name}={token}"))));
    assert_ne!(daemon.host_record(session)["host_pid"].as_i64(), Some(old_host));
    assert!(gone_within(old_host, Duration::from_secs(10)));
    assert!(gone_within(old_harness, Duration::from_secs(10)));
}
