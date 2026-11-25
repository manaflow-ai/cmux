//! `group_hover_summary` through the C ABI: the group hover card sends its
//! members and sections once per card show and puts the typed lines it gets
//! back into localized words.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"group_hover_summary".as_ptr(),
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
fn group_hover_summary_answers_typed_lines() {
    let request = json!({
        "members": [
            {"title": "api", "activity": "failed", "branch": "main"},
            {"title": "web", "activity": "waiting", "branch": "main"},
        ],
        "sections": ["status", "git"],
        "max_members": 6,
        "now": 1_800_000_000.0,
    });
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"blocks": [
            {"section": "status", "tone": "danger", "lines": [{"line": "status", "parts": [
                {"kind": "waiting", "count": 1}, {"kind": "failed", "count": 1}]}]},
            {"section": "git", "tone": "secondary",
             "lines": [{"line": "branches", "listed": "main", "more": 0}]},
        ]})
    );
}

#[test]
fn group_hover_summary_refuses_a_malformed_request() {
    assert_eq!(call(br#"{"sections": ["nope"]}"#).0, ERR_INVALID);
}
