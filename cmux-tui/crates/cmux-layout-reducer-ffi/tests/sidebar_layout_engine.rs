//! `sidebar_layout_engine` through the C ABI:
//! every transliterated vector in schemas/sidebar-layout-engine/vectors.json.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::Value;
use std::ffi::CStr;

const VECTORS: &str = include_str!("../../../../schemas/sidebar-layout-engine/vectors.json");

fn call(op: &CStr, request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 1 << 20];
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
    let body =
        (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
    (code, body)
}

/// JSON equality that reads every number as f64.
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

fn replay(key: &str, op: &CStr, answer: &str) {
    let doc: Value = serde_json::from_str(VECTORS).expect("vectors");
    for (index, case) in doc[key].as_array().expect("cases").iter().enumerate() {
        let mut request = case.clone();
        let expected = request.as_object_mut().and_then(|o| o.remove(answer)).expect("answer");
        let (code, body) = call(op, request.to_string().as_bytes());
        assert_eq!(code, OK, "{key} case {index}");
        assert!(same(&body.expect("reply"), &expected), "{key} case {index}");
    }
}

#[test]
fn every_layout_engine_vector_answers_as_the_swift_did() {
    replay("cases", c"sidebar_layout_engine", "reply");
}

#[test]
fn a_request_without_a_known_rule_is_refused() {
    let (code, _) = call(c"sidebar_layout_engine", br#"{"rule":"nope"}"#);
    assert_eq!(code, ERR_INVALID);
    let (code, _) = call(c"sidebar_layout_engine", b"not json");
    assert_eq!(code, ERR_INVALID);
}
