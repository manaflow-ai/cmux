//! `sidebar_drag_geometry` through the C ABI: every transliterated vector in
//! schemas/sidebar-drag-geometry/vectors.json, sent as the app sends it.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/sidebar-drag-geometry/vectors.json");

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 1 << 20];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_drag_geometry".as_ptr(),
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
fn every_vector_answers_as_the_swift_did() {
    let doc: Value = serde_json::from_str(VECTORS).expect("vectors");
    for (index, case) in doc["geometry"].as_array().expect("cases").iter().enumerate() {
        let mut request = case.clone();
        let expected = request.as_object_mut().and_then(|o| o.remove("answers")).expect("answers");
        let (code, body) = call(request.to_string().as_bytes());
        assert_eq!(code, OK, "case {index}");
        let answers = &body.expect("reply")["answers"];
        assert!(same(answers, &expected), "case {index}");
    }
}

#[test]
fn an_empty_request_answers_nothing_and_bad_json_is_invalid() {
    let (code, body) = call(b"{}");
    assert_eq!(code, OK);
    assert_eq!(body.expect("reply"), json!({"answers": []}));
    assert_eq!(call(b"not json").0, ERR_INVALID);
    assert_eq!(call(br#"{"queries":[{"ask":"fly"}]}"#).0, ERR_INVALID);
}
