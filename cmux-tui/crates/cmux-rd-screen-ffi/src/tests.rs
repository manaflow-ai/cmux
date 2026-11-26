use std::ffi::CString;

use serde_json::{Value, json};

use super::*;

fn call(operation: &str, request: &[u8], capacity: usize) -> (i32, usize, Vec<u8>) {
    let operation = CString::new(operation).unwrap();
    let mut output = vec![0u8; capacity];
    let mut length = 0usize;
    // SAFETY: every pointer is valid for its length.
    let code = unsafe {
        cmux_rd_screen_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut length,
        )
    };
    output.truncate(length.min(capacity));
    (code, length, output)
}

#[test]
fn answers_as_the_rules_do() {
    let request = json!({"longEdge": 1179, "displayLongEdge": 3456, "now": 0.0});
    let (code, _, output) = call("screen_demand_report", request.to_string().as_bytes(), 4096);
    assert_eq!(code, OK);
    let ours: Value = serde_json::from_slice(&output).unwrap();
    let rules =
        cmux_rd_screen::json::respond("screen_demand_report", request.to_string().as_bytes());
    assert_eq!(Ok(ours), rules);
}

#[test]
fn too_small_a_buffer_names_the_length() {
    let request = json!({"longEdge": 1179, "displayLongEdge": 3456, "now": 0.0}).to_string();
    let (code, needed, _) = call("screen_demand_report", request.as_bytes(), 1);
    assert_eq!(code, ERR_BUFFER);
    let (code, length, _) = call("screen_demand_report", request.as_bytes(), needed);
    assert_eq!((code, length), (OK, needed));
}

#[test]
fn refuses_unknown_ops_bad_json_and_null() {
    assert_eq!(call("screen_nope", b"{}", 64).0, ERR_UNKNOWN);
    assert_eq!(call("screen_demand_report", b"not json", 64).0, ERR_INVALID);
    let mut length = 0usize;
    // SAFETY: a null operation is refused before any read.
    let code = unsafe {
        cmux_rd_screen_json(
            std::ptr::null(),
            0,
            std::ptr::null(),
            std::ptr::null_mut(),
            0,
            &mut length,
        )
    };
    assert_eq!(code, ERR_NULL);
    assert_eq!(cmux_rd_screen_abi_version(), ABI_VERSION);
}
