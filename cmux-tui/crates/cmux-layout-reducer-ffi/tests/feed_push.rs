//! `feed_push_<op>` through the C ABI: the Mac's half of the feed push rules
//! (`cmux-feed-push-core`; the phones call the same ops over uniffi).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(op: &str, request: &[u8]) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    // SAFETY: every pointer is live for the call, with its length.
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            op.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

#[test]
fn feed_push_answers_a_banner_action() {
    let request = json!({"action_identifier": "FEED_ALLOW",
        "user_info": {"aps": {"category": "FEED_APPROVE"}, "cmux": {"feed_item": "fi_9"}}});
    let (code, body) = call("feed_push_push_response", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body["response"], "send");
    assert_eq!(body["idempotency_key"], "feed-answer-fi_9-FEED_ALLOW");
    let (code, body) = call("feed_push_shown_text", br#"{"action":{"tool":"Bash","truncated":1}}"#);
    assert_eq!(code, OK);
    assert_eq!(body["truncated"], false);
}

#[test]
fn feed_push_refuses_unknown_ops_and_bad_requests() {
    assert_eq!(call("feed_push_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call("feed_push_op_reply", b"[").0, ERR_INVALID);
    assert_eq!(call("feed_push_op_answer", br#"{"item":1}"#).0, ERR_INVALID);
}
