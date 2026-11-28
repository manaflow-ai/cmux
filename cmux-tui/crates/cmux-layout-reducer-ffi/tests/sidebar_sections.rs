//! `sidebar_sections` through the C ABI: replays `schemas/sidebar-sections/vectors.json`, random
//! cases a line-by-line transliteration of the Swift sections' membership, loose-row detectors and
//! workspace order answered.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/sidebar-sections/vectors.json");

fn raw(request: &[u8]) -> (i32, Option<Value>) {
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                c"sidebar_sections".as_ptr(),
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
fn every_rule_matches_the_swift_for_every_case() {
    let cases: Vec<Value> = serde_json::from_str(VECTORS).expect("vectors are JSON");
    assert!(cases.len() >= 100);
    for case in &cases {
        let sections = &case["sections"];
        let new = &case["new"];
        let answer =
            call(json!({"op": "filter", "sections": sections, "members": case["members"]}));
        assert_eq!(answer["sections"], case["filter"], "filter {case}");
        let answer =
            call(json!({"op": "pinned_first", "sections": sections, "pinned": case["pinned"]}));
        assert_eq!(answer["sections"], case["pinnedFirst"], "pinned_first {case}");
        let answer = call(json!({"op": "hiding", "sections": sections, "hidden": case["hidden"]}));
        assert_eq!(answer["sections"], case["hiding"], "hiding {case}");
        let answer = call(json!({"op": "without_placeholders", "sections": sections}));
        assert_eq!(answer["sections"], case["withoutPlaceholders"], "without_placeholders {case}");
        let answer = call(json!({"op": "workspace_order", "sections": sections}));
        assert_eq!(answer["ids"], case["order"], "workspace_order {case}");
        let answer =
            call(json!({"op": "ordering", "sections": sections, "members": case["memberList"]}));
        assert_eq!(answer["members"], case["ordering"], "ordering {case}");
        let answer =
            call(json!({"op": "ordering", "order": case["order"], "members": case["memberList"]}));
        assert_eq!(answer["members"], case["ordering"], "ordering by order {case}");
        for (op, key) in [
            ("loose_insertion", "insertion"),
            ("loose_removal", "removal"),
            ("loose_move", "move"),
            ("loose_edits", "edits"),
        ] {
            let answer = call(json!({"op": op, "old": sections, "new": new}));
            assert_eq!(answer, case[key], "{op} {case}");
        }
    }
}

#[test]
fn a_malformed_request_is_refused() {
    assert_eq!(raw(br#"{"op":"filter","sections":[]}"#).0, ERR_INVALID);
    assert_eq!(
        raw(br#"{"op":"loose_move","old":[{"nodes":[{"tab":{}}]}],"new":[]}"#).0,
        ERR_INVALID
    );
}
