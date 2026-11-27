use super::*;

/// A reply too large for one frame goes as the error reply for its id; a request or a
/// notification that large is its sender's to fail. Neither goes out whole.
#[test]
fn a_message_too_large_for_one_frame_never_goes_out_whole() {
    let big = json!({"text": "x".repeat(MAX_MESSAGE_BYTES)});
    let reply = Message::ok(json!(7), big.clone()).bounded_line().unwrap();
    assert!(reply.len() < 1024, "{} bytes", reply.len());
    let Message::Response { id, error: Some(e), .. } = Message::parse(&reply).unwrap() else {
        panic!("not an error reply: {reply}");
    };
    assert_eq!(id, json!(7));
    assert_eq!(e.data.unwrap()["reason"], "message.too_large");
    assert!(Message::request(8, "session/prompt", big.clone()).bounded_line().is_err());
    assert!(Message::notification("_acpmux/event", big).bounded_line().is_err());
    let small = Message::ok(json!(9), json!({"ok": true}));
    assert_eq!(small.bounded_line().unwrap(), small.to_line());
}

/// `line_within` is `to_line` up to its cap, byte for byte, and nothing past it: a line one
/// byte over is refused, and one of a frame and more is refused without being written whole.
#[test]
fn a_line_is_written_only_up_to_its_cap() {
    let reply = Message::ok(json!(1), json!({"text": "x".repeat(1000), "n": [1, 2, 3]}));
    let line = reply.to_line();
    assert_eq!(reply.line_within(line.len()).as_deref(), Some(line.as_str()));
    assert_eq!(reply.line_within(line.len() - 1), None);
    let big = Message::ok(json!(2), json!({"text": "x".repeat(2 * MAX_MESSAGE_BYTES)}));
    assert_eq!(big.line_within(MAX_MESSAGE_BYTES), None);
    let refused = big.bounded_line().unwrap();
    assert!(refused.contains("message.too_large"), "{refused}");
    assert!(refused.len() < 1024, "{} bytes", refused.len());
}
