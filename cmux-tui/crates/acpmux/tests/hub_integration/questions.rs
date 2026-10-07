//! Agent questions (hub/questions.rs): policy never answers one, the hub
//! adds the normalized question, and answers are checked before they reach
//! the agent.

use super::*;

/// Starts a turn that asks `prompt` and returns (session id, pending record).
async fn ask(c: &mut TestClient, prompt: &str) -> (String, Value) {
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
async fn questions_approve_all_never_answers_a_question() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let (id, pending) = ask(&mut c, "question: Which one?").await;
    let question = &pending["request"]["toolCall"]["_meta"]["acpmux"]["question"];
    assert_eq!(question["harness"], "claude");
    assert_eq!(question["items"][0]["prompt"], "Which one?");
    assert_eq!(
        question["items"][0]["options"][0],
        json!({"id": "A", "label": "A", "detail": "first"})
    );
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
    let pid = pending["permissionId"].as_str().unwrap();
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "allow_once", "answers": {"Which one?": "B"}}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(hub.session_summary(&session)["preview"], r#"chose allow_once {"Which one?": "B"}"#);
}

#[tokio::test]
async fn questions_incomplete_answers_are_refused_and_the_ask_stays() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, pending) = ask(&mut c, "question: Which one?").await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    // An allow with no answers would hand the agent a blank answer.
    let blank = c
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": "allow_once"}),
        )
        .await;
    assert!(blank.is_err());
    for answers in [json!({}), json!({"Which one?": ""}), json!({"Which one?": "A", "other": "x"})]
    {
        let refused = c
            .request(
                method::MUX_PERMISSION_RESPOND,
                json!({"sessionId": id, "permissionId": pid, "optionId": "allow_once", "answers": answers}),
            )
            .await;
        assert!(refused.is_err(), "{answers}");
    }
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": "allow_once", "answers": {"Which one?": "A"}}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(hub.session_summary(&session)["preview"], r#"chose allow_once {"Which one?": "A"}"#);
}

#[tokio::test]
async fn questions_answers_for_an_ordinary_tool_are_refused() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, pending) = ask(&mut c, "ask: rm -rf /").await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    let refused = c
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": "yes", "answers": {"command": "ls"}}),
        )
        .await;
    assert!(refused.is_err());
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
}

#[tokio::test]
async fn questions_deny_all_declines_without_asking() {
    let (hub, mut c) = setup(PermissionPolicy::DenyAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "question: Which one?"}]}),
    )
    .await
    .unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose reject_once null");
}
