//! The registry store ops (`registry_store_apply`, `registry_store_restore_closed`,
//! `registry_store_claims`) through the C ABI: every vector in
//! `schemas/window-registry-store/vectors.json` (the Swift `WindowRegistryStore`,
//! `RestoreClosedWindows` and `WorkspaceClaims` answers before the move) answers the same, and a
//! bad request is `ERR_INVALID`.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::Value;
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/window-registry-store/vectors.json");

fn call(op: &str, request: &[u8]) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let mut capacity = 1 << 12;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                op.as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut len,
            )
        };
        if code == ERR_BUFFER {
            capacity = len;
            continue;
        }
        let body =
            if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
        return (code, body);
    }
}

#[test]
fn every_vector_answers_as_the_swift_store_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 1000, "{} cases", cases.len());
    for op in ["registry_store_apply", "registry_store_restore_closed", "registry_store_claims"] {
        assert!(cases.iter().any(|c| c["op"] == op), "no {op} case");
    }
    for (index, case) in cases.iter().enumerate() {
        let op = case["op"].as_str().unwrap();
        let request = serde_json::to_vec(&case["request"]).unwrap();
        let (code, body) = call(op, &request);
        assert_eq!(code, OK, "case {index} {op}");
        assert_eq!(body, case["response"], "case {index} {op}: {}", case["request"]);
    }
}

#[test]
fn a_bad_request_is_invalid() {
    assert_eq!(call("registry_store_apply", b"{}").0, ERR_INVALID);
    assert_eq!(call("registry_store_apply", b"not json").0, ERR_INVALID);
    assert_eq!(
        call("registry_store_apply", br#"{"store":{},"action":{"kind":"nope"}}"#).0,
        ERR_INVALID
    );
    assert_eq!(
        call("registry_store_apply", br#"{"store":{},"action":{"kind":"members","id":"w1"}}"#).0,
        OK
    );
    assert_eq!(
        call("registry_store_restore_closed", br#"{"memory":{},"action":{"kind":"keepClosed"}}"#).0,
        ERR_INVALID
    );
    let restore = br#"{"memory":{},"registry":{},"action":{"kind":"keepClosed"}}"#;
    assert_eq!(call("registry_store_restore_closed", restore).0, OK);
    assert_eq!(
        call("registry_store_claims", br#"{"claims":{},"action":{"kind":"release"}}"#).0,
        ERR_INVALID
    );
    let claims = br#"{"claims":{},"action":{"kind":"release","id":"a"}}"#;
    assert_eq!(call("registry_store_claims", claims).0, OK);
}
