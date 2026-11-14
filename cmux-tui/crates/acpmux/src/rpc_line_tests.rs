use super::*;
use serde_json::json;

/// `to_line` writes from borrowed fields the bytes `to_value` wrote, keys in
/// the same order, so readers that compare lines byte for byte
/// (`server/list_reply.rs`) see no change.
#[test]
fn a_line_is_the_bytes_of_the_value() {
    let error =
        RpcError { code: -32000, message: "no".into(), data: Some(json!({"b": 1, "a": 2})) };
    for message in [
        Message::request(1, "session/prompt", json!({"z": 1, "a": [1, 2]})),
        Message::notification("_acpmux/event", json!({"kind": "x"})),
        Message::Request { id: json!(5), method: "session/cancel".into(), params: None },
        Message::Notification { method: "_acpmux/ping".into(), params: None },
        Message::Response { id: json!(6), result: None, error: None },
        Message::ok(json!("id"), json!({"ok": true})),
        Message::ok(json!(2), Value::Null),
        Message::err(json!(3), error),
        Message::err(json!(4), RpcError::new(-1, "bare")),
    ] {
        assert_eq!(message.to_line(), format!("{}\n", message.to_value()), "{message:?}");
    }
}
