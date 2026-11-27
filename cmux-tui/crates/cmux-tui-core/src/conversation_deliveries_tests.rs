use super::*;

/// Own exactly the directory this test creates, including during unwinding.
/// No new test dependency or process-wide environment change is needed.
struct Scratch(std::path::PathBuf);
impl Scratch {
    fn new() -> Self {
        let name =
            new_id("cmux-question-delivery-", crate::workspace_registry::unix_epoch_ms().unwrap())
                .unwrap();
        let path = std::env::temp_dir().join(name);
        let builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        let builder = {
            use std::os::unix::fs::DirBuilderExt;
            let mut builder = builder;
            builder.mode(0o700);
            builder
        };
        builder.create(&path).unwrap();
        let scratch = Self(path);
        crate::platform::restrict_directory(scratch.path()).unwrap();
        scratch
    }

    fn path(&self) -> &Path {
        &self.0
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn binding() -> DeliveryBinding {
    DeliveryBinding {
        session_id: "session1".into(),
        permission_id: "permission1".into(),
        instance: "instance1".into(),
        decision_nonce: "a".repeat(64),
        request_digest: "b".repeat(64),
        option_id: "allow".into(),
        answers_digest: "c".repeat(64),
        receipt_id: None,
    }
}

fn fixture(directory: &Path) -> (ConversationStore, String, Op) {
    let mut store = ConversationStore::open(Some(directory)).unwrap();
    let participants: Vec<Participant> = serde_json::from_value(json!([
        {"id":"user_local","kind":"human","display_name":"Me"},
        {"id":"agent_mux","kind":"agent","display_name":"Chief","agent_class":"mux","acp_session":"session1"}
    ])).unwrap();
    let conversation =
        store.create("create-q", LOCAL_USER, "Questions", &participants).unwrap().summary.id;
    let question: Question = serde_json::from_value(json!({
        "harness":"claude","session":"session1","permission":"permission1",
        "items":[{"id":"q0","prompt":"Pick a color","options":[{"id":"o0","label":"Blue"}]}]
    }))
    .unwrap();
    let sent = store
        .apply_op(
            &conversation,
            "ask-q",
            "agent_mux",
            &Op::MessageSend {
                client_msg_id: "ask-q".into(),
                parts: vec![Part::Question(question)],
                reply_to: None,
                answers: vec![],
                answers_pending: vec![],
                thread_root: None,
            },
        )
        .unwrap();
    let message_id = sent.result.change["message"]["id"].as_str().unwrap().to_owned();
    let answer =
        serde_json::from_value(json!({"selections":{"q0":{"option_ids":["o0"]}}})).unwrap();
    (store, conversation, Op::QuestionAnswer { message_id, part_index: 0, answer })
}

fn claim(store: &mut ConversationStore, conversation: &str, op: &Op) -> DeliveryIntent {
    match store
        .claim_question_delivery(conversation, "answer-q", LOCAL_USER, op, &binding())
        .unwrap()
    {
        DeliveryClaim::Send(intent) => intent,
        other => panic!("expected first-send claim, got {other:?}"),
    }
}

#[test]
fn restart_resumes_query_only_without_proof_and_retains_immutable_question() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    let intent = claim(&mut store, &conversation, &op);
    let serialized = serde_json::to_value(&intent).unwrap();
    // A typed allowlist is deliberate: no arbitrary decision JSON can sneak a
    // signing key or person proof into the durable record.
    assert_eq!(serialized["binding"].as_object().unwrap().len(), 7);
    assert!(!serialized.to_string().contains("person_decision"));
    assert!(!serialized.to_string().contains("personDecision"));
    drop(store);
    let mut store = ConversationStore::open(Some(directory.path())).unwrap();
    let recovered = store.pending_question_deliveries().unwrap();
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].id, intent.id);
    assert_eq!(recovered[0].question, intent.question);
    assert!(matches!(
        store.lookup_question_delivery(&conversation, "answer-q", LOCAL_USER, &op).unwrap(),
        Some(DeliveryClaim::Reconcile(_))
    ));
    assert!(matches!(
        store
            .claim_question_delivery(&conversation, "answer-q", LOCAL_USER, &op, &binding())
            .unwrap(),
        DeliveryClaim::Reconcile(_)
    ));
    assert_eq!(
        store
            .connection
            .pragma_query_value(None, "synchronous", |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn changed_binding_or_operation_cannot_reuse_the_key() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    claim(&mut store, &conversation, &op);
    let mut changed = binding();
    changed.instance = "replacement-instance".into();
    let error = store
        .claim_question_delivery(&conversation, "answer-q", LOCAL_USER, &op, &changed)
        .unwrap_err();
    assert_eq!(error.to_string(), "idempotency_conflict");
    let mut changed = op.clone();
    if let Op::QuestionAnswer { part_index, .. } = &mut changed {
        *part_index = 1;
    }
    assert_eq!(
        store
            .lookup_question_delivery(&conversation, "answer-q", LOCAL_USER, &changed)
            .unwrap_err()
            .to_string(),
        "idempotency_conflict"
    );
    assert!(
        store
            .lookup_question_delivery(&conversation, "answer-q", "other_actor", &op)
            .unwrap()
            .is_none()
    );
}

#[test]
fn unknown_delivery_protects_only_its_message_across_restart() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    claim(&mut store, &conversation, &op);
    drop(store);
    let mut store = ConversationStore::open(Some(directory.path())).unwrap();
    let message_id = op.target_message_id().unwrap().to_owned();
    for mutation in [
        Op::MessageRetract { message_id: message_id.clone() },
        Op::MessageEdit { message_id, parts: vec![] },
        op.clone(),
    ] {
        assert_eq!(
            store
                .apply_op(&conversation, "competing", LOCAL_USER, &mutation)
                .unwrap_err()
                .to_string(),
            "question.delivery_pending"
        );
    }
    assert_eq!(
        store
            .claim_question_delivery(&conversation, "competing", LOCAL_USER, &op, &binding())
            .unwrap_err()
            .to_string(),
        "question.delivery_pending"
    );
    let parts =
        serde_json::from_value(json!([{"type":"text","text":"Unrelated message"}])).unwrap();
    store
        .apply_op(
            &conversation,
            "unrelated",
            LOCAL_USER,
            &Op::MessageSend {
                client_msg_id: "unrelated".into(),
                parts,
                reply_to: None,
                answers: vec![],
                answers_pending: vec![],
                thread_root: None,
            },
        )
        .unwrap();
}

