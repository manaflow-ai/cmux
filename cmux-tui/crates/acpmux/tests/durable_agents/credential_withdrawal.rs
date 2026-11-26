use super::*;
use std::os::unix::fs::PermissionsExt;

#[tokio::test]
async fn api_key_withdrawal_refuses_until_the_recorded_host_is_adopted() {
    let mut daemon = Daemon::new("cred-withdraw", "approve-all");
    daemon.sigterm();
    let launcher = daemon.home.join("claude");
    std::fs::copy(FAKE, &launcher).unwrap();
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({
            "harnesses": {"claude-fake": {"argv": [launcher], "family": "claude"}},
            "defaultHarness": "claude-fake", "permissionPolicy": "approve-all"
        })
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let connection = format!("work-key:{}", "a".repeat(64));
    let created = rpc
        .call(
            "session/new",
            json!({"cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": {
                "credentials": {
                    "env": {"ANTHROPIC_API_KEY": "fixture-key"},
                    "connection": connection
                }
            }}}),
        )
        .await;
    let session = created["sessionId"].as_str().unwrap();
    let host = daemon.host_record(session)["host_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(rpc);

    let hidden = daemon.home.join("records-hidden");
    std::fs::write(&hidden, "").unwrap();
    daemon.env.push(("ACPMUX_TEST_HOST_RECORDS_FAIL_FILE".into(), hidden.display().to_string()));
    daemon.start();
    let mut rpc = daemon.rpc().await;
    rpc.call("_acpmux/harness/health", json!({})).await;
    std::fs::remove_file(hidden).unwrap();

    let method = "agent/credentials.update";
    let withdrawal = json!({"sessionId": session, "env": {}});
    let status = rpc.call(method, json!({"sessionId": session})).await;
    assert_eq!(status["held"], false);
    assert_eq!(status["connection"], connection);
    let result = rpc.reply(method, withdrawal.clone()).await;
    assert_eq!(result["error"]["data"]["reason"], "credentials.host_pending");
    assert!(alive(host));

    // Restart with readable records so startup adopts the same host on both macOS and Linux.
    drop(rpc);
    daemon.sigkill();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    rpc.call("_acpmux/harness/health", json!({})).await;
    assert!(daemon.events(session).iter().any(|event| event["kind"] == "host_adopted"));
    assert_eq!(daemon.host_record(session)["host_pid"], host);
    let next = rpc
        .reply(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "after restart"}]}),
        )
        .await;
    assert_eq!(next["error"]["data"]["reason"], "credentials.needed");
    assert!(alive(host));
    assert_eq!(rpc.call(method, withdrawal).await["restart"], "none");
    assert!(gone_within(host, Duration::from_secs(10)));
    assert_eq!(rpc.call(method, json!({"sessionId": session})).await["held"], false);
}
