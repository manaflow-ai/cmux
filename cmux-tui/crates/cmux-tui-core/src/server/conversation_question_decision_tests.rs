//! conversation_question_decision.rs: the unsigned decision comes only from the live, local,
//! matching prompt, and the command is the trusted local connection's alone.

use serde_json::{Value, json};

use super::super::*;
use super::{decide_from, error_code, record_question, request_digest};
use cmux_conversation::{Question, QuestionAnswer};

fn question(permission: Option<&str>) -> Question {
    serde_json::from_value(json!({
        "harness": "chief", "session": "sess_mux", "permission": permission,
        "items": [{"id": "q0", "prompt": "Ship it?", "multi_select": false,
                   "options": [{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}]}]
    }))
    .unwrap()
}

fn answer() -> QuestionAnswer {
    serde_json::from_value(json!({"selections": {"q0": {"option_ids": ["yes"]}}})).unwrap()
}

fn entry(permission: &str) -> Value {
    json!({"permissionId": permission, "personInstance": "0123456789abcdef",
           "decisionNonce": "b".repeat(64), "request": {
        "toolCall": {"_meta": {"acpmux": {"question": {"harness": "chief", "items": [
            {"id": "q0", "prompt": "Ship it?", "multiSelect": false, "allowsOther": true,
             "options": [{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}]}]}}}},
        "options": [{"optionId": "answer", "kind": "allow_once", "name": "Answer"}]}})
}

fn code(result: anyhow::Result<Value>) -> String {
    error_code(&result.expect_err("the decision must be refused")).unwrap()
}

#[test]
fn the_decision_is_the_live_prompts_with_its_request() {
    let info = json!({"pending": [entry("perm_other"), entry("perm_1")]});
    let decided = decide_from(&question(Some("perm_1")), &answer(), &info).unwrap();
    assert_eq!(decided["permission"], "perm_1");
    assert_eq!(decided["session"], "sess_mux");
    assert_eq!(decided["option_id"], "answer");
    assert_eq!(decided["instance"], "0123456789abcdef");
    assert_eq!(decided["decision_nonce"], "b".repeat(64));
    assert_eq!(decided["answers"], json!({"Ship it?": "Yes"}));
    assert_eq!(decided["request"], entry("perm_1")["request"]);
    assert_eq!(decided["question"], serde_json::to_value(question(Some("perm_1"))).unwrap());
    assert_eq!(decided["digest"], request_digest(&entry("perm_1")["request"]));
    let text = decided["request_json"].as_str().unwrap();
    assert_eq!(serde_json::from_str::<Value>(text).unwrap(), entry("perm_1")["request"]);
    assert_eq!(decided["digest"], request_digest(&serde_json::from_str(text).unwrap()));
}

#[test]
fn a_closed_peer_or_changed_prompt_gets_no_decision() {
    let q = question(Some("perm_1"));
    assert_eq!(code(decide_from(&q, &answer(), &json!({"pending": []}))), "question.closed");
    assert_eq!(code(decide_from(&q, &answer(), &json!({}))), "question.closed");
    let peer = json!({"peer": "other-mac", "pending": [entry("perm_1")]});
    assert_eq!(code(decide_from(&q, &answer(), &peer)), "question.not_local");
    let mut changed = entry("perm_1");
    changed["request"]["toolCall"]["_meta"]["acpmux"]["question"]["items"][0]["prompt"] =
        json!("Delete it?");
    assert_eq!(code(decide_from(&q, &answer(), &json!({"pending": [changed]}))), "question.stale");
    assert_eq!(
        code(decide_from(&question(None), &answer(), &json!({"pending": [entry("perm_1")]}))),
        "question.no_request"
    );
}

#[test]
fn only_a_trusted_local_connection_asks_and_a_missing_part_is_not_found() {
    let mux = Mux::new_for_test("question-decision", crate::SurfaceOptions::default());
    let writer = || {
        MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        })
    };
    let request = json!({"cmd": "conversation-question-decision", "conversation": "c1",
                         "message_id": "m1", "part_index": 0,
                         "answer": {"selections": {"q0": {"option_ids": ["yes"]}}}});
    let run = |client: u64| {
        let command: Command = serde_json::from_value(request.clone()).unwrap();
        handle_command(&mux, client, command, &writer())
    };
    let local = mux.control_clients.register(ClientTransport::Unix, writer());
    let error = run(local).expect_err("no such message");
    assert_eq!(response_error_code(&error).as_deref(), Some("question.not_found"));
    let remote = mux.control_clients.register(ClientTransport::Remote, writer());
    let error = run(remote).expect_err("a remote peer is refused");
    // The exact-name remote allowlist refuses it before the handler runs.
    assert_eq!(error.to_string(), "remote_denied");
}

#[test]
fn the_digest_sorts_keys_at_every_depth_and_an_approval_card_is_refused() {
    use sha2::{Digest, Sha256};
    let request = json!({"b": {"y": 1, "x": [{"d": 2, "c": "é"}]}, "a": null});
    let expected = format!(
        "{:x}",
        Sha256::digest(r#"{"a":null,"b":{"x":[{"c":"é","d":2}],"y":1}}"#.as_bytes())
    );
    assert_eq!(request_digest(&request), expected);
    let card: Question = serde_json::from_value(json!({
        "harness": "chief", "session": "sess_mux", "permission": "perm_1",
        "items": [{"id": format!("approval:{}", "a".repeat(64)), "prompt": "Run it?",
                   "multi_select": false, "allows_other": false,
                   "options": [{"id": "allow", "label": "Allow"}, {"id": "deny", "label": "Deny"}]}]
    }))
    .unwrap();
    let info = json!({"pending": [entry("perm_1")]});
    assert_eq!(code(decide_from(&card, &answer(), &info)), "question.native_approval");
}

/// The native record read returns the stored approval card unchanged, never a question's, and
/// only while it is pending.
#[test]
fn the_native_record_read_is_the_pending_approval_card_only() {
    let stored = json!({
        "harness": "chief", "session": "sess_mux", "permission": "perm_1", "agent": "Chief",
        "items": [{"id": format!("approval:{}", "a".repeat(64)), "header": "Tool", "prompt": "Run \"ls\" ✓?",
                   "multi_select": false, "allows_other": false,
                   "options": [{"id": "allow", "label": "Allow", "preview": {"text": "{\"a\":1}"}},
                               {"id": "deny", "label": "Deny"}]}]
    });
    let card: Question = serde_json::from_value(stored).unwrap();
    let read = record_question(&card).unwrap();
    assert_eq!(read, json!({"question": serde_json::to_value(&card).unwrap()}));
    let back: Question = serde_json::from_value(read["question"].clone()).unwrap();
    assert_eq!(back, card);
    assert_eq!(code(record_question(&question(Some("perm_1")))), "question.not_approval");
    let mut answered = card;
    answered.state = serde_json::from_value(json!({"kind": "cancelled"})).unwrap();
    assert_eq!(code(record_question(&answered)), "question.closed");
}

/// The request digest is the golden sha256, the bytes acpmux hashes and the app checks.
#[cfg(unix)]
#[test]
fn request_digest_matches_the_golden_fixture_and_acpmux() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../cmux-conversation/tests/fixtures/canonical_json.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        assert_eq!(request_digest(&case["value"]), case["sha256"].as_str().unwrap(), "{name}");
        let mut acpmux = String::new();
        acpmux::hub::approvers::canonical_json(&case["value"], &mut acpmux);
        assert_eq!(acpmux, case["canonical"].as_str().unwrap(), "{name}");
    }
}
