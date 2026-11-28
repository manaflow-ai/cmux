//! Replays schemas/workspace-naming/vectors.json through the shipped JSON
//! ABI (ops `workspace_name_*`): the Swift naming rules' answers
//! (`NewWorkspaceName`, `WorkspaceAutoName`, `WorkspaceActivityName`) from
//! before the move, over random and hand-picked inputs.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/workspace-naming/vectors.json");

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
fn workspace_naming_every_shared_vector_answers_as_swift_did() {
    let vectors: Vectors =
        serde_json::from_str(VECTORS).expect("schemas/workspace-naming/vectors.json parses");
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
fn workspace_naming_refuses_unknown_ops_and_bad_requests() {
    assert_eq!(call("workspace_name_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call("workspace_name_for_tab", b"{}").0, ERR_INVALID);
    assert_eq!(call("workspace_name_auto", b"not json").0, ERR_INVALID);
}

#[test]
fn workspace_naming_defaults_match_the_swift_arguments() {
    // A bare workspace: auto source, revision 0, legacy defaults allowed, no name-source support.
    let request = json!({"rule": {"enabled": true, "variant": "persist"}, "name": "workspace-3", "isLocalMachine": true,
                         "front": {"kind": "chat", "title": "Plan", "generatedTitle": "Plan"}});
    assert_eq!(
        answer("workspace_name_auto", &request),
        json!({"label": "Plan", "persisted": "Plan", "confirms": true})
    );
    let tab = json!({"tab": {"kind": "terminal", "title": "zsh", "cwd": "/tmp/api"}, "name": "workspace-4"});
    assert_eq!(answer("workspace_name_for_last_tab", &tab), json!({"name": "api"}));
}
