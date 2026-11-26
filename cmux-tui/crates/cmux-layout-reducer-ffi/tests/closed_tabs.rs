//! `closed_tabs_*` through the C ABI: the app sends its machines' closed items and the facts it
//! keeps, and gets back the closed history's rules (cmux-app-closed-tabs).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(op: &str, request: &[u8]) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let mut output = vec![0u8; 1 << 12];
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

fn machines() -> Value {
    json!([
        {"machine": "local", "local": true, "serves": true, "items": [
            {"id": "a", "kind": "tab", "closed_at_ms": "10", "workspace_id": "ws1",
             "screens": [{"tabs": [{"kind": "terminal", "cwd": "/x"}]}]},
            {"id": "b", "kind": "tab", "closed_at_ms": "20", "workspace_id": "ws2",
             "screens": [{"tabs": [{"kind": "browser", "url": "https://a.test/"}]}]},
        ], "workspaceWindows": {"ws1": "w1", "ws2": "w2"}},
    ])
}

#[test]
fn closed_tabs_newest_picks_this_windows_close() {
    let request =
        json!({"machines": machines(), "installs": ["i"], "registry": {}, "window": "w1"});
    let (code, body) = call("closed_tabs_newest", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"machine": 0, "item": 0}));
}

#[test]
fn closed_tabs_history_rows_are_newest_first() {
    let request = json!({"machines": machines()});
    let (code, body) = call("closed_tabs_history_rows", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    let ids: Vec<_> = body.as_array().unwrap().iter().map(|row| row["id"].clone()).collect();
    assert_eq!(ids, [json!("closed:daemon:b"), json!("closed:daemon:a")]);
}

#[test]
fn closed_tabs_an_empty_request_is_an_empty_object() {
    let (code, body) = call("closed_tabs_is_served", b"");
    assert_eq!(code, OK);
    assert_eq!(body, json!({"served": false}));
}

#[test]
fn closed_tabs_refuses_an_unknown_op_and_a_bad_request() {
    assert_eq!(call("closed_tabs_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call("closed_tabs_entry", b"{}").0, ERR_INVALID);
    assert_eq!(call("closed_tabs_entries", b"not json").0, ERR_INVALID);
}
