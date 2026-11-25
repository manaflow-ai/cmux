//! `cmux_sdk_conversation_rule` against every golden vector of the SDK's
//! conversation client rules (bindings/rust/tests/cases/conversation_rules.json,
//! each naming the Swift source it encodes), run through the C ABI the app
//! calls: the reply envelope, a rule's refusal, an unknown rule and bad input.

use cmux_sdk_ffi::{
    CMUX_SDK_ERR_INVALID, CMUX_SDK_ERR_NULL, CMUX_SDK_ERR_UNKNOWN_RULE, CMUX_SDK_FFI_ABI_VERSION,
    CMUX_SDK_OK, CmuxSdkBytes, cmux_sdk_bytes_free, cmux_sdk_conversation_rule,
    cmux_sdk_ffi_abi_version,
};
use serde_json::{Value, json};
use std::ffi::CString;

const CASES: &str = include_str!("../../../bindings/rust/tests/cases/conversation_rules.json");

fn empty() -> CmuxSdkBytes {
    CmuxSdkBytes { ptr: std::ptr::null_mut(), len: 0 }
}

/// The return code and, on `CMUX_SDK_OK`, the reply envelope.
fn raw_rule(op: &str, request: &[u8]) -> (i32, Option<Value>) {
    let op = CString::new(op).unwrap();
    let mut out = empty();
    let code = unsafe {
        cmux_sdk_conversation_rule(op.as_ptr(), request.as_ptr(), request.len(), &mut out)
    };
    if code != CMUX_SDK_OK {
        assert!(out.ptr.is_null() && out.len == 0, "a failed call leaves *out empty");
        return (code, None);
    }
    assert!(!out.ptr.is_null());
    let text = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
    unsafe { cmux_sdk_bytes_free(out) };
    (code, Some(serde_json::from_slice(&text).unwrap()))
}

/// A rule's answer in the corpus's shape: the result, `{"error": code}` for
/// a refusal, or the return code for an unknown rule.
fn rule(op: &str, request: &Value) -> Result<Value, i32> {
    match raw_rule(op, request.to_string().as_bytes()) {
        (CMUX_SDK_OK, Some(reply)) if reply["ok"] == true => Ok(reply["result"].clone()),
        (CMUX_SDK_OK, Some(reply)) => {
            assert_eq!(reply["ok"], false);
            let code = reply["error"]["code"].as_str().expect("a refusal's code");
            assert!(reply["error"]["message"].as_str().is_some_and(|m| m.contains(code)));
            Ok(json!({"error": code}))
        }
        (code, _) => Err(code),
    }
}

/// An `upload_plan` reply with every chunk listed, each one asked for
/// through `upload_chunk`: the shape the Swift client's vectors record.
fn with_chunks(plan: &Value) -> Value {
    let Some(pieces) = plan.get("pieces").and_then(Value::as_array) else {
        return plan.clone();
    };
    let pieces: Vec<Value> = pieces
        .iter()
        .map(|piece| {
            let count = piece["chunk_count"].as_u64().expect("chunk_count");
            let chunks: Vec<Value> = (0..count)
                .map(|index| {
                    let request = json!({"size": piece["size"], "sent_before": piece["sent_before"],
                                         "total": plan["total"], "index": index});
                    rule("upload_chunk", &request).expect("a known rule")
                })
                .collect();
            json!({"variant": piece["variant"], "size": piece["size"], "chunks": chunks})
        })
        .collect();
    json!({"pieces": pieces})
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
fn every_golden_vector_through_the_c_abi() {
    let corpus: Value = serde_json::from_str(CASES).expect("conversation_rules.json");
    let cases = corpus["cases"].as_array().expect("cases");
    assert!(cases.len() > 50);
    let mut failures = Vec::new();
    for case in cases {
        let op = case["op"].as_str().expect("op");
        let actual = match rule(op, &case["request"]) {
            Ok(value) if op == "upload_plan" && case.get("shape").is_none() => {
                Ok(with_chunks(&value))
            }
            other => other,
        };
        let ok = match (&actual, case.get("expect"), case.get("code").and_then(Value::as_i64)) {
            (Ok(value), Some(expect), None) => same(value, expect),
            (Err(code), None, Some(expected)) => i64::from(*code) == expected,
            _ => false,
        };
        if !ok {
            failures.push(format!(
                "{}: got {actual:?}, want {:?} {:?}",
                case["name"],
                case.get("expect"),
                case.get("code")
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} cases differ:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

#[test]
fn an_unknown_rule_is_its_own_code() {
    assert_eq!(CMUX_SDK_ERR_UNKNOWN_RULE, -3);
    assert_eq!(raw_rule("nope", b"{}"), (CMUX_SDK_ERR_UNKNOWN_RULE, None));
}

#[test]
fn a_refusal_is_an_error_envelope() {
    let (code, reply) = raw_rule("clamp_page", b"{}");
    assert_eq!(code, CMUX_SDK_OK);
    let reply = reply.unwrap();
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["error"]["code"], "invalid");
}

#[test]
fn an_empty_request_is_an_empty_object() {
    let op = CString::new("policy").unwrap();
    let mut out = empty();
    let code = unsafe { cmux_sdk_conversation_rule(op.as_ptr(), std::ptr::null(), 0, &mut out) };
    assert_eq!(code, CMUX_SDK_OK);
    let text = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
    unsafe { cmux_sdk_bytes_free(out) };
    let reply: Value = serde_json::from_slice(&text).unwrap();
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["result"]["max_page"], 500);
}

#[test]
fn bad_input_is_refused_before_any_rule() {
    // Not a JSON object, not JSON, not UTF-8.
    assert_eq!(raw_rule("policy", b"[]").0, CMUX_SDK_ERR_INVALID);
    assert_eq!(raw_rule("policy", b"{").0, CMUX_SDK_ERR_INVALID);
    let op = [0xffu8, 0];
    let mut out = empty();
    let code =
        unsafe { cmux_sdk_conversation_rule(op.as_ptr().cast(), std::ptr::null(), 0, &mut out) };
    assert_eq!(code, CMUX_SDK_ERR_INVALID);
    assert!(out.ptr.is_null());
    // A null op or out.
    let code =
        unsafe { cmux_sdk_conversation_rule(std::ptr::null(), std::ptr::null(), 0, &mut out) };
    assert_eq!(code, CMUX_SDK_ERR_INVALID);
    let op = CString::new("policy").unwrap();
    let code = unsafe {
        cmux_sdk_conversation_rule(op.as_ptr(), std::ptr::null(), 0, std::ptr::null_mut())
    };
    assert_eq!(code, CMUX_SDK_ERR_NULL);
}

#[test]
fn the_abi_version_names_the_rule_entry() {
    assert_eq!(CMUX_SDK_FFI_ABI_VERSION, 2);
    assert_eq!(cmux_sdk_ffi_abi_version(), 2);
}
