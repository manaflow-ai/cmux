use super::super::tests::{answer, decision, pending, question};
use super::*;

fn intent() -> DeliveryIntent {
    let question = question();
    let op = Op::QuestionAnswer { message_id: "message".into(), part_index: 0, answer: answer() };
    let binding = prepare(&question, &op, Some(&decision(&question))).unwrap();
    DeliveryIntent {
        id: "attempt-1".into(),
        conversation: "conversation".into(),
        actor: "user_local".into(),
        idempotency_key: "key".into(),
        question,
        op,
        binding,
        fingerprint: "fingerprint".into(),
    }
}
fn delivered(intent: &DeliveryIntent) -> Value {
    let mut row = attempt(intent);
    row["session"] = json!(intent.binding.session_id);
    row["permission"] = json!(intent.binding.permission_id);
    row["option"] = json!(intent.binding.option_id);
    row["annotationsDigest"] = json!("");
    row["state"] = json!("delivered");
    json!({"deliveryAttempt":row})
}

#[test]
fn exact_receipt_commits_but_every_binding_mismatch_stays_unknown() {
    let intent = intent();
    let good = delivered(&intent);
    assert!(matches!(receipt(&intent, &good).unwrap(), DeliveryResult::Delivered));
    for key in [
        "id",
        "session",
        "permission",
        "option",
        "instance",
        "decisionNonce",
        "requestDigest",
        "answersDigest",
        "annotationsDigest",
        "state",
    ] {
        let mut changed = good.clone();
        changed["deliveryAttempt"][key] = json!("different");
        assert_eq!(
            receipt(&intent, &changed).unwrap_err().to_string(),
            "question.delivery_unknown",
            "{key}"
        );
    }
    assert_eq!(
        receipt(&intent, &json!({"deliveryAttempt":{"id":intent.id,"state":"unknown"}}))
            .unwrap_err()
            .to_string(),
        "question.delivery_unknown"
    );
}

#[test]
fn lost_ack_reconciles_receipt_without_resending() {
    let intent = intent();
    let decision = decision(&intent.question);
    let mut sends = 0;
    let result = exchange(&intent, Some(&decision), |method, params| {
        if method == "_acpmux/permission_respond" {
            sends += 1;
            assert_eq!(params["deliveryAttempt"], attempt(&intent));
            return Err(refuse("question.delivery_unknown"));
        }
        Ok(if params.get("deliveryAttempt").is_some() {
            delivered(&intent)
        } else if method == "_acpmux/info" {
            pending(&decision)
        } else {
            json!({})
        })
    })
    .unwrap();
    assert_eq!(sends, 1);
    assert!(matches!(result, DeliveryResult::Delivered));
    // A restarted owner has the durable intent, but neither decision nor proof.
    let result = exchange(&intent, None, |method, params| {
        assert_ne!(method, "_acpmux/permission_respond");
        Ok(if method == "_acpmux/info" {
            assert_eq!(params["deliveryAttempt"], intent.id);
            delivered(&intent)
        } else {
            json!({})
        })
    })
    .unwrap();
    assert!(matches!(result, DeliveryResult::Delivered));
}

#[test]
fn success_without_receipt_is_not_a_recordable_answer() {
    let intent = intent();
    let decision = decision(&intent.question);
    let result = exchange(&intent, Some(&decision), |method, params| {
        Ok(if method == "_acpmux/info" && params.get("deliveryAttempt").is_none() {
            pending(&decision)
        } else {
            json!({})
        })
    });
    let error = result.unwrap_err();
    assert_eq!(error.to_string(), "question.delivery_unknown");
    assert_eq!(
        super::super::super::error_code(&error).as_deref(),
        Some("conversation_indeterminate")
    );
}

#[test]
fn dropped_receiver_refusal_is_distinct_from_closed_transport() {
    let intent = intent();
    let mut row = delivered(&intent);
    row["deliveryAttempt"]["state"] = json!("refused");
    row["deliveryAttempt"]["reason"] = json!("agent_gone");
    assert!(
        matches!(receipt(&intent, &row).unwrap(), DeliveryResult::Refused(r) if r == "question.agent_gone")
    );
    let decision = decision(&intent.question);
    let error = exchange(&intent, Some(&decision), |method, params| {
        if method == "_acpmux/permission_respond" || params.get("deliveryAttempt").is_some() {
            Err(refuse("question.delivery_unknown"))
        } else {
            Ok(if method == "_acpmux/info" { pending(&decision) } else { json!({}) })
        }
    })
    .unwrap_err();
    assert_eq!(error.to_string(), "question.delivery_unknown");
}

