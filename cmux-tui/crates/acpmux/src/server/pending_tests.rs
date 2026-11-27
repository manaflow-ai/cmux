use super::{has_message_hosts, redact_message_hosts};
use serde_json::json;

#[test]
fn peer_message_projection_redacts_sender_host_everywhere() {
    let mut value = json!({
        "method": "_acpmux/message",
        "params": {"sessionId": "s", "sender": {"name": "lane", "sessionId": "src", "host": "gcp-1"}, "text": "hello", "messageId": "m"},
        "event": {"kind": "_acpmux/message", "msg": {"sender": {"name": "lane", "sessionId": "src", "host": "gcp-1"}}},
        "events": [{"kind": "_acpmux/message", "msg": {"sender": {"host": "gcp-1"}}}]
    });
    assert!(redact_message_hosts(&mut value));
    assert!(value.pointer("/params/sender/host").is_none());
    assert!(value.pointer("/event/msg/sender/host").is_none());
    assert!(value.pointer("/events/0/msg/sender/host").is_none());
}

/// A peer link copies a message only when it has a sender host to take out: the check agrees
/// with the redaction on every shape it redacts and on ones it leaves alone.
#[test]
fn the_host_check_agrees_with_the_redaction() {
    let cases = [
        json!({"event": {"kind": "_acpmux/message", "msg": {"sender": {"host": "gcp-1"}}}}),
        json!({"events": [{"kind": "_acpmux/message", "msg": {"sender": {"host": "gcp-1"}}}]}),
        json!({"messageId": "m", "sender": {"name": "lane", "host": "gcp-1"}}),
        json!({"kind": "_acpmux/message", "msg": {"sender": {"name": "lane"}}}),
        json!({"sender": {"host": "gcp-1"}}),
        json!({"kind": "other", "msg": {"sender": {"host": "gcp-1"}}}),
        json!({"sessionId": "s", "session": {"title": "t", "tools": [1, 2]}}),
        json!("host"),
    ];
    for case in cases {
        let mut copy = case.clone();
        assert_eq!(has_message_hosts(&case), redact_message_hosts(&mut copy), "{case}");
        assert!(!has_message_hosts(&copy), "{copy}");
    }
}
