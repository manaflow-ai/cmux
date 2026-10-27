//! An approve-all an older daemon saved with no source, on a chat whose agent host outlived it
//! (`hub/policy_source.rs`): the next daemon clears the grant before it reaches the host, and
//! ends that host rather than adopt it, so nothing the agent asks under the old grant is
//! approved by it.

use super::*;

/// Lets a `gate-ask:` agent that still waits on `gate` go on to ask; none waits once it ended.
fn release(gate: &Path) {
    let open = std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(gate);
    if let Ok(mut gate) = open {
        let _ = std::io::Write::write_all(&mut gate, b"go");
    }
}

/// A handoff target (local, tagged) that an older daemon gave approve-all, whose agent is about
/// to ask for a permission across the restart.
#[tokio::test]
async fn a_cleared_grants_live_agent_is_ended_not_adopted_and_its_chat_asks() {
    let mut daemon = Daemon::new("grant", "ask");
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let mut client = daemon.rpc().await;
    let ask =
        |text: &str| json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
    client.send("session/prompt", ask(&format!("gate-ask: {}", gate.display()))).await;
    daemon.wait_event(&session, "before-gate chunk", |e| chunk(e, "before-gate"));
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
    let first = daemon.wait_event(&session, "grant_cleared or host_adopted", |e| {
        e["kind"] == "grant_cleared" || e["kind"] == "host_adopted"
    });
    if first["kind"] == "host_adopted" {
        release(&gate);
        let answer = daemon.wait_event(&session, "the agent's ask", |e| {
            e["kind"] == "permission_request" || e["kind"] == "permission_auto"
        });
        panic!("the cleared chat's host was adopted, and its ask got {answer}");
    }
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
    daemon.wait_event(&session, "a permission_request", |e| e["kind"] == "permission_request");
    let events = daemon.events(&session);
    for kind in ["host_adopted", "permission_auto"] {
        assert!(!events.iter().any(|e| e["kind"] == kind), "{kind}: {events:#?}");
    }
    // The host that start runs is the chat's own: the next restart adopts it.
    daemon.sigterm();
    drop(rpc);
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
}
