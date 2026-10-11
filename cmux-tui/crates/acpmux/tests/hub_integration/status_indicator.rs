//! cx-zlox: acpmux decides each session's status dot once (`indicator` on
//! the session summary) and every client draws it, so the chat list, the tab
//! strip and the sidebar agree. First match wins: `input` (a permission or
//! question waits), `working`, `failed` (the last turn failed), `lost` (the
//! agent process is gone and the chat has no answer), `done` (the last turn
//! answered), else null. Whether `done` was seen stays with each client.

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
async fn an_answered_turn_is_done() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "done").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let s = settled(&hub, &mut c, &id, |s| s["lastTurn"]["status"] == "completed").await;
    assert_eq!(s.get("indicator"), Some(&json!("done")), "{s}");
}

#[tokio::test]
async fn a_failed_turn_is_failed_while_its_agent_still_runs() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "failed").await;
    let failed = c.request(method::SESSION_PROMPT, prompt(&id, "fail-streamed: boom", None)).await;
    assert!(failed.is_err(), "{failed:?}");
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "ready").await;
    assert_eq!(s["lastTurn"]["status"], "failed", "{s}");
    assert_eq!(s.get("indicator"), Some(&json!("failed")), "{s}");
}

#[tokio::test]
async fn an_agent_gone_without_an_answer_is_lost() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "lost").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel-then-exit", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "disconnected").await;
    assert_eq!(s["lastTurn"]["status"], "cancelled", "{s}");
    assert_eq!(s.get("indicator"), Some(&json!("lost")), "{s}");
}

#[tokio::test]
async fn an_agent_gone_after_its_answer_is_done() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "answered").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "answer-then-exit", None)).await.unwrap();
    // The agent is gone; the chat keeps its answer, so it is done, not lost.
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "disconnected").await;
    assert_eq!(s["lastTurn"]["status"], "completed", "{s}");
    assert_eq!(s.get("indicator"), Some(&json!("done")), "{s}");
}

#[tokio::test]
async fn a_running_turn_is_working_and_a_waiting_permission_is_input() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let id = new_session(&mut c, "live").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let s = settled(&hub, &mut c, &id, |s| s["status"] == "running").await;
    assert_eq!(s.get("indicator"), Some(&json!("working")), "{s}");
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    settled(&hub, &mut c, &id, |s| s["turn"].is_null()).await;

    c.send(method::SESSION_PROMPT, prompt(&id, "ask: rm -rf /", None)).await;
    let s = settled(&hub, &mut c, &id, |s| s["pendingPermissions"].as_u64() > Some(0)).await;
    assert_eq!(s.get("indicator"), Some(&json!("input")), "{s}");
}
