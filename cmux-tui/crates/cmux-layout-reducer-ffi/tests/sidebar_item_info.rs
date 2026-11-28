//! `sidebar_item_info` through the C ABI: every transliterated vector in
//! schemas/sidebar-item-info/vectors.json.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::Value;

const VECTORS: &str = include_str!("../../../../schemas/sidebar-item-info/vectors.json");

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_item_info".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
    (code, body)
}

#[test]
fn every_item_info_vector_answers_as_the_swift_did() {
    let vectors: Value = serde_json::from_str(VECTORS).expect("vectors parse");
    let cases = vectors["cases"].as_array().expect("cases");
    assert!(cases.len() > 500);
    for case in cases {
        let request = serde_json::to_vec(&case["request"]).expect("request encodes");
        let (code, body) = call(&request);
        assert_eq!(code, OK, "request {}", case["request"]);
        assert_eq!(body.as_ref(), Some(&case["reply"]), "request {}", case["request"]);
    }
}

#[test]
fn an_unknown_rule_and_bad_json_are_invalid() {
    assert_eq!(call(br#"{"rule":"nope"}"#).0, ERR_INVALID);
    assert_eq!(call(b"not json").0, ERR_INVALID);
}
