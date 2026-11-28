//! The C ABI the macOS app calls (src/ffi.rs, include/cmux_update_prewarm.h):
//! both ops through `cmux_update_prewarm_call`, and the codes.

use cmux_update_prewarm_core::ffi::*;
use serde_json::{Value, json};
use std::ffi::CString;

fn empty() -> CmuxUpdatePrewarmBytes {
    CmuxUpdatePrewarmBytes { ptr: std::ptr::null_mut(), len: 0 }
}

fn take(slot: &mut CmuxUpdatePrewarmBytes) -> Value {
    let bytes = std::mem::replace(slot, empty());
    let value = if bytes.ptr.is_null() {
        Value::Null
    } else {
        // SAFETY: a reply buffer of `len` bytes from the library.
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(bytes.ptr, bytes.len) })
            .expect("JSON reply")
    };
    // SAFETY: freed once.
    unsafe { cmux_update_prewarm_bytes_free(bytes) };
    value
}

fn call_bytes(op: &str, body: &[u8]) -> Result<Value, i32> {
    let op = CString::new(op).expect("op");
    let mut out = empty();
    // SAFETY: valid pointers for the call.
    let code =
        unsafe { cmux_update_prewarm_call(op.as_ptr(), body.as_ptr(), body.len(), &mut out) };
    if code == CMUX_UPDATE_PREWARM_OK { Ok(take(&mut out)) } else { Err(code) }
}

fn call(op: &str, request: &Value) -> Result<Value, i32> {
    call_bytes(op, &serde_json::to_vec(request).expect("request"))
}

#[test]
fn c_abi_a_staged_build_from_start_to_its_launch() {
    let build = "4382263402601";
    let started = call("marker.encode", &json!({"build": build, "state": "started"}));
    assert_eq!(started, Ok(json!({"line": "4382263402601 started\n"})));
    let cut = call("marker.verdict", &json!({"build": build, "marker": "4382263402601 started\n"}));
    assert_eq!(
        cut,
        Ok(json!({"pre_warmed": false, "reason": "started_not_finished", "consume": true}))
    );
    let main = call("marker.encode", &json!({"build": build, "state": "main"}));
    let line = main.ok().and_then(|reply| reply["line"].as_str().map(str::to_owned));
    let warm = call("marker.verdict", &json!({"build": build, "marker": line}));
    assert_eq!(warm, Ok(json!({"pre_warmed": true, "reason": "main", "consume": true})));
    let later = call(
        "marker.verdict",
        &json!({"build": "4382263400000", "marker": "4382263402601 main\n"}),
    );
    assert_eq!(
        later,
        Ok(json!({"pre_warmed": false, "reason": "other_build:4382263402601", "consume": false}))
    );
}

#[test]
fn c_abi_the_codes() {
    assert_eq!(cmux_update_prewarm_abi_version(), CMUX_UPDATE_PREWARM_ABI_VERSION);
    assert_eq!(call("nope", &json!({})), Err(CMUX_UPDATE_PREWARM_ERR_UNKNOWN_OP));
    assert_eq!(call("marker.verdict", &json!([1])), Err(CMUX_UPDATE_PREWARM_ERR_INVALID));
    assert_eq!(call_bytes("marker.verdict", b"{not json"), Err(CMUX_UPDATE_PREWARM_ERR_INVALID));
    assert_eq!(
        call("marker.encode", &json!({"build": "a b", "state": "main"})),
        Err(CMUX_UPDATE_PREWARM_ERR_INVALID)
    );

    let mut out = empty();
    // SAFETY: a null op is refused before any read.
    let code = unsafe { cmux_update_prewarm_call(std::ptr::null(), std::ptr::null(), 0, &mut out) };
    assert_eq!(code, CMUX_UPDATE_PREWARM_ERR_NULL);
    let op = CString::new("marker.verdict").expect("op");
    // SAFETY: a null out is refused before any write.
    let code =
        unsafe { cmux_update_prewarm_call(op.as_ptr(), std::ptr::null(), 0, std::ptr::null_mut()) };
    assert_eq!(code, CMUX_UPDATE_PREWARM_ERR_NULL);
    // SAFETY: a null request with a length is refused before any read.
    let code = unsafe { cmux_update_prewarm_call(op.as_ptr(), std::ptr::null(), 4, &mut out) };
    assert_eq!(code, CMUX_UPDATE_PREWARM_ERR_NULL);
    // SAFETY: an empty request is `{}`, which has no build.
    let code = unsafe { cmux_update_prewarm_call(op.as_ptr(), std::ptr::null(), 0, &mut out) };
    assert_eq!(code, CMUX_UPDATE_PREWARM_ERR_INVALID);
    let bad = [b'm', 0xff, 0];
    // SAFETY: a NUL-terminated op that is not UTF-8.
    let code =
        unsafe { cmux_update_prewarm_call(bad.as_ptr().cast(), std::ptr::null(), 0, &mut out) };
    assert_eq!(code, CMUX_UPDATE_PREWARM_ERR_INVALID);
    // SAFETY: a null buffer is ignored.
    unsafe { cmux_update_prewarm_bytes_free(empty()) };
}
