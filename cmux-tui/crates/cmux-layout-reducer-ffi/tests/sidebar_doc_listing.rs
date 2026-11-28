//! `sidebar_doc_listing` through the C ABI: replays `schemas/sidebar-doc-listing/vectors.json`,
//! random cases a line-by-line transliteration of Swift's `SidebarDocListing`, `SidebarDocProjection.Group` and `SidebarGroupSort` answered.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::Value;

const VECTORS: &str = include_str!("../../../../schemas/sidebar-doc-listing/vectors.json");

fn raw(request: &[u8]) -> (i32, Option<Value>) {
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                c"sidebar_doc_listing".as_ptr(),
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
fn every_listing_rule_matches_the_swift_for_every_case() {
    let cases: Vec<Value> = serde_json::from_str(VECTORS).expect("vectors are JSON");
    assert!(cases.len() >= 100);
    for case in &cases {
        assert_eq!(call(case["request"].clone()), case["answer"], "{case}");
    }
}

#[test]
fn a_malformed_request_is_refused() {
    assert_eq!(raw(br#"{"op":"listing"}"#).0, ERR_INVALID);
    assert_eq!(raw(br#"{"op":"ordered","sort":"size"}"#).0, ERR_INVALID);
}
