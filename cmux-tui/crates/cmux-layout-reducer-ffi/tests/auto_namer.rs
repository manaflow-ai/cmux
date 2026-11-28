//! Replays schemas/workspace-auto-namer/vectors.json through the shipped JSON
//! ABI (ops `auto_namer_step`, `auto_name_hold_step`): the Swift
//! `WorkspaceAutoNamer` bookkeeping and `WorkspaceAutoNameHold` answers from
//! before the move, over random runs of the app's calls.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/workspace-auto-namer/vectors.json");

#[derive(Deserialize)]
struct Case {
    name: String,
    op: String,
    request: Value,
    expect: Value,
}

#[derive(Deserialize)]
struct Vectors {
    v: u32,
    cases: Vec<Case>,
}

fn call(op: &str, request: &[u8]) -> (i32, Vec<u8>) {
    let operation = CString::new(op).unwrap();
    let mut capacity = 256;
    loop {
        let mut output = vec![0_u8; capacity];
        let mut written = 0_usize;
        // SAFETY: request and output stay live for the call, each pointer has its stated length,
        // the operation is NUL-terminated and written is a valid exclusive output pointer.
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                operation.as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut written,
            )
        };
        if code == ERR_BUFFER {
            capacity *= 4;
            continue;
        }
        output.truncate(written);
        return (code, output);
    }
}

fn answer(op: &str, request: &Value) -> Value {
    let (code, output) = call(op, &serde_json::to_vec(request).unwrap());
    assert_eq!(code, OK, "{op} {request}");
    serde_json::from_slice(&output).unwrap()
}

#[test]
fn auto_namer_every_shared_vector_answers_as_swift_did() {
    let vectors: Vectors =
        serde_json::from_str(VECTORS).expect("schemas/workspace-auto-namer/vectors.json parses");
    assert_eq!(vectors.v, 1);
    assert!(vectors.cases.len() >= 500, "{} cases", vectors.cases.len());
    let failed: Vec<String> = vectors
        .cases
        .iter()
        .filter_map(|case| {
            let got = answer(&case.op, &case.request);
            (got != case.expect).then(|| {
                format!("{}: {} got {got}, expected {}", case.name, case.request, case.expect)
            })
        })
        .collect();
    assert!(
        failed.is_empty(),
        "{} of {} vectors differ:\n{}",
        failed.len(),
        vectors.cases.len(),
        failed.iter().take(10).cloned().collect::<Vec<_>>().join("\n")
    );
}

#[test]
fn auto_namer_a_bare_request_starts_from_empty_state() {
    let got = answer(
        "auto_namer_step",
        &json!({ "event": { "kind": "release", "slot": { "machineId": "m", "workspaceId": "w" }, "attempt": 0 } }),
    );
    assert_eq!(got["answer"], Value::Null);
    assert_eq!(
        got["state"],
        json!({ "submitted": [], "nextAttemptId": 0, "shown": [], "retries": [] })
    );
    let got = answer(
        "auto_name_hold_step",
        &json!({ "event": { "kind": "settle", "workspace": "w", "namer": "t" } }),
    );
    assert_eq!(got, json!({ "state": { "held": {}, "launcherNamed": {} }, "answer": null }));
}

#[test]
fn auto_namer_refuses_unknown_ops_and_malformed_requests() {
    for (op, request) in [
        ("auto_namer_nope", &b"{}"[..]),
        ("auto_namer_step", &b"not json"[..]),
        ("auto_namer_step", &br#"{"event":{"kind":"explode"}}"#[..]),
        ("auto_namer_step", &br#"{"event":{"kind":"maySend","attempt":0}}"#[..]),
        ("auto_name_hold_step", &br#"{"event":{"kind":"forget"}}"#[..]),
    ] {
        assert_eq!(call(op, request).0, ERR_INVALID, "{op}");
    }
}
