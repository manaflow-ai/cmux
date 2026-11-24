use super::redact_message_hosts;
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
