//! `workspace_creation_*` through the C ABI: the app sends a new workspace's facts and gets back its
//! name, its start and the requests it sends.

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

#[test]
fn workspace_creation_default_name_leaves_home_out() {
    let request = json!({"workspaces": [{"name": "home", "kind": "home"}, {"name": "workspace-2"}],
                         "reserved": ["workspace-3"]});
    let (code, body) =
        call("workspace_creation_default_name", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"name": "workspace-4"}));
}

#[test]
fn workspace_creation_terminal_env_puts_placement_last() {
    let request = json!({"app": {"A": "app"}, "caller": {"CMUX_SURFACE_ID": "spoof"},
                         "workspace": "w", "terminal": "t"});
    let (code, body) =
        call("workspace_creation_terminal_env", &serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body["env"]["CMUX_SURFACE_ID"], "t");
    assert_eq!(body["env"]["A"], "app");
}

#[test]
fn workspace_creation_empty_request_is_null() {
    let (code, body) = call("workspace_creation_default_name", b"");
    assert_eq!(code, OK);
    assert_eq!(body, json!({"name": "workspace-1"}));
}

#[test]
fn workspace_creation_refuses_a_request_that_is_not_its_json() {
    let (code, _) = call("workspace_creation_tab_key", br#"{"surface": 3}"#);
    assert_eq!(code, ERR_INVALID);
    let (code, _) = call("workspace_creation_nope", b"{}");
    assert_eq!(code, ERR_INVALID);
}
