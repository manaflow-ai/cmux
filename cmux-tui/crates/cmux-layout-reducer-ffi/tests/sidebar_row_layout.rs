//! `sidebar_row_layout` through the C ABI: the settings as written in, the row's lines out.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 4096];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_row_layout".as_ptr(),
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
fn an_agents_layout_resolves_to_its_lines_and_slots() {
    let request = json!({
        "lines": [["name"]],
        "linesByAgent": {"claude": [["icon", "name", "branch"], ["agentStatus", "working"]]},
        "kind": "agent",
        "agent": "claude",
    });
    let (code, body) = call(request.to_string().as_bytes());
    assert_eq!(code, OK);
    let body = body.expect("reply");
    assert_eq!(body["custom"], json!(true));
    assert_eq!(body["source"], json!("agent"));
    assert_eq!(body["lines"], json!([["name", "branch"], ["agentStatus"]]));
    assert_eq!(body["slots"], json!({"icon": true, "working": true, "progress": false}));
    assert_eq!(body["problems"], json!([]));
}

#[test]
fn no_layout_answers_not_custom() {
    let (code, body) = call(br#"{"kind":"terminal"}"#);
    assert_eq!(code, OK);
    let body = body.expect("reply");
    assert_eq!(body["custom"], json!(false));
    assert!(body.get("source").is_none());
}

#[test]
fn a_request_that_is_not_an_object_is_refused() {
    let (code, _) = call(br#"[1,2]"#);
    assert_eq!(code, ERR_INVALID);
}
