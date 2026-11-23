//! `sidebar_shelf_plan` through the C ABI: the sidebar sends one candidate per
//! drawn workspace row and folds the shelved ones behind "Working (N)".

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_shelf_plan".as_ptr(),
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
fn sidebar_shelf_plan_answers_the_shelved_rows() {
    let request = json!({
        "candidates": [
            {"chat": true, "lifecycle": "finished", "background_waits": 1},
            {"chat": true, "lifecycle": "working", "background_waits": 1},
            {"chat": true, "lifecycle": "finished", "background_waits": 1, "unread": true},
            {"chat": true, "lifecycle": "idle"},
            {"chat": false, "background_waits": 2},
        ],
    });
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"shelved": [0]}));
}

#[test]
fn sidebar_shelf_plan_refuses_a_malformed_request() {
    let (code, _) = call(b"{\"candidates\": 3}");
    assert_eq!(code, ERR_INVALID);
}
