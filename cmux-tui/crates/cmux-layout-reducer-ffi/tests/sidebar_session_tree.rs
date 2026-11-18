//! `sidebar_session_tree` and `sidebar_session_tree_fold` through the C ABI: the sidebar sends one
//! list's rows with their parents and states, and draws the order, depths, chevrons and status
//! marks it gets back; a chevron click or a Left/Right arrow sends the folds and saves the answer.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(operation: &std::ffi::CStr, request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

#[test]
fn sidebar_session_tree_answers_the_drawn_rows() {
    let request = json!({
        "rows": [
            {"id": "ws:a", "state": "idle"},
            {"id": "sub:a:1", "parent": "ws:a", "state": "running"},
            {"id": "ws:b", "state": "done"},
        ],
    });
    let (code, body) = call(c"sidebar_session_tree", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"rows": [
            {"index": 0, "depth": 0, "fold": "collapsed", "mark": "running",
             "rollUp": {"needsInput": 0, "failed": 0, "running": 1, "hidden": 1}},
            {"index": 2, "depth": 0, "mark": "done"},
        ]})
    );
    let open = json!({"rows": request["rows"], "expanded": ["ws:a"]});
    let (_, body) = call(c"sidebar_session_tree", &serde_json::to_vec(&open).unwrap());
    assert_eq!(body["rows"][1], json!({"index": 1, "depth": 1, "mark": "running"}));
    assert_eq!(body["rows"][0]["fold"], "expanded");
}

#[test]
fn sidebar_session_tree_fold_flips_and_saves_one_side() {
    let request = json!({"expanded": [], "collapsed": [], "id": "ws:a", "parents": ["ws:a"]});
    let (code, body) = call(c"sidebar_session_tree_fold", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"expanded": ["ws:a"], "collapsed": [], "open": true}));
}

#[test]
fn sidebar_session_tree_refuses_a_malformed_request() {
    let (code, _) = call(c"sidebar_session_tree", br#"{"rows": 3}"#);
    assert_eq!(code, ERR_INVALID);
}
