//! The C ABI the macOS app calls (src/ffi.rs, include/cmux_daemon_launch.h):
//! every golden vector through `cmux_daemon_launch_call`, a watch scenario
//! through the handle, the line splitter, the login capture, and the codes.

use cmux_daemon_launch_core::ffi::*;
use serde_json::Value;
use std::ffi::CString;

#[path = "golden.rs"]
#[allow(dead_code)]
mod golden;

fn take(slot: &mut CmuxDaemonLaunchBytes) -> Value {
    let bytes =
        std::mem::replace(slot, CmuxDaemonLaunchBytes { ptr: std::ptr::null_mut(), len: 0 });
    let value = if bytes.ptr.is_null() {
        Value::Null
    } else {
        // SAFETY: a reply buffer of `len` bytes from the library.
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(bytes.ptr, bytes.len) })
            .expect("JSON reply")
    };
    // SAFETY: freed once.
    unsafe { cmux_daemon_launch_bytes_free(bytes) };
    value
}

fn call(op: &str, request: &Value) -> Result<Value, i32> {
    let op = CString::new(op).expect("op");
    let body = serde_json::to_vec(request).expect("request");
    let mut out = CmuxDaemonLaunchBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: valid pointers for the call.
    let code = unsafe { cmux_daemon_launch_call(op.as_ptr(), body.as_ptr(), body.len(), &mut out) };
    if code == CMUX_DAEMON_LAUNCH_OK { Ok(take(&mut out)) } else { Err(code) }
}

#[test]
fn c_abi_every_vector_through_the_call() {
    for file in golden::OP_FILES {
        for case in golden::cases(file) {
            let op = case["op"].as_str().unwrap_or_default();
            assert_eq!(
                call(op, &case["request"]),
                Ok(case["expect"].clone()),
                "{file} {}",
                case["name"]
            );
        }
    }
}

#[test]
fn c_abi_the_codes() {
    assert_eq!(cmux_daemon_launch_abi_version(), CMUX_DAEMON_LAUNCH_ABI_VERSION);
    assert_eq!(call("nope", &serde_json::json!({})), Err(CMUX_DAEMON_LAUNCH_ERR_UNKNOWN_OP));
    assert_eq!(
        call("version_decision", &serde_json::json!([1])),
        Err(CMUX_DAEMON_LAUNCH_ERR_INVALID)
    );
    let mut out = CmuxDaemonLaunchBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: a null op is refused before any read.
    let code = unsafe { cmux_daemon_launch_call(std::ptr::null(), std::ptr::null(), 0, &mut out) };
    assert_eq!(code, CMUX_DAEMON_LAUNCH_ERR_NULL);
    let op = CString::new("reap_grace_probes").expect("op");
    // SAFETY: an empty request is `{}`.
    let code = unsafe { cmux_daemon_launch_call(op.as_ptr(), std::ptr::null(), 0, &mut out) };
    assert_eq!(code, CMUX_DAEMON_LAUNCH_OK);
    assert_eq!(take(&mut out), serde_json::json!([["--help"], ["help", "start"]]));
}

#[test]
fn c_abi_a_watch_scenario_through_the_handle() {
    // SAFETY: an empty policy is the standard one.
    let watch = unsafe { cmux_daemon_launch_watch_new(std::ptr::null(), 0) };
    assert!(!watch.is_null());
    for scenario in golden::cases("watch.json").into_iter().take(1) {
        for step in scenario["steps"].as_array().into_iter().flatten() {
            let op = CString::new(step["op"].as_str().unwrap_or_default()).expect("op");
            let body = serde_json::to_vec(&step["request"]).expect("request");
            let mut out = CmuxDaemonLaunchBytes { ptr: std::ptr::null_mut(), len: 0 };
            // SAFETY: a live handle and valid pointers.
            let code = unsafe {
                cmux_daemon_launch_watch_call(
                    watch,
                    op.as_ptr(),
                    body.as_ptr(),
                    body.len(),
                    &mut out,
                )
            };
            assert_eq!(code, CMUX_DAEMON_LAUNCH_OK);
            assert_eq!(take(&mut out), step["expect"], "{}", step["op"]);
        }
    }
    // SAFETY: freed once.
    unsafe { cmux_daemon_launch_watch_free(watch) };
    let bad = b"{\"sustainedMs\":\"x\"}";
    // SAFETY: readable bytes.
    assert!(unsafe { cmux_daemon_launch_watch_new(bad.as_ptr(), bad.len()) }.is_null());
}

#[test]
fn c_abi_lines_and_the_login_capture() {
    let lines = cmux_daemon_launch_lines_new();
    let mut out = CmuxDaemonLaunchBytes { ptr: std::ptr::null_mut(), len: 0 };
    let bytes = b"a\nb";
    // SAFETY: a live handle and valid pointers.
    assert_eq!(
        unsafe {
            cmux_daemon_launch_lines_push(lines, bytes.as_ptr(), bytes.len(), false, &mut out)
        },
        0
    );
    assert_eq!(take(&mut out), serde_json::json!(["a"]));
    // SAFETY: as above; the finish takes the rest.
    assert_eq!(
        unsafe { cmux_daemon_launch_lines_push(lines, std::ptr::null(), 0, true, &mut out) },
        0
    );
    assert_eq!(take(&mut out), serde_json::json!(["b"]));
    // SAFETY: freed once.
    unsafe { cmux_daemon_launch_lines_free(lines) };

    let output = b"x\n__CMUX_NEXT_LOGIN_ENV__\nPATH=/p\x00";
    // SAFETY: readable bytes, writable out.
    assert_eq!(
        unsafe { cmux_daemon_launch_login_env_accept(0, output.as_ptr(), output.len(), &mut out) },
        0
    );
    assert_eq!(take(&mut out), serde_json::json!({"PATH": "/p"}));
    // SAFETY: as above.
    assert_eq!(
        unsafe { cmux_daemon_launch_login_env_accept(1, output.as_ptr(), output.len(), &mut out) },
        0
    );
    assert_eq!(take(&mut out), Value::Null);
}
