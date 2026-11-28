//! `cmux_design_call` through the C ABI, as the app calls it.

use cmux_design_core::ffi::*;
use serde_json::Value;
use std::ffi::CString;

fn call(op: &str, request: &str) -> (i32, Option<Value>) {
    let op = CString::new(op).unwrap();
    let mut out = CmuxDesignBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: valid pointers for the call.
    let status =
        unsafe { cmux_design_call(op.as_ptr(), request.as_ptr(), request.len(), &mut out) };
    if status != CMUX_DESIGN_OK {
        return (status, None);
    }
    // SAFETY: the reply buffer the call wrote.
    let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    let value = serde_json::from_slice(reply).ok();
    // SAFETY: freed once.
    unsafe { cmux_design_bytes_free(out) };
    (status, value)
}

#[test]
fn echo_round_trips() {
    let (status, reply) = call("core.echo", r#"{"a": [1, "b"]}"#);
    assert_eq!(status, CMUX_DESIGN_OK);
    assert_eq!(reply, Some(serde_json::json!({"a": [1, "b"]})));
}

#[test]
fn an_empty_request_reads_as_an_empty_object() {
    assert_eq!(call("core.echo", ""), (CMUX_DESIGN_OK, Some(serde_json::json!({}))));
}

#[test]
fn bad_calls_answer_their_codes() {
    assert_eq!(call("nope.op", "{}").0, CMUX_DESIGN_ERR_UNKNOWN_OP);
    assert_eq!(call("toast.nope", "{}").0, CMUX_DESIGN_ERR_UNKNOWN_OP);
    assert_eq!(call("core.echo", "[]").0, CMUX_DESIGN_ERR_INVALID);
    assert_eq!(call("core.echo", "{").0, CMUX_DESIGN_ERR_INVALID);
    let mut out = CmuxDesignBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: a null op is the case under test.
    let status = unsafe { cmux_design_call(std::ptr::null(), std::ptr::null(), 0, &mut out) };
    assert_eq!(status, CMUX_DESIGN_ERR_NULL);
    assert_eq!(cmux_design_abi_version(), CMUX_DESIGN_ABI_VERSION);
}
