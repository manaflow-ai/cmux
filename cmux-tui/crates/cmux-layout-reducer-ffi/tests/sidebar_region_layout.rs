//! `sidebar_region_layout` and `sidebar_band_heights` through the C ABI:
//! every transliterated vector in schemas/sidebar-region-layout/vectors.json.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

const VECTORS: &str = include_str!("../../../../schemas/sidebar-region-layout/vectors.json");

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
fn every_region_vector_answers_as_the_swift_did() {
    replay("regions", c"sidebar_region_layout", "reply");
}

#[test]
fn every_band_heights_vector_answers_as_the_swift_did() {
    replay("band_heights", c"sidebar_band_heights", "heights");
}

#[test]
fn a_bare_band_lays_out_nothing_and_bad_json_is_invalid() {
    let metrics = json!({"row_height": 28, "header_height": 24, "inset": 8, "section_gap": 8, "padding": 8,
        "card_padding": 4, "tile_min_width": 42, "tile_height": 36, "tile_gap": 8});
    let (code, body) = call(
        c"sidebar_region_layout",
        json!({"width": 240, "metrics": metrics}).to_string().as_bytes(),
    );
    assert_eq!(code, OK);
    let body = body.expect("reply");
    assert_eq!(body["layout"]["height"], json!(0.0));
    assert_eq!(body["drops"], json!([]));
    assert_eq!(call(c"sidebar_region_layout", b"not json").0, ERR_INVALID);
    assert_eq!(call(c"sidebar_region_layout", b"{}").0, ERR_INVALID);
    assert_eq!(call(c"sidebar_band_heights", br#"{"available":1}"#).0, ERR_INVALID);
}
