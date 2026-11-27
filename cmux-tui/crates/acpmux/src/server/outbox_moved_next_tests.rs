use super::*;

/// What `transfer_out.rs` `moved_error` answers.
fn moved_error(to: &Value) -> RpcError {
    RpcError::new(-32000, "transfer.moved: this chat moved; it runs there, never here")
        .with_data(json!({"movedTo": to}))
}

/// A moved chat's refusal names where it went, and the delivery goes there; a chat in the
/// middle of a move is tried again soon, and neither is a refusal that fails the delivery.
#[test]
fn a_moved_chat_is_followed_and_a_moving_one_is_waited_for() {
    let to = json!({"host": "gcp-1", "sessionId": "m1", "cwd": "/w"});
    let moved = moved_error(&to);
    assert_eq!(next(&moved), Next::Moved("gcp-1/m1".into()));
    let here = moved_error(&json!({"sessionId": "m2"}));
    assert_eq!(next(&here), Next::Moved("m2".into()));
    let sibling = moved_error(&json!({"socket": "/tmp/dev.sock", "sessionId": "m3"}));
    let handed = Next::MovedToSocket { socket: "/tmp/dev.sock".into(), session: "m3".into() };
    assert_eq!(next(&sibling), handed);
    let nowhere = moved_error(&json!({"host": "gcp-1"}));
    assert_eq!(next(&nowhere), Next::Retry);
    let moving =
        RpcError::new(-32000, "transfer.moving: this chat is being moved to another daemon");
    assert_eq!(next(&moving), Next::Moving);
}
