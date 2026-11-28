//! The LayoutModel ops (`layout_state_*`) through the C ABI: every vector in
//! `schemas/layout-state/vectors.json` (the Swift rules' answers before the move) answers the same,
//! and an unknown op or a bad request is `ERR_INVALID`.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::Value;
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/layout-state/vectors.json");

fn call(op: &str, request: &[u8]) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let mut capacity = 1 << 12;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
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
        if code == ERR_BUFFER {
            capacity = len;
            continue;
        }
        let body =
            if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
        return (code, body);
    }
}

#[test]
fn every_vector_answers_as_the_swift_rules_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 400, "{} cases", cases.len());
    for (index, case) in cases.iter().enumerate() {
        let op = case["op"].as_str().unwrap();
        let request = serde_json::to_vec(&case["request"]).unwrap();
        let (code, body) = call(op, &request);
        assert_eq!(code, OK, "case {index} {op}");
        assert_eq!(body, case["response"], "case {index} {op}: {}", case["request"]);
    }
}

#[test]
fn an_unknown_op_or_bad_request_is_invalid() {
    assert_eq!(call("layout_state_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call("layout_state_focus", b"{\"pane\":1}").0, ERR_INVALID);
    assert_eq!(call("layout_state_focus", b"not json").0, ERR_INVALID);
}
