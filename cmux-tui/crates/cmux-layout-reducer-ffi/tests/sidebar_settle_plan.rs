//! `sidebar_settle_plan` through the C ABI: the sidebar sends one candidate
//! per drawn workspace row and folds the settled ones behind "Settled (N)";
//! Archive Settled Chats sends the same and archives the settled ones.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_settle_plan".as_ptr(),
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
fn sidebar_settle_plan_answers_settled_and_kept_rows() {
    let request = json!({
        "candidates": [
            {"chat": true, "lifecycle": "finished", "has_activity": true},
            {"chat": true, "lifecycle": "finished", "has_activity": true, "unread": true},
            {"chat": true, "lifecycle": "failed", "has_activity": true},
            {"chat": true, "lifecycle": "lost", "has_activity": true},
            {"chat": true, "lifecycle": "working", "has_activity": true},
            {"chat": false},
        ],
        "trigger": "archive",
    });
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"settled": [0], "kept": {"unread": [1], "failed": [2], "lost": [3], "busy": [4]}})
    );
}

#[test]
fn sidebar_settle_plan_refuses_a_malformed_request() {
    let (code, _) = call(b"{\"candidates\": 3}");
    assert_eq!(code, ERR_INVALID);
}
