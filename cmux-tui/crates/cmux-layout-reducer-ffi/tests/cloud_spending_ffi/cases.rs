//! `cloud_spending_set_next` through the C ABI: the app sends the saved overage, the save's key and each reply, and
//! makes the one session call the answer names (cmux-cloud-start-core `spending_write` holds the rules).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

fn next(request: &Value) -> Value {
    let (code, reply) = call(c"cloud_spending_set_next", &serde_json::to_vec(request).unwrap());
    assert_eq!(code, OK);
    reply
}

#[test]
fn a_save_is_one_call_then_the_saved_cap() {
    let first = next(&json!({"overageUsd": 40, "key": "save-1"}));
    assert_eq!(
        first,
        json!({"next": "call", "path": "v1/ops", "body": {"op": "usage.cap.set", "origin": "user",
            "idempotency_key": "save-1", "params": {"overage_usd": 40.0}}})
    );
    let reply =
        json!({"ok": true, "value": {"owner": "team:t", "team_cap_usd": 140, "overage_usd": 40}});
    assert_eq!(
        next(&json!({"overageUsd": 40, "key": "save-1", "steps": [reply]})),
        json!({"next": "done", "outcome": {"kind": "saved", "overageUsd": 40.0, "teamCapUsd": 140.0}})
    );
}

#[test]
fn a_bad_amount_is_answered_without_a_call() {
    let reply = next(&json!({"overageUsd": 0, "key": "save-1"}));
    assert_eq!(reply["next"], "done");
    assert_eq!(reply["outcome"]["kind"], "invalid");
}

#[test]
fn a_request_that_is_not_one_is_refused() {
    assert_eq!(call(c"cloud_spending_set_next", b"{\"overageUsd\": 1}").0, ERR_INVALID);
    assert_eq!(call(c"cloud_spending_set_next", b"not json").0, ERR_INVALID);
}
