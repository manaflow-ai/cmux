//! An approve-all an older daemon saved with no source, on a chat whose agent host outlived it
//! (`hub/policy_source.rs`): the next daemon clears the grant before it reaches the host, and
//! ends that host rather than adopt it, so nothing the agent asked under the old grant is
//! approved by it.

use super::*;

/// A handoff target (local, tagged) that an older daemon gave approve-all, and that asked for a
/// permission before the restart.
#[tokio::test]
async fn a_cleared_grants_live_agent_is_ended_not_adopted_and_its_chat_asks() {
    let mut daemon = Daemon::new("grant", "ask");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    let ask =
        |text: &str| json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
    client.send("session/prompt", ask("ask: deploy")).await;
    daemon.wait_event(&session, "permission_request", |e| e["kind"] == "permission_request");
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(client);
    assert!(alive(harness_pid), "SIGTERM ended the agent");

    // What an older daemon saved: the chat's own approve-all, with no `policySource`.
    let path = daemon.home.join("sessions").join(&session).join("session.json");
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    meta["permissionPolicy"] = json!("approve-all");
    meta["tags"] = json!({"handoffKey": {"value": "k1"}});
    meta.as_object_mut().unwrap().remove("policySource");
    std::fs::write(&path, meta.to_string()).unwrap();

    daemon.start();
    let first = daemon.wait_event(&session, "grant_cleared or the agent's answer", |e| {
        e["kind"] == "grant_cleared" || chunk(e, "chose yes")
    });
    assert_eq!(first["kind"], "grant_cleared", "the old grant answered the agent: {first}");
    assert_eq!(first["msg"]["hostEnded"], true, "{first}");
    assert!(gone_within(harness_pid, Duration::from_secs(10)), "the agent still runs");
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        (&saved["permissionPolicy"], &saved["policySource"]),
        (&json!("ask"), &json!("cleared"))
    );

    // Its next start asks.
    let mut rpc = daemon.rpc().await;
    rpc.send("session/prompt", ask("ask: again")).await;
    daemon.wait_event(&session, "a new permission_request", |e| {
        e["kind"] == "permission_request" && e.to_string().contains("again")
    });
    let events = daemon.events(&session);
    for kind in ["host_adopted", "permission_auto", "permission_reissued"] {
        assert!(!events.iter().any(|e| e["kind"] == kind), "{kind}: {events:#?}");
    }
}
