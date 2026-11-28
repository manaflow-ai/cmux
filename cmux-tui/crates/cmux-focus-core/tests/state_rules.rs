//! Replays schemas/focus-state-rules/vectors.json against the Rust rules: random cases written
//! from a line-by-line transliteration of the CmuxNextFocus Swift before the move
//! (`TypeAheadWait.survives`, `FocusState` typing facts, `FocusTopology.removing`, `FocusEvent`
//! source facts, `Responder.debugName`, `FocusMachine.reapplyingOnWaitChange`).

use cmux_focus_core::state_rules::{OPERATIONS, call};
use serde::Deserialize;
use serde_json::Value;

const VECTORS: &str = include_str!("../../../../schemas/focus-state-rules/vectors.json");

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

#[test]
fn focus_state_rules_every_shared_vector_answers() {
    let vectors: Vectors =
        serde_json::from_str(VECTORS).expect("schemas/focus-state-rules/vectors.json parses");
    assert_eq!(vectors.v, 1);
    assert!(vectors.cases.len() > 300, "{} cases", vectors.cases.len());
    for op in OPERATIONS {
        assert!(vectors.cases.iter().any(|c| c.op == op), "no case for {op}");
    }
    let failed: Vec<String> = vectors
        .cases
        .iter()
        .filter_map(|case| {
            let request = serde_json::to_vec(&case.request).unwrap();
            let got = call(&case.op, &request);
            (got.as_ref() != Some(&case.expect))
                .then(|| format!("{}: expected {}, got {:?}", case.name, case.expect, got))
        })
        .collect();
    assert!(failed.is_empty(), "{} failed:\n{}", failed.len(), failed.join("\n"));
}

#[test]
fn focus_state_rules_refuse_an_unknown_op_or_a_bad_request() {
    assert_eq!(call("focus_state_nope", b"{}"), None);
    assert_eq!(call("focus_state_wait_change", b"{\"waited\":true}"), None);
    assert_eq!(call("focus_state_resolved_facts", b"not json"), None);
}
