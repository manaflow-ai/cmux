//! The app's conversation client rules (src/app.rs) through the C ABI the
//! macOS app calls (src/ffi.rs, include/cmux_conversation_ffi.h): every
//! golden vector in tests/cases/app.json, which encode what the Swift client
//! did (each case names its Swift source), and the ABI's own error codes.

use cmux_conversation::ffi::{
    CmuxConversationBytes, ERR_INVALID, ERR_NULL, ERR_UNKNOWN_OP, OK,
    cmux_conversation_abi_version, cmux_conversation_bytes_free, cmux_conversation_call,
};
use serde::Deserialize;
use serde_json::Value;
use std::ffi::CString;

const CASES: &str = include_str!("cases/app.json");

#[derive(Deserialize)]
struct Corpus {
    format: String,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    op: String,
    request: Value,
    expect: Option<Value>,
    code: Option<i32>,
}

/// One call through the C ABI with raw request bytes.
fn call_raw(op: &str, request: &[u8]) -> Result<Value, i32> {
    let op = CString::new(op).expect("op name");
    let mut out = CmuxConversationBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: a NUL-terminated op, a readable request, a writable out.
    let code = unsafe {
        cmux_conversation_call(op.as_ptr(), request.as_ptr(), request.len(), &raw mut out)
    };
    if code != OK {
        assert!(out.ptr.is_null(), "nothing is written on an error");
        return Err(code);
    }
    // SAFETY: the library gave out `len` bytes at `ptr`.
    let bytes = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
    // SAFETY: freed once.
    unsafe { cmux_conversation_bytes_free(out) };
    Ok(serde_json::from_slice(&bytes).expect("the reply is JSON"))
}

fn call(op: &str, request: &Value) -> Result<Value, i32> {
    call_raw(op, &serde_json::to_vec(request).expect("request"))
}

/// Equal JSON, with numbers equal to 1e-12 (progress fractions).
fn same(actual: &Value, expect: &Value) -> bool {
    match (actual, expect) {
        (Value::Number(a), Value::Number(b)) => match (a.as_f64(), b.as_f64()) {
            (Some(a), Some(b)) => (a - b).abs() < 1e-12 && a.fract().eq(&0.0) == b.fract().eq(&0.0),
            _ => a == b,
        },
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b))
        }
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len() && a.iter().all(|(k, v)| b.get(k).is_some_and(|w| same(v, w)))
        }
        _ => actual == expect,
    }
}

#[test]
fn c_abi_every_golden_vector() {
    let corpus: Corpus = serde_json::from_str(CASES).expect("tests/cases/app.json");
    assert_eq!(corpus.format, "cmux-conversation-app/1");
    assert!(corpus.cases.len() > 50);
    let mut failures = Vec::new();
    for case in &corpus.cases {
        let actual = call(&case.op, &case.request);
        let ok = match (&actual, &case.expect, case.code) {
            (Ok(value), Some(expect), None) => same(value, expect),
            (Err(code), None, Some(expected)) => *code == expected,
            _ => false,
        };
        if !ok {
            failures.push(format!(
                "{}: got {actual:?}, want {:?} {:?}",
                case.name, case.expect, case.code
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} cases differ:\n{}",
        failures.len(),
        corpus.cases.len(),
        failures.join("\n")
    );
}

#[test]
fn c_abi_errors() {
    assert_eq!(cmux_conversation_abi_version(), 1);
    assert_eq!(call_raw("policy", b"").map(|v| v["max_page"].clone()), Ok(Value::from(500)));
    assert_eq!(call_raw("policy", b"[1]"), Err(ERR_INVALID));
    assert_eq!(call_raw("policy", b"{"), Err(ERR_INVALID));
    assert_eq!(call_raw("policy", &[0xff, 0xfe]), Err(ERR_INVALID));
    assert_eq!(call_raw("bogus", b"{}"), Err(ERR_UNKNOWN_OP));
    let mut out = CmuxConversationBytes { ptr: std::ptr::null_mut(), len: 0 };
    // SAFETY: null pointers are refused before any read.
    unsafe {
        assert_eq!(
            cmux_conversation_call(std::ptr::null(), std::ptr::null(), 0, &raw mut out),
            ERR_NULL
        );
        let op = CString::new("policy").expect("op");
        assert_eq!(
            cmux_conversation_call(op.as_ptr(), std::ptr::null(), 3, &raw mut out),
            ERR_NULL
        );
        assert_eq!(
            cmux_conversation_call(op.as_ptr(), std::ptr::null(), 0, std::ptr::null_mut()),
            ERR_NULL
        );
        cmux_conversation_bytes_free(CmuxConversationBytes { ptr: std::ptr::null_mut(), len: 0 });
    }
}

#[test]
fn c_abi_upload_plan_covers_a_large_file_exactly() {
    let size: u64 = 1 << 30;
    let plan = call(
        "upload_plan",
        &serde_json::json!({"attachment": {"byte_count": size}, "needs": ["original"]}),
    )
    .expect("plan");
    let chunks = plan["pieces"][0]["chunks"].as_array().expect("chunks");
    assert_eq!(chunks.len(), 256);
    let mut next = 0;
    for chunk in chunks {
        assert_eq!(chunk["offset"].as_u64(), Some(next));
        next += chunk["length"].as_u64().expect("length");
        assert!(chunk["progress"].as_f64().expect("progress") <= 0.99);
    }
    assert_eq!(next, size);
}
