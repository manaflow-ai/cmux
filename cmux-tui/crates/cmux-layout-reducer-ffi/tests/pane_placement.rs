//! Replays schemas/agent-pane-placement/vectors.json through the shipped JSON
//! ABI (ops `right_column_*`, `subagent_panes_step`): the Swift
//! `RightColumnPlacement` and `AgentSubagentPanes` answers from before the
//! move, over random columns, frames and runs of the app's calls.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/agent-pane-placement/vectors.json");

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
fn pane_placement_every_shared_vector_answers_as_swift_did() {
    let vectors: Vectors =
        serde_json::from_str(VECTORS).expect("schemas/agent-pane-placement/vectors.json parses");
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
        failed.join("\n")
    );
}

#[test]
fn pane_placement_refuses_unknown_ops_and_bad_requests() {
    assert_eq!(call("right_column_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call("right_column_beside", b"{}").0, ERR_INVALID);
    assert_eq!(call("subagent_panes_step", b"{}").0, ERR_INVALID);
    assert_eq!(call("subagent_panes_step", br#"{"event":{"kind":"nope"}}"#).0, ERR_INVALID);
    assert_eq!(call("right_column_decide", b"not json").0, ERR_INVALID);
}

#[test]
fn pane_placement_defaults_match_the_swift_arguments() {
    // No column read: a split right; the beside gap defaults to the layout's 24 pt gutter.
    assert_eq!(
        answer("right_column_decide", &json!({})),
        json!({"decision": {"to": "splitRight"}})
    );
    let frames = json!({"chat": {"x": 0.0, "y": 0.0, "width": 700.0, "height": 800.0},
                        "near": {"x": 724.0, "y": 0.0, "width": 300.0, "height": 800.0}});
    assert_eq!(
        answer("right_column_beside", &json!({"source": "chat", "frames": frames})),
        json!({"panes": ["near"]})
    );
    // A fresh tracker places the first open; `asked` defaults to `focus`.
    let step = answer(
        "subagent_panes_step",
        &json!({"event": {"kind": "open", "agent": "a", "focus": true, "chat": "c", "now": 1}}),
    );
    assert_eq!(step["answer"], json!("place"));
    assert_eq!(step["state"]["opening"], json!("a"));
}