#[test]
fn exact_success_commits_once_and_keyed_result_survives_restart() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    let intent = claim(&mut store, &conversation, &op);
    let mut wrong = binding();
    wrong.answers_digest = "d".repeat(64);
    assert_eq!(
        store
            .finish_question_delivery(&intent.id, &wrong, DeliveryResult::Delivered)
            .unwrap_err()
            .to_string(),
        "question.receipt_mismatch"
    );
    let DeliveryCompletion::Answered(first) =
        store.finish_question_delivery(&intent.id, &binding(), DeliveryResult::Delivered).unwrap()
    else {
        panic!("expected answer");
    };
    assert!(!first.replayed);
    assert!(store.pending_question_deliveries().unwrap().is_empty());
    drop(store);
    let mut store = ConversationStore::open(Some(directory.path())).unwrap();
    let DeliveryCompletion::Answered(replay) =
        store.finish_question_delivery(&intent.id, &binding(), DeliveryResult::Delivered).unwrap()
    else {
        panic!("expected replay");
    };
    assert!(replay.replayed);
    assert_eq!(replay.result, first.result);
    assert!(matches!(
        store.lookup_question_delivery(&conversation, "answer-q", LOCAL_USER, &op).unwrap(),
        Some(DeliveryClaim::Finished(_))
    ));
    assert!(store.apply_op(&conversation, "answer-q", LOCAL_USER, &op).unwrap().replayed);
}

#[test]
fn definitive_refusal_unblocks_but_preserves_keyed_refusal() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    let intent = claim(&mut store, &conversation, &op);
    let refusal = "question.agent_gone";
    assert!(
        matches!(store.finish_question_delivery(&intent.id, &binding(), DeliveryResult::Refused(refusal.into())).unwrap(), DeliveryCompletion::Refused(reason) if reason == refusal)
    );
    drop(store);
    let mut store = ConversationStore::open(Some(directory.path())).unwrap();
    assert!(store.pending_question_deliveries().unwrap().is_empty());
    assert!(
        matches!(store.lookup_question_delivery(&conversation, "answer-q", LOCAL_USER, &op).unwrap(), Some(DeliveryClaim::Refused(reason)) if reason == refusal)
    );
    assert!(matches!(
        store
            .claim_question_delivery(&conversation, "different-key", LOCAL_USER, &op, &binding())
            .unwrap(),
        DeliveryClaim::Send(_)
    ));
    assert_eq!(
        store
            .finish_question_delivery(&intent.id, &binding(), DeliveryResult::Delivered)
            .unwrap_err()
            .to_string(),
        "question.receipt_mismatch"
    );
}

