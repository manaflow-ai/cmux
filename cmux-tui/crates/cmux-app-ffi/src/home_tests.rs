use super::*;
use serde_json::Value;
use std::ffi::CString;

fn call(op: &str, request: &str) -> (i32, Option<Value>) {
    let op = CString::new(op).unwrap();
    let mut out = CmuxHomeBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: valid pointers for the call.
    let status = unsafe { cmux_home_call(op.as_ptr(), request.as_ptr(), request.len(), &mut out) };
    if status != CMUX_HOME_OK {
        return (status, None);
    }
    // SAFETY: the reply buffer the call wrote.
    let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    let value = serde_json::from_slice(reply).ok();
    // SAFETY: freed once.
    unsafe { cmux_home_bytes_free(out) };
    (status, value)
}

#[test]
fn ops_list_answers() {
    let (status, reply) = call("ops.list", "{}");
    assert_eq!(status, CMUX_HOME_OK);
    let names: Vec<String> = serde_json::from_value(reply.unwrap()).unwrap();
    assert_eq!(names, cmux_home_rules::ops::op_names());
}

#[test]
fn bad_calls_answer_their_codes() {
    assert_eq!(call("nope", "{}").0, CMUX_HOME_ERR_UNKNOWN_OP);
    assert_eq!(call("inbox.nope", "{}").0, CMUX_HOME_ERR_UNKNOWN_OP);
    assert_eq!(call("ops.list", "[]").0, CMUX_HOME_ERR_INVALID);
    assert_eq!(call("ops.list", "{").0, CMUX_HOME_ERR_INVALID);
}
