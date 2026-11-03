//! cx-v9k2f: acpmux decides each session's lane once (`lane` on the session
//! summary): what a coordinator watching many agents needs to see at a glance.
//! `working` since its turn started, `input` (a permission or question waits),
//! `idle` since its last turn ended, `failed` with the last turn's error text
//! (an agent dead on "Credit balance too low" must not read as idle), `lost`
//! (the agent process is gone). A closed session has no lane.

use super::*;

/// The session's wire summary (`_acpmux/watch`) once `settled` holds.
async fn settled(
    hub: &Hub,
    c: &mut TestClient,
    id: &str,
    settled: impl Fn(&Value) -> bool,
) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let summary = hub.session_summary(&hub.resolve(id).unwrap());
        if settled(&summary) {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "never settled: {summary}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let watched = c.request("_acpmux/watch", json!({"enabled": true})).await.unwrap();
    watched["sessions"].as_array().unwrap().iter().find(|s| s["sessionId"] == id).unwrap().clone()
}

#[tokio::test]
async fn a_new_session_is_idle_since_it_was_created() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "fresh").await;
    let s = settled(&hub, &mut c, &id, |_| true).await;
    assert_eq!(s["lane"]["state"], "idle", "{s}");
    assert_eq!(s["lane"]["since"], s["createdAt"], "{s}");
    assert!(s["lane"]["error"].is_null(), "{s}");
}

#[tokio::test]
async fn an_answered_turn_is_idle_since_it_ended() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "answered").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let s = settled(&hub, &mut c, &id, |s| s["lastTurn"]["status"] == "completed").await;
    assert_eq!(s["lane"]["state"], "idle", "{s}");
    assert_eq!(s["lane"]["since"], s["lastTurn"]["endedAt"], "{s}");
}

#[tokio::test]
async fn a_running_turn_is_working_since_it_started_and_a_permission_is_input() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "live").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "running").await;
    assert_eq!(s["lane"]["state"], "working", "{s}");
    assert_eq!(s["lane"]["since"], s["turn"]["startedAt"], "{s}");
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    settled(&hub, &mut c, &id, |s| s["turn"].is_null()).await;

    c.send(method::SESSION_PROMPT, prompt(&id, "ask: rm -rf /", None)).await;
    let s = settled(&hub, &mut c, &id, |s| s["pendingPermissions"].as_u64() > Some(0)).await;
    assert_eq!(s["lane"]["state"], "input", "{s}");
    let asked = s["lane"]["since"].as_u64().expect("waiting has a since");

    // Typing in the composer saves a draft (and moves updatedAt): still waiting since the ask.
    tokio::time::sleep(Duration::from_millis(20)).await;
    c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "hmm"})).await.unwrap();
    let s = settled(&hub, &mut c, &id, |s| s["updatedAt"].as_u64() > Some(asked)).await;
    assert_eq!(s["lane"]["state"], "input", "{s}");
    assert_eq!(s["lane"]["since"].as_u64(), Some(asked), "{s}");
}

#[tokio::test]
async fn a_failed_turn_is_failed_with_its_error_text() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "broke").await;
    let failed = c
        .request(method::SESSION_PROMPT, prompt(&id, "fail-streamed: Credit balance too low", None))
        .await;
    assert!(failed.is_err(), "{failed:?}");
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "ready").await;
    assert_eq!(s["lane"]["state"], "failed", "{s}");
    assert_eq!(s["lane"]["since"], s["lastTurn"]["endedAt"], "{s}");
    let error = s["lane"]["error"].as_str().unwrap_or_default();
    assert!(error.contains("Credit balance too low"), "{s}");
}

#[tokio::test]
async fn an_agent_gone_without_an_answer_is_lost() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "gone").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel-then-exit", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let s = settled(&hub, &mut c, &id, |s| {
        s["status"] == "disconnected" && s["lastTurn"]["status"] == "cancelled"
    })
    .await;
    assert_eq!(s["lane"]["state"], "lost", "{s}");
    assert!(s["lane"]["since"].as_u64().is_some(), "{s}");
}

/// Goal 8 (leo-workspace research/2026-10-24-acpmux-tasks-liveness-urgency.md): a lane whose model
/// went quiet mid-turn with no tool call running says it has stalled, since its last sign; one
/// waiting on a long tool call (a build) never does. The state stays `working`.
#[cfg(unix)]
#[tokio::test]
async fn a_quiet_turn_with_no_tool_running_stalls_and_a_long_tool_call_does_not() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.stalled_turn_ms = Some(300);
    let fifo = |tag: &str| {
        let gate =
            std::env::temp_dir().join(format!("acpmux-stall-{tag}-{}", uuid::Uuid::now_v7()));
        assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
        gate
    };
    let (quiet_gate, tool_gate) = (fifo("quiet"), fifo("tool"));
    let quiet = new_session(&mut c, "quiet").await;
    let building = new_session(&mut c, "building").await;
    c.send(
        method::SESSION_PROMPT,
        prompt(&quiet, &format!("gate: {}", quiet_gate.display()), None),
    )
    .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "before-gate").await;
    let tool = format!("work-gate: {} | Run the full build", tool_gate.display());
    c.send(method::SESSION_PROMPT, prompt(&building, &tool, None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["title"] == "Run the full build").await;

    let s = settled(&hub, &mut c, &quiet, |s| s["lane"]["stalledSince"].is_u64()).await;
    assert_eq!(s["lane"]["state"], "working", "{s}");
    let since = s["lane"]["stalledSince"].as_u64().unwrap();
    assert!(since >= s["turn"]["startedAt"].as_u64().unwrap(), "since its last sign: {s}");
    assert_eq!(s["turn"]["stalledSince"], s["lane"]["stalledSince"], "{s}");

    tokio::time::sleep(Duration::from_millis(600)).await;
    let s = settled(&hub, &mut c, &building, |s| s["status"] == "running").await;
    assert_eq!(s["lane"]["state"], "working", "{s}");
    assert!(s["lane"]["stalledSince"].is_null(), "a tool call runs: {s}");

    for gate in [&quiet_gate, &tool_gate] {
        std::fs::write(gate, "go").unwrap();
    }
    for id in [&quiet, &building] {
        let s = settled(&hub, &mut c, id, |s| s["lastTurn"]["status"] == "completed").await;
        assert!(s["lane"]["stalledSince"].is_null(), "an ended turn has not stalled: {s}");
    }
    for gate in [quiet_gate, tool_gate] {
        let _ = std::fs::remove_file(gate);
    }
}