fn native_fixture(allow: bool) -> (Question, Op, Value) {
    let request = json!({"toolCall":{"title":"Read file","rawInput":{"path":"hello"}},
        "options":[{"optionId":"custom-deny","kind":"reject_once"},
        {"optionId":"custom-allow","kind":"allow_once"}]});
    let item = format!("approval:{}", digest(&request));
    let question: Question =
        serde_json::from_value(json!({"harness":"chief","session":"local/session1",
        "permission":"permission1","items":[{"id":item,"prompt":"Read file", "allows_other":false,
        "options":[{"id":"allow","label":"Allow","preview":{"text":request.to_string()}},
        {"id":"deny","label":"Deny"}]}]}))
        .unwrap();
    let answer = serde_json::from_value(
        json!({"selections":{item:{"option_ids":[if allow {"allow"} else {"deny"}]}}}),
    )
    .unwrap();
    let op = Op::QuestionAnswer { message_id: "m".into(), part_index: 0, answer };
    let record = json!({"question":question,"receipt_id":"native-1","instance":"instance1","decision_nonce":"a".repeat(64)});
    (question, op, record)
}

#[test]
fn native_approval_uses_real_option_identity_and_never_sends_again() {
    for allow in [true, false] {
        let (question, op, record) = native_fixture(allow);
        let binding = prepare_native(&question, &op, &record).unwrap();
        assert_eq!(binding.option_id, if allow { "custom-allow" } else { "custom-deny" });
        assert_eq!(binding.session_id, "session1");
        assert_eq!(binding.answers_digest, "");
        let intent = DeliveryIntent { question, op, binding, ..intent() };
        let info = delivered(&intent);
        assert_eq!(info["deliveryAttempt"]["id"], "native-1");
        assert!(matches!(
            exchange(&intent, None, |method, _| {
                assert_ne!(method, "_acpmux/permission_respond");
                Ok(if method == "_acpmux/info" { info.clone() } else { json!({}) })
            })
            .unwrap(),
            DeliveryResult::Delivered
        ));
        let mut wrong = info;
        wrong["deliveryAttempt"]["option"] =
            json!(if allow { "custom-deny" } else { "custom-allow" });
        assert!(receipt(&intent, &wrong).is_err());
    }
}

#[test]
fn changed_native_card_or_request_is_not_recorded() {
    let (mut question, op, record) = native_fixture(true);
    question.session = "other-session".into();
    assert_eq!(prepare_native(&question, &op, &record).unwrap_err().to_string(), "question.stale");
    let (mut question, op, mut record) = native_fixture(true);
    question.items[0].options[0].preview.as_mut().unwrap().text = "{}".into();
    record["question"] = json!(question);
    assert_eq!(prepare_native(&question, &op, &record).unwrap_err().to_string(), "question.stale");
    let (mut question, op, mut record) = native_fixture(true);
    question.items[0].options[1].id = "allow".into();
    record["question"] = json!(question);
    assert_eq!(
        prepare_native(&question, &op, &record).unwrap_err().to_string(),
        "question.not_approval"
    );
}

#[test]
fn local_alias_uses_the_exact_qualified_target_for_read_send_and_receipt() {
    let mut intent = intent();
    intent.question.session = "local/session1".into();
    let decision = decision(&intent.question);
    intent.binding = prepare(&intent.question, &intent.op, Some(&decision)).unwrap();
    assert_eq!(intent.binding.session_id, "session1");
    let result = exchange(&intent, Some(&decision), |method, params| {
        if method != "initialize" {
            assert_eq!(params["sessionId"], "local/session1");
        }
        Ok(if params.get("deliveryAttempt").is_some() && method == "_acpmux/info" {
            delivered(&intent)
        } else if method == "_acpmux/info" {
            pending(&decision)
        } else {
            json!({})
        })
    })
    .unwrap();
    assert!(matches!(result, DeliveryResult::Delivered));
}
