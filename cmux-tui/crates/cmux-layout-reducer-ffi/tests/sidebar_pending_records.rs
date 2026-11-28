//! `sidebar_pending_records` through the C ABI: replays `schemas/sidebar-pending-records/vectors.json`,
//! random cases a line-by-line transliteration of Swift's `SidebarDocPendingRecords` answered.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/sidebar-pending-records/vectors.json");

fn raw(request: &[u8]) -> (i32, Option<Value>) {
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                c"sidebar_pending_records".as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut len,
            )
        };
        if code == ERR_BUFFER {
            capacity = len.max(capacity * 2);
            continue;
        }
        let body =
            (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
        return (code, body);
    }
}

fn call(request: Value) -> Value {
    let (code, body) = raw(request.to_string().as_bytes());
    assert_eq!(code, OK, "{request}");
    body.expect("reply")
}

#[test]
fn the_writes_and_the_laid_records_match_the_swift_for_every_case() {
    let cases: Vec<Value> = serde_json::from_str(VECTORS).expect("vectors are JSON");
    assert!(cases.len() >= 100);
    for case in &cases {
        let answer = call(json!({"op": "writes", "ops": case["ops"], "items": case["items"]}));
        assert_eq!(answer["writes"], case["writes"], "writes {case}");
        let writes = if case["writes"].is_null() { json!([]) } else { case["writes"].clone() };
        let answer = call(json!({"op": "apply", "writes": writes, "items": case["items"]}));
        assert_eq!(answer["items"], case["applied"], "apply {case}");
    }
}

#[test]
fn a_malformed_request_is_refused() {
    assert_eq!(raw(br#"{"op":"apply","writes":[{"rename":{}}]}"#).0, ERR_INVALID);
    assert_eq!(raw(br#"{"op":"writes"}"#).0, ERR_INVALID);
}
