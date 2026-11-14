use serde_json::{Map, Value, json};

use super::super::super::terminal_talk::send::Wait;
use super::{LIST, SEND, descriptors, send_request};

fn arguments(value: Value) -> Map<String, Value> {
    value.as_object().cloned().expect("an object")
}

#[test]
fn descriptors_name_both_tools_and_send_requires_target_and_text() {
    let [list, send] = descriptors();
    assert_eq!((list["name"].as_str(), send["name"].as_str()), (Some(LIST), Some(SEND)));
    assert_eq!(send["inputSchema"]["required"], json!(["target", "text"]));
    assert_eq!(list["annotations"]["readOnlyHint"], true);
    assert_eq!(send["annotations"]["readOnlyHint"], false);
    assert_eq!(
        send["inputSchema"]["properties"]["idempotency_key"]["maxLength"], 128,
        "a composed send needs a stable retry identity: {send}"
    );
}

#[test]
fn send_arguments_become_the_cli_request() {
    let (request, session) = send_request(&arguments(json!({
        "target": "term_a", "text": "hi\nthere", "wait": "prompt",
        "timeout_seconds": 20, "settle_seconds": 0.5, "force": true, "session": "work",
        "idempotency_key": "repeatable-send",
    })))
    .expect("valid");
    assert_eq!(request.target, "term_a");
    assert_eq!(request.text, "hi\nthere");
    assert_eq!(request.wait, Wait::Prompt);
    assert_eq!(request.timeout.as_secs(), 20);
    assert_eq!(request.settle.as_millis(), 500);
    assert!(request.force);
    assert_eq!(request.idempotency_key.as_deref(), Some("repeatable-send"));
    assert_eq!(session.as_deref(), Some("work"));
    let (defaults, _) =
        send_request(&arguments(json!({"target": "t", "text": "x"}))).expect("valid");
    assert_eq!((defaults.wait, defaults.timeout.as_secs()), (Wait::Idle, 300));
}

#[test]
fn send_arguments_refuse_unknown_names_and_bad_values() {
    for bad in [
        json!({"target": "t"}),
        json!({"target": "t", "text": "x", "colour": "red"}),
        json!({"target": "t", "text": "x", "wait": "later"}),
        json!({"target": "t", "text": "x", "timeout_seconds": 5000}),
        json!({"target": "t", "text": "x", "force": "yes"}),
        json!({"target": "t", "text": "x", "idempotency_key": ""}),
        json!({"target": "t", "text": "x", "idempotency_key": "x".repeat(129)}),
    ] {
        assert!(send_request(&arguments(bad.clone())).is_err(), "{bad}");
    }
}
