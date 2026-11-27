//! Grok's x.ai extension requests (cx-1785): `_x.ai/ask_user_question`
//! becomes an acpmux question that only a person answers, and
//! `x.ai/exit_plan_mode` becomes a plan approval; each reply goes back in
//! Grok's shape (`{outcome, answers}` / `{outcome}`).

use super::*;

async fn start(c: &mut TestClient, prompt: &str) -> (String, Value) {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.next += 1;
    let prompt_id = c.next;
    c.tx.send(
        Message::request(
            prompt_id,
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": prompt}]}),
        )
        .to_line(),
    )
    .await
    .unwrap();
    let pending = c.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    (id, pending)
}

#[tokio::test]
async fn xai_question_is_answered_by_a_person_in_grok_shape() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let (id, pending) = start(&mut c, "xai-question: Which one?").await;
    let question = &pending["request"]["toolCall"]["_meta"]["acpmux"]["question"];
    // Answered in Claude's text-keyed shape, by every client; Grok asked.
    assert_eq!(question["harness"], "claude");
    assert_eq!(question["agent"], "Grok");
    assert_eq!(question["items"][0]["prompt"], "Which one?");
    assert_eq!(
        question["items"][0]["options"][0],
        json!({"id": "A", "label": "A", "detail": "first"})
    );
    let session = hub.resolve(&id).unwrap();
    // approve-all never answers a question.
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
    let pid = pending["permissionId"].as_str().unwrap();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "allow_once", "answers": {"Which one?": "B"}}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(
        hub.session_summary(&session)["preview"],
        r#"xai {"answers": {"Which one?": ["B"]}, "outcome": "accepted"}"#
    );
}

#[tokio::test]
async fn xai_question_declined_is_cancelled_for_grok() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, pending) = start(&mut c, "xai-question: Which one?").await;
    let pid = pending["permissionId"].as_str().unwrap();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "reject_once"}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], r#"xai {"outcome": "cancelled"}"#);
}

#[tokio::test]
async fn xai_exit_plan_mode_is_a_plan_approval() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, pending) = start(&mut c, "xai-plan: 1. read 2. fix").await;
    let tool = &pending["request"]["toolCall"];
    assert_eq!(tool["kind"], "switch_mode");
    assert_eq!(tool["rawInput"]["plan"], "1. read 2. fix");
    let pid = pending["permissionId"].as_str().unwrap();
    let approve = pending["request"]["options"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["kind"] == "allow_once")
        .unwrap()["optionId"]
        .as_str()
        .unwrap()
        .to_owned();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": approve}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], r#"xai {"outcome": "approved"}"#);
}

#[tokio::test]
async fn xai_exit_plan_mode_kept_planning_asks_for_changes() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, pending) = start(&mut c, "xai-plan: the plan").await;
    let pid = pending["permissionId"].as_str().unwrap();
    let keep = pending["request"]["options"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["kind"] == "reject_once")
        .unwrap()["optionId"]
        .as_str()
        .unwrap()
        .to_owned();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": keep}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], r#"xai {"outcome": "request_changes"}"#);
}

#[tokio::test]
async fn xai_question_under_deny_all_is_cancelled_for_grok() {
    let (hub, mut c) = setup(PermissionPolicy::DenyAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "xai-question: Which one?"}]}),
    )
    .await
    .unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], r#"xai {"outcome": "cancelled"}"#);
}

#[tokio::test]
async fn xai_question_pending_at_a_cancel_is_cancelled_for_grok() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, _pending) = start(&mut c, "xai-question: Which one?").await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], r#"xai {"outcome": "cancelled"}"#);
}
