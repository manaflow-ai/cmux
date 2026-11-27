//! `sidebar_archive_marks` through the C ABI: replays `schemas/sidebar-archive-marks/vectors.json`,
//! random cases a line-by-line transliteration of Swift's `AutoArchiveCoordinator` and `SidebarDocRecords`
//! answered.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/sidebar-archive-marks/vectors.json");

fn raw(request: &[u8]) -> (i32, Option<Value>) {
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                c"sidebar_archive_marks".as_ptr(),
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
fn every_mark_and_list_matches_the_swift_for_every_case() {
    let cases: Vec<Value> = serde_json::from_str(VECTORS).expect("vectors are JSON");
    assert!(cases.len() >= 100);
    for case in &cases {
        let records = &case["records"];
        let answer = call(json!({"op": "archivable", "records": records, "items": case["named"]}));
        assert_eq!(answer["archivable"], case["archivable"], "archivable {case}");
        let answer = call(json!({"op": "marks", "records": records,
            "candidates": case["candidates"], "shown": case["shown"]}));
        assert_eq!(answer["marks"], case["marks"], "marks {case}");
        assert_eq!(answer["rules"], case["rules"], "rules {case}");
        let answer =
            call(json!({"op": "archived", "records": records, "candidates": case["candidates"]}));
        assert_eq!(answer["rows"], case["rows"], "rows {case}");
        let answer = call(json!({"op": "item", "records": records, "id": case["probe"]}));
        assert_eq!(answer, case["item"], "item {case}");
    }
}

#[test]
fn a_malformed_request_is_refused() {
    assert_eq!(raw(br#"{"op":"archivable"}"#).0, ERR_INVALID);
    assert_eq!(raw(br#"{"op":"marks","candidates":[{"item":1}]}"#).0, ERR_INVALID);
}
