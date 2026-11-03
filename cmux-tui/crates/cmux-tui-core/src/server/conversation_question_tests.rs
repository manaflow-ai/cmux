use super::*;
use crate::conversation_store::{ConversationStore, LOCAL_USER};
use cmux_conversation::{Op, Part, Participant};

fn question() -> Question {
    serde_json::from_value(
        json!({"harness":"claude","session":"session1","permission":"permission1",
        "items":[{"id":"q0","prompt":"Pick a color","options":[{"id":"o0","label":"Blue"}]}]}),
    )
    .unwrap()
}
fn answer() -> QuestionAnswer {
    serde_json::from_value(json!({"selections":{"q0":{"option_ids":["o0"]}}})).unwrap()
}
fn decision(question: &Question) -> Value {
    let request = json!({"sessionId":question.session,
    "options":[{"optionId":"allow","kind":"allow_once"}],
    "toolCall":{"_meta":{"acpmux":{"question":{
        "harness":"claude","items":[{"id":"q0","prompt":"Pick a color",
        "options":[{"id":"o0","label":"Blue"}],"multiSelect":false,"allowsOther":true}]
    }}}}});
    json!({"question":question,"digest":digest(&request),"request":request,
        "instance":"instance1","option_id":"allow","decision_nonce":"a".repeat(64),
        "person_decision":"b".repeat(64)})
}
fn pending(decision: &Value) -> Value {
    json!({"pending":[{"permissionId":"permission1","personInstance":"instance1",
        "decisionNonce":decision["decision_nonce"],"request":decision["request"]}]})
}

#[test]
fn answered_forwards_the_exact_proof_and_derived_answers() {
    let q = question();
    let d = decision(&q);
    let decoded = decode(&q, Some(&d)).unwrap();
    let mut sent = vec![];
    deliver_with(&q, &answer(), &decoded, |method, params| {
        sent.push((method.to_owned(), params));
        Ok(if method == "_acpmux/info" { pending(&d) } else { json!({}) })
    })
    .unwrap();
    assert_eq!(sent.len(), 3);
    assert_eq!(sent[2].0, "_acpmux/permission_respond");
    assert_eq!(sent[2].1["answers"], json!({"Pick a color":"Blue"}));
    assert_eq!(sent[2].1["_meta"]["acpmux"]["personDecision"], d["person_decision"]);
}

#[test]
fn stale_request_digest_is_refused_without_sending() {
    let q = question();
    let d = decision(&q);
    let decoded = decode(&q, Some(&d)).unwrap();
    let mut info = pending(&d);
    info["pending"][0]["request"]["toolCall"]["title"] = json!("Replaced");
    let error = deliver_with(&q, &answer(), &decoded, |method, _| {
        assert_ne!(method, "_acpmux/permission_respond");
        Ok(if method == "_acpmux/info" { info.clone() } else { json!({}) })
    })
    .unwrap_err();
    assert_eq!(error.to_string(), "question.stale");
}

#[test]
fn changed_question_and_recomputed_wrong_snapshot_are_refused() {
    let q = question();
    let mut d = decision(&q);
    let mut changed = q.clone();
    changed.items[0].prompt = "Pick a different color".into();
    assert_eq!(decode(&changed, Some(&d)).err().unwrap().to_string(), "question.stale");
    d["request"]["toolCall"]["_meta"]["acpmux"]["question"]["items"][0]["prompt"] =
        json!("Another question");
    d["digest"] = json!(digest(&d["request"]));
    assert_eq!(decode(&q, Some(&d)).err().unwrap().to_string(), "question.stale");
}

#[test]
fn closed_request_and_agent_gone_are_refusals() {
    let q = question();
    let d = decision(&q);
    let decoded = decode(&q, Some(&d)).unwrap();
    let error = deliver_with(&q, &answer(), &decoded, |method, _| {
        assert_ne!(method, "_acpmux/permission_respond");
        Ok(json!({"pending":[]}))
    })
    .unwrap_err();
    assert_eq!(error.to_string(), "question.closed");
    let error = deliver_with(&q, &answer(), &decoded, |_, _| Err(refuse("question.agent_gone")))
        .unwrap_err();
    assert_eq!(error.to_string(), "question.agent_gone");
}

#[test]
fn unproven_text_never_becomes_permission_authority() {
    let q = question();
    assert_eq!(decode(&q, None).err().unwrap().to_string(), "question.person_decision_required");
    let mut d = decision(&q);
    d["person_decision"] = json!("yes");
    assert_eq!(decode(&q, Some(&d)).err().unwrap().to_string(), "question.invalid_decision");
}

fn store() -> (ConversationStore, String, Op) {
    let mut store = ConversationStore::open(None).unwrap();
    let participants: Vec<Participant> = serde_json::from_value(json!([
        {"id":"user_local","kind":"human","display_name":"Me"},
        {"id":"agent_mux","kind":"agent","display_name":"Chief","agent_class":"mux","acp_session":"session1"}
    ])).unwrap();
    let created = store.create("create-q", LOCAL_USER, "Questions", &participants).unwrap();
    let conversation = created.summary.id.clone();
    let sent = store
        .apply_op(
            &conversation,
            "ask-q",
            "agent_mux",
            &Op::MessageSend {
                client_msg_id: "ask-q".into(),
                parts: vec![Part::Question(question())],
                reply_to: None,
                answers: vec![],
                answers_pending: vec![],
                thread_root: None,
            },
        )
        .unwrap();
    let message = sent.result.change["message"]["id"].as_str().unwrap().to_owned();
    let op = Op::QuestionAnswer { message_id: message, part_index: 0, answer: answer() };
    (store, conversation, op)
}

#[test]
fn delivery_refusal_rolls_back_then_answer_commits_once() {
    let (mut store, conversation, op) = store();
    let error = store
        .answer_question(&conversation, "answer-q", LOCAL_USER, &op, |_| {
            Err(refuse("question.agent_gone"))
        })
        .unwrap_err();
    assert_eq!(error.to_string(), "question.agent_gone");
    let result = store
        .answer_question(&conversation, "answer-q", LOCAL_USER, &op, |q| {
            assert_eq!(q.state, QuestionState::Pending);
            Ok(())
        })
        .unwrap();
    assert!(!result.replayed);
    let replay = store
        .answer_question(&conversation, "answer-q", LOCAL_USER, &op, |_| {
            panic!("replay sent twice")
        })
        .unwrap();
    assert!(replay.replayed);
    let error = store
        .answer_question(&conversation, "answer-again", LOCAL_USER, &op, |_| {
            panic!("closed sent twice")
        })
        .unwrap_err();
    assert_eq!(error.to_string(), "question_closed");
}

#[test]
fn store_rejects_stale_digest_without_committing_or_sending() {
    let (mut store, conversation, op) = store();
    let mut d = decision(&question());
    d["digest"] = json!("0".repeat(64));
    let error = store
        .answer_question(&conversation, "stale-answer", LOCAL_USER, &op, |q| {
            decode(q, Some(&d)).map(|_| ())
        })
        .unwrap_err();
    assert_eq!(error.to_string(), "question.stale");
    // The failed delivery did not close the question or spend an idempotency key.
    assert!(
        !store
            .answer_question(&conversation, "stale-answer", LOCAL_USER, &op, |_| Ok(()))
            .unwrap()
            .replayed
    );
}

#[test]
fn refusals_use_home_final_rejection_not_indeterminate_retry() {
    let error = refuse("question.agent_gone");
    assert_eq!(super::super::error_code(&error).as_deref(), Some("conversation_rejected"));
}
