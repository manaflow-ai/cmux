//! `sidebar_layout_fold` through the C ABI: every vector in schemas/sidebar-layout-fold/vectors.json,
//! each reply from a transliteration of the Swift (SidebarLayout+Fold, +Insert, +Selection,
//! SidebarLayoutKeyIndex, SidebarDragLook).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::Value;
use std::ffi::CStr;

const VECTORS: &str = include_str!("../../../../schemas/sidebar-layout-fold/vectors.json");

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let op: &CStr = c"sidebar_layout_fold";
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

#[test]
fn every_fold_vector_answers_as_the_swift_did() {
    let doc: Value = serde_json::from_str(VECTORS).expect("vectors");
    let cases = doc["cases"].as_array().expect("cases");
    assert!(cases.len() >= 20, "{} cases", cases.len());
    for case in cases {
        let name = case["name"].as_str().expect("name");
        let (code, body) = call(case["request"].to_string().as_bytes());
        assert_eq!(code, OK, "{name}");
        assert!(same(&body.expect("reply"), &case["reply"]), "{name}");
    }
}

#[test]
fn a_request_without_a_known_rule_is_refused() {
    let (code, _) = call(br#"{"rule":"nope"}"#);
    assert_eq!(code, ERR_INVALID);
    let (code, _) = call(b"not json");
    assert_eq!(code, ERR_INVALID);
}
