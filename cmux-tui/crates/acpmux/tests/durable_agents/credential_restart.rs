//! A Cloud chat's launch credential (`agent_credentials.rs`) outlives a daemon restart: the next
//! daemon takes it back from the agent host it adopts, so the agent it starts later (a wake from
//! idle hibernation, a restart on a route switch) still runs on the owner's login.
//!
//! The production Cloud journey (2026-11-18, every run from the one that passed the login as a
//! launch credential): after "daemon restart keeps the session" the agent hibernated while the
//! machine paused, and "turn after resume" woke it with no credential, on the machine's route:
//! "Claude is not signed in here. This Cloud machine reaches Claude through the Cloud service...".

use super::*;

const TOKEN: &str = "sk-ant-oat01-journey-stub-login-value";

#[tokio::test]
async fn a_woken_agent_runs_on_the_launch_credential_after_a_daemon_restart() {
    let mut daemon = Daemon::with_env("credrest", "approve-all", &[]);
    daemon.sigterm();
    // A Claude-family agent, so the credential applies to it (`agent_credentials::apply`).
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", FAKE], "family": "claude"}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    daemon.start();
    let created = daemon
        .rpc()
        .await
        .call(
            "session/new",
            json!({
                "cwd": daemon.home,
                "mcpServers": [],
                "_meta": {"acpmux": {"credentials": {"env": {"CLAUDE_CODE_OAUTH_TOKEN": TOKEN}}}},
            }),
        )
        .await;
    let session = created["sessionId"].as_str().expect("session id").to_owned();
    let ask = json!({"sessionId": session, "prompt": [{"type": "text", "text": "env: CLAUDE_CODE_OAUTH_TOKEN"}]});
    let want = format!("CLAUDE_CODE_OAUTH_TOKEN={TOKEN}");
    let answer = daemon.rpc().await.call("session/prompt", ask.clone()).await;
    assert_eq!(answer["stopReason"], "end_turn", "{answer}");
    daemon.wait_event(&session, "the agent's login", |e| chunk(e, &want));
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    // A crash, as the journey's SIGKILL; the next daemon adopts the host and hibernates the
    // idle agent after one second.
    daemon.sigkill();
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "1".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    let hibernated = gone_within(harness, Duration::from_secs(20));
    assert!(hibernated, "the adopted idle agent did not hibernate");
    // The next prompt wakes a new agent: on the same login, not the machine's route.
    let answer = daemon.rpc().await.call("session/prompt", ask).await;
    assert_eq!(answer["stopReason"], "end_turn", "the woken agent did not answer: {answer}");
    let woken = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    assert_ne!(woken, harness, "the prompt was not answered by a new agent");
    let replies: Vec<String> = daemon
        .events(&session)
        .iter()
        .filter(|e| e["msg"]["params"]["update"]["sessionUpdate"] == "agent_message_chunk")
        .filter_map(|e| e["msg"]["params"]["update"]["content"]["text"].as_str().map(str::to_owned))
        .filter(|t| t.starts_with("CLAUDE_CODE_OAUTH_TOKEN="))
        .collect();
    assert_eq!(
        replies.last().map(String::as_str),
        Some(want.as_str()),
        "the agent woken after a daemon restart lost its launch credential: {replies:?}"
    );
}
