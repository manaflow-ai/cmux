//! One open conversation's mirror and intent log (src/session.rs) through
//! the C session handle the macOS app calls (src/ffi.rs): every flow in
//! tests/cases/session.json, which encode what the Swift
//! HomeConversationSession, ConversationMirror and ConversationIntentLog
//! did, and the handle's own error codes.

use cmux_conversation::ffi::{
    CmuxConversationBytes, CmuxConversationSession, ERR_NULL, ERR_UNKNOWN_OP, OK,
    cmux_conversation_bytes_free, cmux_conversation_session_call, cmux_conversation_session_free,
    cmux_conversation_session_new,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::CString;

const FLOWS: &str = include_str!("cases/session.json");

#[derive(Deserialize)]
struct Corpus {
    format: String,
    flows: Vec<Flow>,
}

#[derive(Deserialize)]
struct Flow {
    name: String,
    tail_limit: u32,
    steps: Vec<Step>,
}

#[derive(Deserialize)]
struct Step {
    op: String,
    request: Value,
    expect: Value,
}

fn call(session: *const CmuxConversationSession, op: &str, request: &Value) -> Result<Value, i32> {
    let op = CString::new(op).expect("op name");
    let bytes = serde_json::to_vec(request).expect("request");
    let mut out = CmuxConversationBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: a live handle, a NUL-terminated op, a readable request, a writable out.
    let code = unsafe {
        cmux_conversation_session_call(
            session,
            op.as_ptr(),
            bytes.as_ptr(),
            bytes.len(),
            &raw mut out,
        )
    };
    if code != OK {
        return Err(code);
    }
    // SAFETY: the library gave out `len` bytes at `ptr`.
    let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
    // SAFETY: freed once.
    unsafe { cmux_conversation_bytes_free(out) };
    Ok(serde_json::from_slice(&reply).expect("the reply is JSON"))
}

#[test]
fn c_abi_every_session_flow() {
    let corpus: Corpus = serde_json::from_str(FLOWS).expect("tests/cases/session.json");
    assert_eq!(corpus.format, "cmux-conversation-session/1");
    let mut failures = Vec::new();
    for flow in &corpus.flows {
        let session = cmux_conversation_session_new(flow.tail_limit);
        for (index, step) in flow.steps.iter().enumerate() {
            let actual = call(session, &step.op, &step.request);
            if actual.as_ref() != Ok(&step.expect) {
                failures.push(format!(
                    "{} step {index} ({}):\n  got  {}\n  want {}",
                    flow.name,
                    step.op,
                    actual.map_or_else(|code| format!("code {code}"), |v| v.to_string()),
                    step.expect
                ));
                break;
            }
        }
        // SAFETY: a handle from `cmux_conversation_session_new`, freed once.
        unsafe { cmux_conversation_session_free(session) };
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn c_abi_session_errors() {
    assert_eq!(call(std::ptr::null(), "state", &json!({})), Err(ERR_NULL));
    let session = cmux_conversation_session_new(0);
    assert_eq!(call(session, "bogus", &json!({})), Err(ERR_UNKNOWN_OP));
    assert_eq!(call(session, "state", &json!({})).map(|s| s["mirror"].clone()), Ok(Value::Null));
    // SAFETY: null is ignored; the handle is freed once.
    unsafe {
        cmux_conversation_session_free(std::ptr::null_mut());
        cmux_conversation_session_free(session);
    }
}

/// The kept events stop at 1024 while a snapshot loads.
#[test]
fn c_abi_session_buffer_is_bounded() {
    let session = cmux_conversation_session_new(0);
    for rev in 1..=2000 {
        call(session, "apply", &json!({"event": {"rev": rev, "change": {"kind": "x"}}}))
            .expect("apply");
    }
    let state = call(session, "state", &json!({})).expect("state");
    assert_eq!(state["buffered"], json!(1024));
    // SAFETY: freed once.
    unsafe { cmux_conversation_session_free(session) };
}
