//! `focus_state_*` through the C ABI: the app's focus read view rules (cmux-focus-core
//! state_rules) answer every case of schemas/focus-state-rules/vectors.json, and refuse an
//! unknown op or a request that does not decode.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/focus-state-rules/vectors.json");

fn call(op: &str, request: &[u8]) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let mut output = vec![0u8; 1 << 16];
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

#[derive(Deserialize)]
struct Case {
    name: String,
    op: String,
    request: Value,
    expect: Value,
}

#[derive(Deserialize)]
struct Vectors {
    cases: Vec<Case>,
}

#[test]
fn focus_state_ops_answer_every_shared_vector() {
    let vectors: Vectors = serde_json::from_str(VECTORS).unwrap();
    assert!(vectors.cases.len() > 300);
    let failed: Vec<String> = vectors
        .cases
        .iter()
        .filter_map(|case| {
            let (code, body) = call(&case.op, &serde_json::to_vec(&case.request).unwrap());
            (code != OK || body != case.expect).then(|| format!("{}: {code} {body}", case.name))
        })
        .collect();
    assert!(failed.is_empty(), "{} failed:\n{}", failed.len(), failed.join("\n"));
}

#[test]
fn focus_state_survives_keeps_keys_under_the_tabs_store_id() {
    let request = json!({
        "wait": {"focus": {"agentPage": {"pane": "pane_a", "tab": "pending_tab_1"}}, "page": "readiness-1"},
        "settled": {"agentPage": {"pane": "pane_a", "tab": "tab_1"}},
        "settledPage": "readiness-1",
    });
    let (code, body) =
        call("focus_state_type_ahead_survives", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"survives": true}));
}

#[test]
fn focus_state_refuses_an_unknown_op_or_a_bad_request() {
    assert_eq!(call("focus_state_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call("focus_state_responder_name", b"{\"responder\":7}").0, ERR_INVALID);
    assert_eq!(call("focus_state_wait_change", b"").0, ERR_INVALID);
}
