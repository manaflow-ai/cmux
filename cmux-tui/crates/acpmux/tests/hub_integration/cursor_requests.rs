//! Cursor's `cursor/` extension requests (cx-1785): `cursor/ask_question`
//! becomes an acpmux question that only a person answers, answered with
//! Cursor's option ids, and `cursor/create_plan` becomes a plan approval.

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

fn option_of_kind(pending: &Value, kind: &str) -> String {
    pending["request"]["options"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["kind"] == kind)
        .unwrap()["optionId"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn cursor_question_is_answered_by_a_person_with_option_ids() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let (id, pending) = start(&mut c, "cursor-question: Which ones?").await;
    let question = &pending["request"]["toolCall"]["_meta"]["acpmux"]["question"];
    // Answered by item id (the codex wire shape); Cursor asked.
    assert_eq!(question["harness"], "codex");
    assert_eq!(question["agent"], "Cursor");
    assert_eq!(question["items"][0]["id"], "which");
    assert_eq!(question["items"][0]["prompt"], "Which ones?");
    assert_eq!(question["items"][0]["multiSelect"], true);
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "waiting");
    let pid = pending["permissionId"].as_str().unwrap();
    let answer = option_of_kind(&pending, "allow_once");
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": answer,
               "answers": {"which": {"answers": ["A", "B"]}}}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    assert_eq!(
        hub.session_summary(&session)["preview"],
        r#"cursor {"outcome": {"answers": [{"questionId": "which", "selectedOptionIds": ["opt-a", "opt-b"]}], "outcome": "answered"}}"#
    );
}

#[tokio::test]
async fn cursor_question_declined_is_skipped() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, pending) = start(&mut c, "cursor-question: Which ones?").await;
    let pid = pending["permissionId"].as_str().unwrap();
    let decline = option_of_kind(&pending, "reject_once");
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": decline}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(
        hub.session_summary(&session)["preview"],
        r#"cursor {"outcome": {"outcome": "skipped"}}"#
    );
}

#[tokio::test]
async fn cursor_question_pending_at_a_cancel_is_cancelled() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, _pending) = start(&mut c, "cursor-question: Which ones?").await;
    c.tx.send(Message::notification(method::SESSION_CANCEL, json!({"sessionId": id})).to_line())
        .await
        .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(
        hub.session_summary(&session)["preview"],
        r#"cursor {"outcome": {"outcome": "cancelled"}}"#
    );
}

#[tokio::test]
async fn cursor_create_plan_is_a_plan_approval() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, pending) = start(&mut c, "cursor-plan: 1. read 2. fix").await;
    let tool = &pending["request"]["toolCall"];
    assert_eq!(tool["kind"], "switch_mode");
    assert_eq!(tool["rawInput"]["plan"], "1. read 2. fix");
    let pid = pending["permissionId"].as_str().unwrap();
    let approve = option_of_kind(&pending, "allow_once");
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": approve}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(
        hub.session_summary(&session)["preview"],
        r#"cursor {"outcome": {"outcome": "accepted"}}"#
    );
}

#[tokio::test]
async fn cursor_create_plan_kept_planning_is_rejected() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let (id, pending) = start(&mut c, "cursor-plan: the plan").await;
    let pid = pending["permissionId"].as_str().unwrap();
    let keep = option_of_kind(&pending, "reject_once");
    c.request(
        method::MUX_PERMISSION_RESPOND,
        json!({"sessionId": id, "permissionId": pid, "optionId": keep}),
    )
    .await
    .unwrap();
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_end").await;
    let session = hub.resolve(&id).unwrap();
    assert_eq!(
        hub.session_summary(&session)["preview"],
        r#"cursor {"outcome": {"outcome": "rejected"}}"#
    );
}
