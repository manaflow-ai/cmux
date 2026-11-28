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

fn attempt(hub: &Hub, session: &Session, id: &str) -> receipt::Attempt {
    let guard = session.permissions.lock().unwrap();
    let pending = &guard.pending["question-1"];
    serde_json::from_value(json!({"id":id, "instance":hub.person.instance(),
        "decisionNonce":pending.decision_nonce,
        "requestDigest":super::super::approvers::answers_digest(Some(&pending.request)),
        "answersDigest":super::super::approvers::answers_digest(Some(&json!({"Which card?":"Glass"})))
    })).unwrap()
}

#[tokio::test]
async fn receipt_marks_only_successful_delivery_and_rejects_stale_binding() {
    for alive in [true, false] {
        let (hub, session, receiver) = pending_question();
        let binding = attempt(&hub, &session, "attempt1");
        let receiver = if alive {
            Some(receiver)
        } else {
            drop(receiver);
            None
        };
        let result = hub
            .respond_permission_receipted(
                &session,
                "question-1",
                Some("allow_once".into()),
                Some(json!({"Which card?":"Glass"})),
                None,
                None,
                super::super::person::Answerer { person: true, ..Default::default() },
                Control::Local,
                Some(binding),
            )
            .await;
        let status = hub.permission_delivery_status(&session, "attempt1").unwrap();
        if let Some(receiver) = receiver {
            result.unwrap();
            assert_eq!(receiver.await.unwrap()["outcome"], "selected");
            assert_eq!(status["state"], "delivered");
        } else {
            assert_eq!(result.unwrap_err().data.unwrap()["reason"], "agent_gone");
            assert_eq!(status["state"], "refused");
            assert_eq!(status["reason"], "agent_gone");
        }
    }
    for field in
        ["requestDigest", "answersDigest", "annotationsDigest", "decisionNonce", "instance"]
    {
        let (hub, session, mut receiver) = pending_question();
        let mut bad = serde_json::to_value(attempt(&hub, &session, "stale")).unwrap();
        bad[field] = json!("changed");
        let result = hub
            .respond_permission_receipted(
                &session,
                "question-1",
                Some("allow_once".into()),
                Some(json!({"Which card?":"Glass"})),
                None,
                None,
                super::super::person::Answerer { person: true, ..Default::default() },
                Control::Local,
                Some(serde_json::from_value(bad).unwrap()),
            )
            .await;
        assert_eq!(result.unwrap_err().data.unwrap()["reason"], "question.stale");
        assert!(matches!(receiver.try_recv(), Err(oneshot::error::TryRecvError::Empty)));
        assert!(session.permissions.lock().unwrap().pending.contains_key("question-1"));
    }
}

#[tokio::test]
async fn rejected_receipt_claim_neither_spends_proof_nor_delivers() {
    let (hub, session, mut receiver) = pending_question();
    let binding = attempt(&hub, &session, "claimed");
    {
        let mut guard = session.permissions.lock().unwrap();
        let prepared = receipt::Receipt::prepare(
            binding.clone(),
            &session.id,
            "question-1",
            hub.person.instance(),
            &guard.pending["question-1"],
            Some("allow_once"),
            Some(&json!({"Which card?":"Glass"})),
            None,
        )
        .unwrap();
        guard.deliveries.claim(&prepared, None).unwrap();
    }
    let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    hub.person.install_spawn_key(key).unwrap();
    let answers = json!({"Which card?":"Glass"});
    let proof = super::super::person::decision_answers_proof(
        key,
        hub.person.instance(),
        &session.id,
        "question-1",
        "allow_once",
        "question-nonce",
        &answers,
        None,
    )
    .unwrap();
    let result = hub
        .respond_permission_receipted(
            &session,
            "question-1",
            Some("allow_once".into()),
            Some(answers.clone()),
            None,
            None,
            super::super::person::Answerer {
                decision: Some(("question-nonce", &proof)),
                ..Default::default()
            },
            Control::Local,
            Some(binding),
        )
        .await;
    assert_eq!(result.unwrap_err().data.unwrap()["reason"], "question.delivery_claimed");
    assert!(hub.person.decision_proves(
        &session.id,
        "question-1",
        "allow_once",
        "question-nonce",
        Some(&answers),
        None,
        &proof
    ));
    assert!(matches!(receiver.try_recv(), Err(oneshot::error::TryRecvError::Empty)));
    assert!(session.permissions.lock().unwrap().pending.contains_key("question-1"));
    assert_eq!(hub.permission_delivery_status(&session, "claimed").unwrap()["state"], "unknown");
}