#[test]
fn failed_finish_keeps_intent_and_does_not_record_answer() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    let intent = claim(&mut store, &conversation, &op);
    store.connection.execute_batch("CREATE TRIGGER fail_delivery_finish BEFORE UPDATE ON question_delivery BEGIN SELECT RAISE(ABORT, 'injected finish failure'); END;").unwrap();
    assert!(
        store.finish_question_delivery(&intent.id, &binding(), DeliveryResult::Delivered).is_err()
    );
    drop(store);
    let mut store = ConversationStore::open(Some(directory.path())).unwrap();
    assert_eq!(store.pending_question_deliveries().unwrap().len(), 1);
    let message =
        load_message_by_id(&store.connection, op.target_message_id().unwrap()).unwrap().unwrap();
    assert_eq!(message.parts[0], Part::Question(intent.question));
    let ledger_count: i64 = store
        .connection
        .query_row(
            "SELECT count(*) FROM op_ledger_v2 WHERE idempotency_key = 'answer-q'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(ledger_count, 0);
    store.connection.execute_batch("DROP TRIGGER fail_delivery_finish").unwrap();
    assert!(matches!(
        store.finish_question_delivery(&intent.id, &binding(), DeliveryResult::Delivered).unwrap(),
        DeliveryCompletion::Answered(_)
    ));
    assert!(matches!(
        store.lookup_question_delivery(&conversation, "answer-q", LOCAL_USER, &op).unwrap(),
        Some(DeliveryClaim::Finished(_))
    ));
}

#[test]
fn failed_claim_never_authorizes_send_or_changes_durability_default() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    store.connection.execute_batch("CREATE TRIGGER fail_delivery_claim BEFORE INSERT ON question_delivery BEGIN SELECT RAISE(ABORT, 'injected claim failure'); END;").unwrap();
    assert!(
        store
            .claim_question_delivery(&conversation, "answer-q", LOCAL_USER, &op, &binding())
            .is_err()
    );
    assert!(store.pending_question_deliveries().unwrap().is_empty());
    assert_eq!(
        store
            .connection
            .pragma_query_value(None, "synchronous", |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
    store.connection.execute_batch("DROP TRIGGER fail_delivery_claim").unwrap();
    claim(&mut store, &conversation, &op);
}

#[test]
fn older_store_is_upgraded_additively_without_changing_conversation_data() {
    let directory = Scratch::new();
    let (store, conversation, op) = fixture(directory.path());
    // Simulate a pre-outbox database, preserving its existing schema version
    // and all conversation rows.
    store.connection.execute_batch("DROP TABLE question_delivery").unwrap();
    drop(store);
    let mut store = ConversationStore::open(Some(directory.path())).unwrap();
    assert!(store.pending_question_deliveries().unwrap().is_empty());
    claim(&mut store, &conversation, &op);
}

#[test]
fn agent_or_unknown_actor_cannot_claim_a_person_answer() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    for actor in ["agent_mux", "user_unknown"] {
        assert!(
            store
                .claim_question_delivery(&conversation, "answer-q", actor, &op, &binding())
                .is_err()
        );
        assert!(store.pending_question_deliveries().unwrap().is_empty());
    }
    claim(&mut store, &conversation, &op);
}

#[test]
fn native_receipt_claim_is_query_only_even_on_first_attempt() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    let mut native = binding();
    native.receipt_id = Some("native-receipt".into());
    assert!(matches!(
        store.claim_question_delivery(&conversation, "answer-q", LOCAL_USER, &op, &native).unwrap(),
        DeliveryClaim::Reconcile(_)
    ));
    assert_eq!(
        store.pending_question_deliveries().unwrap()[0].binding.receipt_id,
        native.receipt_id
    );
    assert_eq!(
        store
            .claim_question_delivery(&conversation, "answer-q", LOCAL_USER, &op, &binding())
            .unwrap_err()
            .to_string(),
        "idempotency_conflict"
    );
}

#[test]
fn chief_author_is_stored_class_not_display_name_or_claimed_question_agent() {
    let directory = Scratch::new();
    let (store, conversation, op) = fixture(directory.path());
    assert!(store.question_author_is_chief(&conversation, &op).unwrap());
    assert!(!store.question_author_is_chief("different-conversation", &op).unwrap());
    let mut head = load_head(&store.connection, &conversation).unwrap().unwrap();
    let author = head.participants.iter_mut().find(|p| p.id == "agent_mux").unwrap();
    // The display name remains Chief, but this is no longer the Chief class.
    author.agent_class = Some(cmux_conversation::AgentClass::Agent);
    store
        .connection
        .execute(
            "UPDATE conversation SET participants_json = ?2 WHERE id = ?1",
            params![conversation, serde_json::to_string(&head.participants).unwrap()],
        )
        .unwrap();
    assert!(!store.question_author_is_chief(&conversation, &op).unwrap());
}

#[test]
fn local_session_prefix_binds_to_raw_acp_session_identity() {
    let directory = Scratch::new();
    let (mut store, conversation, op) = fixture(directory.path());
    let mut message =
        load_message_by_id(&store.connection, op.target_message_id().unwrap()).unwrap().unwrap();
    let Part::Question(question) = &mut message.parts[0] else { panic!("expected question") };
    question.session = "local/session1".into();
    store
        .connection
        .execute(
            "UPDATE message SET message_json = ?2 WHERE id = ?1",
            params![message.id, serde_json::to_string(&message).unwrap()],
        )
        .unwrap();
    let intent = claim(&mut store, &conversation, &op);
    assert_eq!(intent.question.session, "local/session1");
    assert_eq!(intent.binding.session_id, "session1");
}
