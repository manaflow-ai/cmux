//! `_meta.acpmux.steerOnly`: a client that steers (the Chief delivering a
//! message between tool calls) gets a refusal, never a queued prompt, when
//! the session cannot steer now: no turn runs, or its agent does not steer
//! (the fake agent advertises no steering).

use super::*;

fn steer(id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"steer": true, "steerOnly": true}}})
}

#[tokio::test]
async fn a_steer_only_prompt_is_refused_with_no_turn_running() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let refused = c.request(method::SESSION_PROMPT, steer(&id, "late")).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("steer.unavailable")), "{refused:?}");
}

#[tokio::test]
async fn a_steer_only_prompt_is_refused_by_an_agent_that_does_not_steer() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.next += 1;
    c.tx.send(
        Message::request(
            c.next,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "slow"}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let refused = c.request(method::SESSION_PROMPT, steer(&id, "late")).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("steer.unavailable")), "{refused:?}");
}
