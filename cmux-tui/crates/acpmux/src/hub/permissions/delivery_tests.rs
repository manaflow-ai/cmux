//! A permission response succeeds only while the asking task can receive it.

use super::*;

fn pending_question() -> (Arc<Hub>, Arc<Session>, oneshot::Receiver<Value>) {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "question-session", "name": "Question",
        "harness": "claude", "cwd": "/tmp", "status": "waiting", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    let mut request = json!({
        "toolCall": {"toolCallId": "ask-1", "rawInput": {"questions": [{
            "question": "Which card?", "options": [{"label": "Glass"}, {"label": "Plain"}]
        }]}, "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": true}}},
        "options": [{"optionId": "allow_once", "kind": "allow_once"}]
    });
    super::super::questions::normalize(
        &mut request,
        super::super::questions::PreviewFormat::Monospace,
    );
    let (reply, receiver) = oneshot::channel();
    session.permissions.lock().unwrap().pending.insert(
        "question-1".into(),
        PendingPermission {
            request,
            reply,
            decision_nonce: "question-nonce".into(),
            ancestor_may_answer: false,
            prev_status: SessionStatus::Running,
            agent_request: None,
            agent_host_incarnation: None,
        },
    );
    (hub, session, receiver)
}

async fn answer(
    hub: &Hub,
    session: &Session,
    fence: Option<&crate::agent::Fence>,
) -> Result<(), RpcError> {
    hub.respond_permission(
        session,
        "question-1",
        Some("allow_once".into()),
        Some(json!({"Which card?": "Glass"})),
        None,
        super::super::person::Answerer { person: true, fence, ..Default::default() },
        Control::Local,
    )
    .await
}

#[tokio::test]
async fn dropped_question_receiver_is_refused_with_or_without_a_fence() {
    for fenced in [false, true] {
        let (hub, session, receiver) = pending_question();
        drop(receiver);
        let fence = crate::agent::Fence::default();
        let error = answer(&hub, &session, fenced.then_some(&fence)).await.unwrap_err();
        assert_eq!(error.code, -32002);
        assert_eq!(error.data.as_ref().unwrap()["reason"], "agent_gone");
        assert_eq!(error.data.as_ref().unwrap()["permissionId"], "question-1");
        assert!(error.message.contains("no longer waiting"));
        assert!(!session.permissions.lock().unwrap().pending.contains_key("question-1"));
        assert!(hub.answer_fences.lock().unwrap().is_empty());
        assert_eq!(fence.is_cut(), fenced);
    }
}

#[tokio::test]
async fn live_question_receiver_gets_the_answer_once() {
    let (hub, session, receiver) = pending_question();
    answer(&hub, &session, None).await.unwrap();
    let delivered = receiver.await.unwrap();
    assert_eq!(delivered["outcome"], "selected");
    assert_eq!(delivered["optionId"], "allow_once");
    assert_eq!(delivered["_meta"]["updatedInput"]["answers"], json!({"Which card?": "Glass"}));
    let duplicate = answer(&hub, &session, None).await.unwrap_err();
    assert_eq!(duplicate.code, -32002);
}
