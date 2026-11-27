//! `sidebar_list_rules` through the C ABI: every vector from the Swift transliteration answers the
//! same through the JSON op, and a request with no known rule is refused.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::path::PathBuf;

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_list_rules".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
    (code, body)
}

fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

#[test]
fn every_vector_answers_through_the_c_abi() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/sidebar-list-rules/vectors.json");
    let doc: Value =
        serde_json::from_str(&std::fs::read_to_string(path).expect("vectors")).expect("json");
    for (n, case) in doc["cases"].as_array().expect("cases").iter().enumerate() {
        let (code, body) = call(case["request"].to_string().as_bytes());
        assert_eq!(code, OK, "case {n}");
        let body = body.expect("reply");
        assert!(same(&body, &case["response"]), "case {n}: got {body}");
    }
}

#[test]
fn a_pill_hit_answers_contains() {
    let request = json!({"rule": "pill", "rect": {"x": 0, "y": 0, "width": 100, "height": 30},
        "inset": 4, "cornerRadius": 10, "point": {"x": 50, "y": 15}});
    let (code, body) = call(request.to_string().as_bytes());
    assert_eq!(code, OK);
    assert_eq!(body, Some(json!({"contains": true})));
}

#[test]
fn an_unknown_rule_or_malformed_request_is_refused() {
    assert_eq!(call(br#"{"rule":"nope"}"#).0, ERR_INVALID);
    assert_eq!(call(br#"{"rule":"rowAt"}"#).0, ERR_INVALID);
    assert_eq!(call(b"not json").0, ERR_INVALID);
}
