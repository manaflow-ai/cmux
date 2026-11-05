//! `agent_cursor_visibility` through the C ABI: every case of
//! schemas/agent-cursor-visibility/vectors.json, sent as the app sends it
//! (`{"target", "snapshot"}`), answers its `expect` in the shape the app
//! decodes. A malformed request is refused, never a panic.

use cmux_focus_core::agent_cursor_visibility::Visibility;
use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/agent-cursor-visibility/vectors.json");

fn call(request: &[u8]) -> (i32, Vec<u8>) {
    let mut output = vec![0u8; 4096];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"agent_cursor_visibility".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    output.truncate(if code == OK { len } else { 0 });
    (code, output)
}

#[test]
fn agent_cursor_visibility_op_answers_every_vector() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 26);
    for case in cases {
        let request = json!({"target": case["target"], "snapshot": case["snapshot"]});
        let (code, body) = call(&serde_json::to_vec(&request).unwrap());
        assert_eq!(code, OK, "{}", case["name"]);
        let got: Visibility = serde_json::from_slice(&body).unwrap();
        let expect: Visibility = serde_json::from_value(case["expect"].clone()).unwrap();
        assert_eq!(got, expect, "{}: {}", case["name"], String::from_utf8_lossy(&body));
        let kind: Value = serde_json::from_slice::<Value>(&body).unwrap()["kind"].clone();
        assert_eq!(kind, case["expect"]["kind"], "{}", case["name"]);
    }
}

#[test]
fn agent_cursor_visibility_op_refuses_a_malformed_request() {
    assert_eq!(call(b"{").0, ERR_INVALID);
    assert_eq!(call(br#"{"target":"t"}"#).0, ERR_INVALID);
    assert_eq!(call(br#"{"target":"t","snapshot":{"windows":[{"id":"w"}]}}"#).0, ERR_INVALID);
}
