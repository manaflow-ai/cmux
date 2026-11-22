//! `tab_discard_*` through the C ABI: the app sends its hidden browser pages' facts and gets back
//! which go now (`tab_discard_plan`), and what a page's probe answer keeps (`tab_discard_probe`).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(op: &str, request: &[u8]) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    // SAFETY: every pointer is live for the call, with its length.
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            op.as_ptr(),
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
fn tab_discard_plan_takes_a_plain_hidden_tab_and_keeps_a_pinned_one() {
    let request = json!({
        "setting": {"mode": "moderate"},
        "pressure": "critical",
        "candidates": [
            {"key": "plain", "hidden_for": 120.0},
            {"key": "pinned", "hidden_for": 120.0, "is_pinned": true},
        ],
    });
    let (code, body) = call("tab_discard_plan", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body["due"], json!(["plain"]));
    assert_eq!(body["exemptions"], json!({"pinned": "pinned"}));
}

#[test]
fn tab_discard_probe_keeps_audio_and_form_input() {
    for (key, probe, reason) in [
        ("ffi-audio", json!({"playing_media": true}), json!("audio")),
        ("ffi-form", json!({"edited_form": true}), json!("form_input")),
        ("ffi-plain", json!({}), Value::Null),
    ] {
        let request = json!({"key": key, "probe": probe, "pressure": "critical"});
        let (code, body) = call("tab_discard_probe", &serde_json::to_vec(&request).unwrap());
        assert_eq!(code, OK);
        assert_eq!(body["exemption"], reason, "{key}");
    }
}

#[test]
fn tab_discard_refuses_a_malformed_request_or_an_unknown_op() {
    assert_eq!(call("tab_discard_plan", b"{\"pressure\":\"high\"}").0, ERR_INVALID);
    assert_eq!(call("tab_discard_plan", b"not json").0, ERR_INVALID);
    assert_eq!(call("tab_discard_nope", b"{}").0, ERR_INVALID);
}
