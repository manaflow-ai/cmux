//! Stop (`hub/cancel.rs`): `session/cancel` is answered even as a request,
//! and it always ends the turn, even when the agent never answers it.

use super::*;

/// Stop always ends the turn: an agent that never answers the cancel (Claude
/// Code idle after a local slash command, cosmic-gray 2026-10-14) left the chat
/// running, its queue stuck behind it. acpmux ends the turn itself and says so.
#[tokio::test]
async fn a_cancel_the_agent_never_answers_still_ends_the_turn() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.next += 1;
    c.tx.send(
        Message::request(
            c.next,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "deaf-to-cancel"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let stopped = std::time::Instant::now();
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    let done = tokio::time::timeout(
        Duration::from_secs(10),
        c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end"),
    )
    .await
    .expect("the turn stayed open after Stop");
    assert_eq!(done["msg"]["stopReason"], "cancelled", "{done}");
    assert!(stopped.elapsed() < Duration::from_secs(10));
    let result = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_result").await;
    assert_eq!(result["msg"]["cancelForced"], true, "{result}");
}

#[tokio::test]
async fn session_cancel_as_a_request_is_answered() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "cancel-req").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "slow", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let cancel = c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let (r, _) = c.response(cancel).await;
    assert_eq!(r.unwrap(), json!({}));
    let r = c.response(rid).await.0.unwrap();
    assert_eq!(r["stopReason"], "cancelled");
    // With no turn running it still answers.
    assert_eq!(
        c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap(),
        json!({})
    );
}
