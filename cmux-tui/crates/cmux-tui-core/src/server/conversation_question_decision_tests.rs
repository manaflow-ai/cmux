//! conversation_question_decision.rs: the unsigned decision comes only from the live, local,
//! matching prompt, and the command is the trusted local connection's alone.

use serde_json::{Value, json};

use super::super::*;
use super::{decide_from, error_code};
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
    assert!(error.to_string().contains("trusted local connection"), "{error}");
}
