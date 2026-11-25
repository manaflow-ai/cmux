//! The guest's start request pins the Claude auth source in the launched agent's env.

use super::*;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_team_auth_overrides_the_harness_default_for_one_guest_launch() {
    let mut daemon = Daemon::new("claude-launch-auth", "approve-all");
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({
            "harnesses": {
                "claude-fake": {
                    "argv": ["python3", FAKE], "family": "claude",
                    "env": {"CMUX_CLAUDE_AUTH": "own"}
                }
            },
            "defaultHarness": "claude-fake",
            "permissionPolicy": "approve-all"
        })
        .to_string(),
    )
    .unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    for (meta, expected) in [
        (json!({"claudeTeamRoute": true}), "team"),
        (json!({"claudeMachineLogin": true}), "own"),
        (json!({}), "own"),
    ] {
        let started = rpc
            .call(
                "session/new",
                json!({"cwd": daemon.home, "mcpServers": [], "_meta": {"acpmux": meta}}),
            )
            .await;
        let session = started["sessionId"].as_str().unwrap();
        rpc.call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "env: CMUX_CLAUDE_AUTH"}]}),
        )
        .await;
        let event = daemon.wait_event(session, "Claude auth env", |event| {
            event["msg"]["params"]["update"]["content"]["text"]
                .as_str()
                .is_some_and(|text| text.starts_with("CMUX_CLAUDE_AUTH="))
        });
        assert_eq!(
            event["msg"]["params"]["update"]["content"]["text"],
            format!("CMUX_CLAUDE_AUTH={expected}")
        );
    }
}
