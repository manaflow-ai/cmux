//! The answer to a Claude Code permission ask has Claude Code's own reply
//! shape: an allow carries `updatedInput` (the input Claude sent, unless the
//! hub answered it), a deny carries a `message`. A bare allow failed Claude
//! Code's schema check (a ZodError), so every allowed tool call of a
//! claude-stdio chat was refused, by a person or by the policy alike.

use super::*;

/// Runs the "answer-shape" turn in a new session with `policy`; `answer`
/// answers its one ask as the person (None: the policy answers). The text the
/// fake Claude says about the answer it got.
async fn answer_shape(
    policy: PermissionPolicy,
    answer: Option<&str>,
    approve_pending: bool,
) -> String {
    let root = std::env::temp_dir().join(format!("acpmux-shape-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, _agent) = claude_setup(&claude, &[]).await;
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut person = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    person.become_person().await;

    let s =
        person.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    hub.set_policy(&session, policy).await;
    person.next += 1;
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "answer-shape"}]});
    person
        .tx
        .send(Message::request(person.next, method::SESSION_PROMPT, prompt).to_line())
        .await
        .unwrap();
    if answer.is_some() || approve_pending {
        let pending = person.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
        let pid = pending["permissionId"].as_str().unwrap().to_owned();
        if approve_pending {
            hub.set_policy(&session, PermissionPolicy::ApproveAll).await;
        } else if let Some(option) = answer {
            person
                .request(
                    method::MUX_PERMISSION_RESPOND,
                    json!({"sessionId": id, "permissionId": pid, "optionId": option}),
                )
                .await
                .unwrap();
        }
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while !hub.events(&id, 0, 10_000).unwrap().iter().any(|e| e.kind == "turn_end") {
        assert!(std::time::Instant::now() < deadline, "the turn never ended");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let said = hub.session_summary(&session)["preview"].as_str().unwrap_or_default().to_owned();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
    said
}

#[tokio::test]
async fn a_person_allow_hands_claude_its_input_back() {
    assert_eq!(
        answer_shape(PermissionPolicy::Ask, Some("allow_once"), false).await,
        "allow input ok"
    );
}

#[tokio::test]
async fn a_policy_allow_hands_claude_its_input_back() {
    assert_eq!(answer_shape(PermissionPolicy::ApproveAll, None, false).await, "allow input ok");
}

#[tokio::test]
async fn approving_a_pending_claude_request_hands_its_input_back() {
    assert_eq!(answer_shape(PermissionPolicy::Ask, None, true).await, "allow input ok");
}

#[tokio::test]
async fn a_deny_carries_a_message() {
    assert_eq!(
        answer_shape(PermissionPolicy::Ask, Some("reject_once"), false).await,
        "deny message ok"
    );
}
