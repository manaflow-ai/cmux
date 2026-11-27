use super::*;
use std::ffi::CString;

fn call(op: &str, request: &str) -> (i32, Option<Value>) {
    let op = CString::new(op).unwrap();
    let mut out = CmuxSettingsBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: valid pointers for the call.
    let status =
        unsafe { cmux_settings_call(op.as_ptr(), request.as_ptr(), request.len(), &mut out) };
    if status != CMUX_SETTINGS_OK {
        return (status, None);
    }
    // SAFETY: the reply buffer the call wrote.
    let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    let value = serde_json::from_slice(reply).ok();
    // SAFETY: freed once.
    unsafe { cmux_settings_bytes_free(out) };
    (status, value)
}

#[test]
fn jsonc_parse_round_trips() {
    let (status, reply) = call("jsonc.parse", r#"{"source": "{\"a\": 1, // c\n}"}"#);
    assert_eq!(status, CMUX_SETTINGS_OK);
    assert_eq!(reply, Some(serde_json::json!({ "value": { "a": 1 } })));
}

#[test]
fn bad_calls_answer_their_codes() {
    assert_eq!(call("nope", "{}").0, CMUX_SETTINGS_ERR_UNKNOWN_OP);
    assert_eq!(call("jsonc.parse", "[]").0, CMUX_SETTINGS_ERR_INVALID);
    assert_eq!(call("jsonc.parse", "{}").0, CMUX_SETTINGS_ERR_INVALID);
}
