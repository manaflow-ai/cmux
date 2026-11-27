//! `sidebar_doc_target` through the C ABI: replays `schemas/sidebar-doc-target/vectors.json`, random
//! cases a line-by-line transliteration of Swift's `SidebarDocStore.target`, `SidebarDocDrag` and
//! `SidebarHostGroup` answered.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/sidebar-doc-target/vectors.json");

fn raw(request: &[u8]) -> (i32, Option<Value>) {
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                c"sidebar_doc_target".as_ptr(),
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
fn every_anchor_move_and_intent_matches_the_swift_for_every_case() {
    let cases: Vec<Value> = serde_json::from_str(VECTORS).expect("vectors are JSON");
    assert!(cases.len() >= 100);
    for case in &cases {
        let mut request = json!({"op": "target", "section": "s", "index": case["index"],
            "siblings": case["siblings"], "moving": case["moving"]});
        if !case["parent"].is_null() {
            request["parent"] = case["parent"].clone();
        }
        assert_eq!(call(request.clone())["target"], case["target"], "target {case}");
        request["nested"] = case["nested"].clone();
        assert_eq!(call(request)["target"], case["topLevel"], "top level {case}");
        let unplaced = &case["unplaced"];
        let answer = call(json!({"op": "unplaced_target", "in_group": unplaced["in_group"],
            "index": unplaced["index"], "rows": unplaced["rows"]}));
        assert_eq!(answer["target"], unplaced["answer"], "unplaced {case}");
        let keyboard = &case["keyboard"];
        let answer = call(json!({"op": "keyboard_move", "visible": keyboard["visible"],
            "moving": keyboard["moving"], "items": keyboard["items"], "up": keyboard["up"]}));
        assert_eq!(answer["move"], keyboard["answer"], "keyboard {case}");
        let host = &case["host"];
        let answer = call(json!({"op": "resolving_host_group", "intent": host["intent"],
            "ends": host["ends"]}));
        assert_eq!(answer["intent"], host["answer"], "host {case}");
        let count = &case["count"];
        let answer = call(json!({"op": "document_node_count",
            "draws_as_group": count["draws_as_group"], "nodes": count["nodes"]}));
        assert_eq!(answer["count"], count["answer"], "count {case}");
    }
}

#[test]
fn a_malformed_request_is_refused() {
    assert_eq!(raw(br#"{"op":"target","section":"s"}"#).0, ERR_INVALID);
    assert_eq!(raw(br#"{"op":"resolving_host_group","intent":{"kind":"fly"}}"#).0, ERR_INVALID);
}
