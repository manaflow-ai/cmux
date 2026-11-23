//! `sidebar_automatic_plan` through the C ABI: the sidebar sends one
//! candidate per drawn workspace row and folds the automatic ones behind
//! "Automatic (N)" unless `sidebar.showAutomaticSessions` is on.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_automatic_plan".as_ptr(),
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
fn sidebar_automatic_plan_folds_script_sessions_only() {
    let candidates = json!([
        {"created_by": "script"},
        {},
        {"created_by": "person"},
        {"created_by": "agent"},
        {"created_by": "script", "needs_input": true},
    ]);
    let (code, body) = call(&serde_json::to_vec(&json!({"candidates": candidates})).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"automatic": [0]}));
    let (code, body) = call(
        &serde_json::to_vec(&json!({"candidates": candidates, "show_automatic": true})).unwrap(),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"automatic": []}));
}

#[test]
fn sidebar_automatic_plan_refuses_a_malformed_request() {
    let (code, _) = call(br#"{"candidates": [{"created_by": "robot"}]}"#);
    assert_eq!(code, ERR_INVALID);
}
