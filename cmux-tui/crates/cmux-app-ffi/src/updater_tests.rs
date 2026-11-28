use super::*;
use std::ffi::CString;

fn ffi(op: &str, request: &str) -> (i32, Option<Value>) {
    let op = CString::new(op).unwrap();
    let mut out = CmuxUpdaterBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: valid pointers for the call.
    let status =
        unsafe { cmux_updater_call(op.as_ptr(), request.as_ptr(), request.len(), &mut out) };
    if status != CMUX_UPDATER_OK {
        return (status, None);
    }
    // SAFETY: the reply buffer the call wrote.
    let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    let value = serde_json::from_slice(reply).ok();
    // SAFETY: freed once.
    unsafe { cmux_updater_bytes_free(out) };
    (status, value)
}

#[test]
fn handle_answers_the_new_flow_and_its_effects() {
    let (status, reply) = ffi(
        "update_flow.handle",
        r#"{"flow": {"phase": "downloading", "installRequested": true},
                "event": {"kind": "sparkle", "next": "ready"},
                "preferences": {"installOnQuit": false, "oneClickInstall": false}}"#,
    );
    assert_eq!(status, CMUX_UPDATER_OK);
    assert_eq!(
        reply,
        Some(json!({
            "flow": {"phase": "ready", "installRequested": false, "userAsked": false,
                     "downloadAsked": false, "askPending": false},
            "effects": ["install"]
        }))
    );
}

#[test]
fn card_and_pill_answer_kinds_or_null() {
    let (_, card) = ffi(
        "update_flow.card",
        r#"{"flow": {"phase": "available"}, "downloadsAutomatically": false}"#,
    );
    assert_eq!(card, Some(json!("available")));
    let (_, none) = ffi("update_flow.card", r#"{"flow": {}, "downloadsAutomatically": true}"#);
    assert_eq!(none, Some(Value::Null));
    let (_, pill) =
        ffi("update_flow.footer_pill", r#"{"flow": {"phase": "ready"}, "silent": false}"#);
    assert_eq!(pill, Some(json!("ready")));
}

#[test]
fn staged_prewarm_ops_answer_over_the_abi() {
    let (status, none) = ffi(
        "staged_prewarm.scan",
        r#"{"installations": ["/nonexistent-cmux-prewarm"], "bundleIdentifier": "x", "build": "1"}"#,
    );
    assert_eq!(status, CMUX_UPDATER_OK);
    assert_eq!(none, Some(Value::Null));
    let (_, word) = ffi(
        "staged_prewarm.describe_exit",
        r#"{"executable": "/A.app/Contents/Frameworks/A Helper.app/Contents/MacOS/A Helper", "status": 255}"#,
    );
    assert_eq!(word, Some(json!("exit 255 (framework loaded)")));
    let (_, pages) = ffi("staged_prewarm.read_pages", r#"{"root": "/nonexistent-cmux-prewarm"}"#);
    assert_eq!(pages, Some(json!({"files": 0, "pages": 0})));
    assert_eq!(
        ffi("staged_prewarm.consume_marker", r#"{"build": "1"}"#).0,
        CMUX_UPDATER_ERR_INVALID
    );
}

#[test]
fn bad_calls_answer_their_codes() {
    assert_eq!(ffi("nope", "{}").0, CMUX_UPDATER_ERR_UNKNOWN_OP);
    assert_eq!(ffi("update_flow.handle", "[]").0, CMUX_UPDATER_ERR_INVALID);
    assert_eq!(ffi("update_flow.handle", "{}").0, CMUX_UPDATER_ERR_INVALID);
}
